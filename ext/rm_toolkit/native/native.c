#include "ruby.h"
#include "ruby/thread.h" // Needed for rb_thread_call_without_gvl
#include <errno.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// --- Platform Specific Includes ---
#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <locale.h>
#else
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/mman.h> // For mmap
#include <fcntl.h>    // For O_RDONLY
#include <unistd.h>
#include <pthread.h>
#endif

// --- SIMD Intrinsics Includes ---
#if defined(__AVX2__)
#include <immintrin.h>
#endif

// --- Ruby Integration Variables ---
VALUE RmToolkitNative_module = Qnil;
VALUE rm_toolkit_native_Error_class;
VALUE native_File_module;
VALUE native_FileUtils_module;
ID native_join_id;
ID native_dirname_id;
ID native_mkdir_p_id;
ID native_expand_path_id;

// ============================================================================
// --- Utility Functions --- (Unchanged)
// ============================================================================
static bool is_hex_char(char c) {
    return (c >= '0' && c <= '9') ||
           (c >= 'a' && c <= 'f') ||
           (c >= 'A' && c <= 'F');
}

static void sanitize_unicode_escapes_in_place(char *path) {
    if (!path) return;
    char *read_ptr = path, *write_ptr = path;
    while (*read_ptr) {
        if (*read_ptr == '\\' && (read_ptr[1] == 'u' || read_ptr[1] == 'U') &&
            read_ptr[2] && is_hex_char(read_ptr[2]) &&
            read_ptr[3] && is_hex_char(read_ptr[3]) &&
            read_ptr[4] && is_hex_char(read_ptr[4]) &&
            read_ptr[5] && is_hex_char(read_ptr[5])) {
            read_ptr += 6;
        } else {
            *write_ptr++ = *read_ptr++;
        }
    }
    *write_ptr = '\0';
}

static void sanitize_path_in_place(char *path) {
    if (!path) return;
    char *read_ptr = path, *write_ptr = path;
    while (*read_ptr) {
        unsigned char current_char = (unsigned char)*read_ptr;
        bool is_invalid = false;
        switch (current_char) {
            case '<': case '>': case ':': case '"': case '|': case '?': case '*':
                is_invalid = true;
                break;
            default:
                if (current_char > 0 && current_char < 32) is_invalid = true;
                break;
        }
        if (!is_invalid) *write_ptr++ = *read_ptr;
        read_ptr++;
    }
    *write_ptr = '\0';
}

static bool is_path_safe_precheck(const char *path) {
    if (!path) return false;
    if (path[0] == '/' || path[0] == '\\') return false;
    if (strlen(path) >= 2 && path[1] == ':') return false;
    const char *p = path;
    while ((p = strstr(p, "..")) != NULL) {
        bool at_start = (p == path);
        bool at_end = (*(p + 2) == '\0');
        bool pre_slash = !at_start && (*(p - 1) == '/' || *(p - 1) == '\\');
        bool post_slash = !at_end && (*(p + 2) == '/' || *(p + 2) == '\\');
        if ((at_start || pre_slash) && (at_end || post_slash)) {
            return false;
        }
        p += 2;
    }
    return true;
}

static void sys_fail_helper(const char *msg, const char *path) {
  char full_msg[1024];
  snprintf(full_msg, sizeof(full_msg), "%s: %s (%s)", msg, path, strerror(errno));
  rb_sys_fail(full_msg);
}

FILE *platform_fopen(const char *path, const char *mode) {
  return fopen(path, mode);
}

// ============================================================================
// --- RGSSAD Decryption Logic --- (Unchanged)
// ============================================================================
#define MOD_4_MASK 0b11
enum RGSSAD_TYPE { UNKNOWN_ARCHIVE, RGSSADv1, RGSSADv3, FUX2PACK2 };
#define RGSSADv1_INITIAL_KEY 0xDEADCAFE
#define HEADER_SIZE 8
#define V3_SEED_SIZE 4
#define FUX2PACK2_HEADER_HINT_SIZE 8

unsigned int decrypt_integer_v1(unsigned int encrypted_val, unsigned int *key) { unsigned int decrypted_val = encrypted_val ^ (*key); *key = (*key) * 7 + 3; return decrypted_val; }
void decrypt_filename_v1(unsigned char *data, size_t n, unsigned int *key) { for (size_t i = 0; i < n; ++i) { data[i] ^= ((*key) & 0xFF); *key = (*key) * 7 + 3; } }
unsigned int decrypt_integer_v3(unsigned int encrypted_val, unsigned int key) { return encrypted_val ^ key; }
void decrypt_filename_v3(unsigned char *data, size_t n, unsigned int key) {
  size_t q = n >> 2; int r = n & MOD_4_MASK;
  unsigned int *data_p = (unsigned int *)data;
  for (size_t i = 0; i < q; ++i) data_p[i] ^= key;
  unsigned char *remainder_p = (unsigned char *)(data_p + q);
  if (r > 0) { unsigned char* key_bytes = (unsigned char*)&key; for (int i = 0; i < r; ++i) remainder_p[i] ^= key_bytes[i]; }
}

// ============================================================================
// --- Data Decryption (SIMD) ---
// ============================================================================
typedef void (*decrypt_func_t)(unsigned char*, size_t, unsigned int);
static decrypt_func_t g_decrypt_func = NULL;

// ** GROUND TRUTH SCALAR IMPLEMENTATION **
// This version is correct: it returns the updated key, essential for the SIMD functions.
__attribute__((optimize("no-tree-vectorize")))
static unsigned int decrypt_file_data_scalar(unsigned char *data, size_t n, unsigned int key) {
  size_t q = n >> 2;
  int r = n & MOD_4_MASK;
  unsigned int *data_p = (unsigned int *)data;

  for (size_t i = 0; i < q; ++i) {
    data_p[i] ^= key;
    key = key * 7 + 3;
  }

  if (r > 0) {
      unsigned char *remainder_p = (unsigned char *)(data_p + q);
      unsigned char *key_bytes = (unsigned char *)&key;
      for (int i = 0; i < r; ++i) {
          remainder_p[i] ^= key_bytes[i];
      }
  }
  return key;
}

#if defined(__AVX2__)
#define VEC_SIZE_AVX2 8
#define MOD_32_MASK 0x1F
#if __STDC_VERSION__ >= 201112L
_Alignas(32)
#elif defined(__GNUC__) || defined(__clang__)
__attribute__((aligned(32)))
#endif
static const unsigned int POWERS_OF_7_AVX2[VEC_SIZE_AVX2] = {
    1U, 7U, 49U, 343U, 2401U, 16807U, 117649U, 823543U
};
#if __STDC_VERSION__ >= 201112L
_Alignas(32)
#elif defined(__GNUC__) || defined(__clang__)
__attribute__((aligned(32)))
#endif
static const unsigned int GEOMETRIC_SUMS_AVX2[VEC_SIZE_AVX2] = {
    0U, 3U, 24U, 171U, 1200U, 8403U, 58824U, 411771U
};

#define POWER_OF_7_STEP_AVX2 5764801U
#define GEOMETRIC_SUM_STEP_AVX2 2882400U

__attribute__((target("avx2")))
static void decrypt_file_data_avx2_parallel(unsigned char* data, size_t n, unsigned int key) {
    const __m256i v_powers = _mm256_load_si256((const __m256i*)POWERS_OF_7_AVX2);
    const __m256i v_geometrics = _mm256_load_si256((const __m256i*)GEOMETRIC_SUMS_AVX2);
    size_t offset = 0;
    if (((uintptr_t)data & MOD_32_MASK) != 0) {
        offset = 32 - ((uintptr_t)data & MOD_32_MASK);
        if (offset > n) offset = n;
        key = decrypt_file_data_scalar(data, offset, key); // Correctly update key
    }
    const size_t q = (n - offset) >> 5;
    const int r = (n - offset) & MOD_32_MASK;
    __m256i* data_p = (__m256i*)(data + offset);
    for (size_t i = 0; i < q; ++i) {
        __m256i v_key_base = _mm256_set1_epi32(key);
        __m256i v_keys = _mm256_add_epi32(_mm256_mullo_epi32(v_key_base, v_powers), v_geometrics);
        __m256i v_data = _mm256_load_si256(data_p);
        v_data = _mm256_xor_si256(v_data, v_keys);
        _mm256_store_si256(data_p, v_data);
        data_p++;
        key = key * POWER_OF_7_STEP_AVX2 + GEOMETRIC_SUM_STEP_AVX2;
    }
    if (r > 0) {
        decrypt_file_data_scalar((unsigned char*)data_p, (size_t)r, key);
    }
}
#endif

// Wrapper to match the function pointer type `void (*)(...)` for the fallback case.
void decrypt_file_data_scalar_wrapper(unsigned char *data, size_t n, unsigned int key) {
    decrypt_file_data_scalar(data, n, key);
}

void decrypt_file_data(unsigned char *data, size_t n, unsigned int key) {
    g_decrypt_func(data, n, key);
}

// ============================================================================
// --- Buffer Pool Implementation --- (Unchanged)
// ============================================================================
#define POOL_SIZE 8
#define DEFAULT_BUFFER_SIZE (1024 * 1024)

typedef struct {
    unsigned char *buffer;
    size_t capacity;
    bool in_use;
    bool is_overflow;
} PoolBuffer;

static inline bool init_buffer_pool(PoolBuffer *pool) {
    for (int i = 0; i < POOL_SIZE; ++i) {
        pool[i].buffer = malloc(DEFAULT_BUFFER_SIZE);
        if (!pool[i].buffer) { for (int j = 0; j < i; ++j) free(pool[j].buffer); return false; }
        pool[i].capacity = DEFAULT_BUFFER_SIZE;
        pool[i].in_use = false;
        pool[i].is_overflow = false;
    }
    return true;
}

static inline void free_buffer_pool(PoolBuffer *pool) {
    for (int i = 0; i < POOL_SIZE; ++i) { free(pool[i].buffer); }
}

static inline PoolBuffer* get_buffer(PoolBuffer *pool, size_t required_size) {
    for (int i = 0; i < POOL_SIZE; ++i) {
        if (!pool[i].in_use && pool[i].capacity >= required_size) {
            pool[i].in_use = true;
            return &pool[i];
        }
    }
    PoolBuffer* overflow_buf = malloc(sizeof(PoolBuffer));
    if (!overflow_buf) return NULL;
    overflow_buf->buffer = malloc(required_size);
    if (!overflow_buf->buffer) { free(overflow_buf); return NULL; }
    overflow_buf->capacity = required_size;
    overflow_buf->in_use = true;
    overflow_buf->is_overflow = true;
    return overflow_buf;
}

static inline void return_buffer(PoolBuffer *pbuf) {
    if (!pbuf) return;
    if (pbuf->is_overflow) {
        free(pbuf->buffer);
        free(pbuf);
    } else {
        pbuf->in_use = false;
    }
}


// ============================================================================
// --- RGSSAD Extraction Logic (Structs and Cleanup) ---
// ============================================================================
enum EntryReadStatus { SUCCESS = 0, END_OF_FILE = 1, READ_ERROR = -1, ALLOC_ERROR = -2 };

typedef struct {
    unsigned int offset, size, data_key, filename_size;
    char *decrypted_filename, *final_output_path_c;
} RgssadEntry;

typedef struct {
    RgssadEntry **entries;
    size_t count, capacity;
} RgssadExtractionPlan;

struct RgssadContext;

typedef struct {
    int thread_id;
    struct RgssadContext *main_ctx;
    PoolBuffer pool[POOL_SIZE];
} RgssadThreadContext;

// ** REFACTORED CONTEXT STRUCT **
// `mapped_file` and `file_size` are now common for all platforms.
// Windows-specific handles are isolated.
typedef struct RgssadContext {
    VALUE target_path_rb, output_dir_rb;
    bool verbose;
    RgssadExtractionPlan *plan;
    unsigned char *mapped_file;
    size_t file_size;
#ifdef _WIN32
    HANDLE h_file;
    HANDLE h_map_file;
#endif
    enum RGSSAD_TYPE archive_type;
    unsigned int key_v3;
    int num_threads;
    bool thread_error_occurred;
    volatile int last_error_no;
#ifndef _WIN32
    pthread_mutex_t next_entry_mutex;
#endif
    size_t next_entry_index;
    RgssadThreadContext *thread_contexts;
} RgssadContext;

static void free_extraction_plan(RgssadExtractionPlan *plan) {
    if (!plan) return;
    for (size_t i = 0; i < plan->count; i++) {
        if (plan->entries[i]) {
            free(plan->entries[i]->decrypted_filename);
            free(plan->entries[i]->final_output_path_c);
            free(plan->entries[i]);
        }
    }
    free(plan->entries);
    free(plan);
}

// ** REFACTORED CLEANUP FUNCTION **
// Handles both Windows and non-Windows resource cleanup in a unified way.
static VALUE rgssad_cleanup(VALUE context_val) {
    RgssadContext *ctx = (RgssadContext *)context_val;
    free_extraction_plan(ctx->plan);
    if (ctx->thread_contexts) {
        free(ctx->thread_contexts);
    }
    if (ctx->mapped_file) {
#ifdef _WIN32
        UnmapViewOfFile(ctx->mapped_file);
#else
        munmap(ctx->mapped_file, ctx->file_size);
#endif
    }
#ifdef _WIN32
    if (ctx->h_map_file) CloseHandle(ctx->h_map_file);
    if (ctx->h_file) CloseHandle(ctx->h_file);
#else
    pthread_mutex_destroy(&ctx->next_entry_mutex);
#endif
    return Qnil;
}

// ** REFACTORED TO USE MEMORY MAPPING ON ALL PLATFORMS **
// The old file-based plan building functions for Windows are now removed.
static int build_plan_from_memory(RgssadContext *ctx, const unsigned char* memory, size_t size) {
    const unsigned char *ptr = memory;
    unsigned int key_v1 = RGSSADv1_INITIAL_KEY;
    size_t current_offset = 0;

    while(current_offset < size) {
        if (ctx->plan->count >= ctx->plan->capacity) {
            size_t new_capacity = ctx->plan->capacity == 0 ? 256 : ctx->plan->capacity * 2;
            RgssadEntry **new_entries = realloc(ctx->plan->entries, new_capacity * sizeof(RgssadEntry*));
            if (!new_entries) return ALLOC_ERROR;
            ctx->plan->entries = new_entries;
            ctx->plan->capacity = new_capacity;
        }
        RgssadEntry *entry = calloc(1, sizeof(RgssadEntry));
        if (!entry) return ALLOC_ERROR;

        if (ctx->archive_type == RGSSADv1) {
            if (current_offset + 4 > size) { free(entry); return READ_ERROR; }
            unsigned int enc_fn_size;
            memcpy(&enc_fn_size, ptr + current_offset, 4);
            entry->filename_size = decrypt_integer_v1(enc_fn_size, &key_v1);
            if (entry->filename_size == 0 || entry->filename_size > 4096) { free(entry); return READ_ERROR; }
            current_offset += 4;
            if (current_offset + entry->filename_size > size) { free(entry); return READ_ERROR; }
            entry->decrypted_filename = malloc(entry->filename_size + 1);
            memcpy(entry->decrypted_filename, ptr + current_offset, entry->filename_size);
            entry->decrypted_filename[entry->filename_size] = '\0';
            current_offset += entry->filename_size;
            if (current_offset + 4 > size) { free(entry->decrypted_filename); free(entry); return READ_ERROR; }
            unsigned int enc_size;
            memcpy(&enc_size, ptr + current_offset, 4);
            entry->size = decrypt_integer_v1(enc_size, &key_v1);
            current_offset += 4;
            entry->data_key = key_v1;
            entry->offset = (ptr - memory) + current_offset;
            current_offset += entry->size;
        } else { // RGSSADv3
            if (current_offset + 16 > size) { free(entry); return READ_ERROR; }
            unsigned int metadata[4];
            memcpy(metadata, ptr + current_offset, 16);
            entry->offset = decrypt_integer_v3(metadata[0], ctx->key_v3);
            if (entry->offset == 0) { free(entry); break; }
            entry->size = decrypt_integer_v3(metadata[1], ctx->key_v3);
            entry->data_key = decrypt_integer_v3(metadata[2], ctx->key_v3);
            entry->filename_size = decrypt_integer_v3(metadata[3], ctx->key_v3);
            current_offset += 16;
            if (entry->filename_size == 0 || entry->filename_size > 4096) { free(entry); return READ_ERROR; }
            if (current_offset + entry->filename_size > size) { free(entry); return READ_ERROR; }
            entry->decrypted_filename = malloc(entry->filename_size + 1);
            memcpy(entry->decrypted_filename, ptr + current_offset, entry->filename_size);
            entry->decrypted_filename[entry->filename_size] = '\0';
            current_offset += entry->filename_size;
        }
        if (entry->offset > ctx->file_size || entry->offset + entry->size > ctx->file_size) {
            free(entry->decrypted_filename); free(entry); return READ_ERROR;
        }
        ctx->plan->entries[ctx->plan->count++] = entry;
    }
    return SUCCESS;
}

static void write_decrypted_file(const char* path, const unsigned char* data, size_t size) {
    FILE* out_file = platform_fopen(path, "wb");
    if (!out_file) sys_fail_helper("Failed to open output file", path);
    if (size > 0) {
        if (fwrite(data, 1, size, out_file) != size) {
            fclose(out_file);
            sys_fail_helper("Failed to write to output file", path);
        }
    }
    fclose(out_file);
}

static int compare_entries_by_offset(const void *a, const void *b) {
    RgssadEntry *entry_a = *(RgssadEntry**)a;
    RgssadEntry *entry_b = *(RgssadEntry**)b;
    if (entry_a->offset < entry_b->offset) return -1;
    if (entry_a->offset > entry_b->offset) return 1;
    return 0;
}

// ============================================================================
// --- Worker Thread and I/O Logic ---
// ============================================================================

// ** REFACTORED TO BE PLATFORM-AGNOSTIC **
// Now that all platforms use a memory-mapped file, the I/O logic is identical.
static void perform_extraction_io(RgssadThreadContext *thread_ctx, RgssadEntry *entry) {
    RgssadContext *ctx = thread_ctx->main_ctx;
    const char *output_path = entry->final_output_path_c;

    if (entry->size > 0) {
        PoolBuffer* pbuf = get_buffer(thread_ctx->pool, entry->size);
        if (!pbuf) {
            ctx->last_error_no = ENOMEM;
            ctx->thread_error_occurred = true;
            return;
        }
        
        // This check is belt-and-suspenders; build_plan_from_memory should prevent this.
        if (entry->offset + entry->size > ctx->file_size) {
            ctx->thread_error_occurred = true;
            return_buffer(pbuf);
            return;
        }

        // Unified, high-performance memory copy for all platforms
        memcpy(pbuf->buffer, ctx->mapped_file + entry->offset, entry->size);
        
        decrypt_file_data(pbuf->buffer, entry->size, entry->data_key);
        write_decrypted_file(output_path, pbuf->buffer, entry->size);
        return_buffer(pbuf);
    } else {
        write_decrypted_file(output_path, NULL, 0);
    }
    if (ctx->verbose) { printf("  Extracted: %s (Thread %d)\n", entry->decrypted_filename, thread_ctx->thread_id); }
}

#ifndef _WIN32
static void* rgssad_worker_thread(void* arg) {
    RgssadThreadContext *thread_ctx = (RgssadThreadContext*)arg;
    RgssadContext *ctx = thread_ctx->main_ctx;
    if (!init_buffer_pool(thread_ctx->pool)) {
        ctx->last_error_no = ENOMEM;
        ctx->thread_error_occurred = true;
        return NULL;
    }
    while (true) {
        if (ctx->thread_error_occurred) break;
        size_t entry_idx;
        pthread_mutex_lock(&ctx->next_entry_mutex);
        if (ctx->next_entry_index >= ctx->plan->count) {
            pthread_mutex_unlock(&ctx->next_entry_mutex);
            break;
        }
        entry_idx = ctx->next_entry_index++;
        pthread_mutex_unlock(&ctx->next_entry_mutex);
        perform_extraction_io(thread_ctx, ctx->plan->entries[entry_idx]);
    }
    free_buffer_pool(thread_ctx->pool);
    return NULL;
}
#endif

// ============================================================================
// --- Thread Orchestration with correct GVL handling --- (Unchanged)
// ============================================================================

#ifndef _WIN32
static void* manage_worker_threads_nogvl(void* arg) {
    RgssadContext *ctx = (RgssadContext*)arg;
    pthread_t *threads = malloc(ctx->num_threads * sizeof(pthread_t));
    if (!threads) { ctx->last_error_no = ENOMEM; ctx->thread_error_occurred = true; return NULL; }
    
    ctx->thread_contexts = calloc(ctx->num_threads, sizeof(RgssadThreadContext));
    if(!ctx->thread_contexts) { free(threads); ctx->last_error_no = ENOMEM; ctx->thread_error_occurred = true; return NULL; }

    for (int i = 0; i < ctx->num_threads; i++) {
        ctx->thread_contexts[i].thread_id = i;
        ctx->thread_contexts[i].main_ctx = ctx;
        if (pthread_create(&threads[i], NULL, rgssad_worker_thread, &ctx->thread_contexts[i]) != 0) {
            ctx->last_error_no = errno;
            ctx->thread_error_occurred = true;
            for (int j = 0; j < i; ++j) { pthread_join(threads[j], NULL); }
            free(threads);
            return NULL;
        }
    }
    for (int i = 0; i < ctx->num_threads; i++) { pthread_join(threads[i], NULL); }
    free(threads);
    return NULL;
}

static void ubf_noop(void* data) {}
#endif

static VALUE execute_extraction_plan(RgssadContext *ctx) {
    qsort(ctx->plan->entries, ctx->plan->count, sizeof(RgssadEntry*), compare_entries_by_offset);

    if (ctx->verbose) printf("(Phase 2a: Pre-processing filenames and paths in main thread)\n");
    unsigned int key_v1 = RGSSADv1_INITIAL_KEY;
    VALUE output_dir_abs_rb = rb_funcall(native_File_module, native_expand_path_id, 1, ctx->output_dir_rb);
    const char *output_dir_abs_c = StringValueCStr(output_dir_abs_rb);

    for (size_t i = 0; i < ctx->plan->count; i++) {
        RgssadEntry *entry = ctx->plan->entries[i];
        char* filename_buffer = entry->decrypted_filename;
        if (ctx->archive_type == RGSSADv1) { decrypt_filename_v1((unsigned char*)filename_buffer, entry->filename_size, &key_v1); }
        else { decrypt_filename_v3((unsigned char*)filename_buffer, entry->filename_size, ctx->key_v3); }
        for (unsigned int j = 0; j < entry->filename_size; ++j) if (filename_buffer[j] == '\\') filename_buffer[j] = '/';
        sanitize_unicode_escapes_in_place(filename_buffer);
        sanitize_path_in_place(filename_buffer);
        if (!is_path_safe_precheck(filename_buffer)) { rb_raise(rm_toolkit_native_Error_class, "Insecure path detected (pre-check failed): %s", filename_buffer); }
        VALUE rb_filename_str = rb_utf8_str_new_cstr(filename_buffer);
        VALUE output_full_path_rb = rb_funcall(native_File_module, native_join_id, 2, ctx->output_dir_rb, rb_filename_str);
        VALUE output_file_abs_rb = rb_funcall(native_File_module, native_expand_path_id, 1, output_full_path_rb);
        const char *output_file_abs_c = StringValueCStr(output_file_abs_rb);
        if (strncmp(output_file_abs_c, output_dir_abs_c, strlen(output_dir_abs_c)) != 0) { rb_raise(rm_toolkit_native_Error_class, "Insecure path detected after canonicalization: %s", filename_buffer); }
        rb_funcall(native_FileUtils_module, native_mkdir_p_id, 1, rb_funcall(native_File_module, native_dirname_id, 1, output_full_path_rb));
        entry->final_output_path_c = strdup(output_file_abs_c);
        if (!entry->final_output_path_c) rb_raise(rb_eNoMemError, "Failed to duplicate final path string.");
    }

    if (ctx->verbose) printf("(Phase 2b: Concurrently extracting %zu files across %d threads)\n", ctx->plan->count, ctx->num_threads);

#ifdef _WIN32
    // Windows multi-threading is more complex to add without extra libraries like PThreads-win32.
    // For now, it will run single-threaded but with high-performance I/O.
    RgssadThreadContext t_ctx = {0};
    t_ctx.thread_id = 0;
    t_ctx.main_ctx = ctx;
    if (!init_buffer_pool(t_ctx.pool)) { rb_raise(rb_eNoMemError, "Failed to initialize buffer pool for Windows."); }
    for(size_t i = 0; i < ctx->plan->count; i++) {
        perform_extraction_io(&t_ctx, ctx->plan->entries[i]);
        if(ctx->thread_error_occurred) break;
    }
    free_buffer_pool(t_ctx.pool);
#else
    ctx->next_entry_index = 0;
    ctx->last_error_no = 0;
    rb_thread_call_without_gvl(manage_worker_threads_nogvl, (void*)ctx, ubf_noop, (void*)ctx);
#endif

    if(ctx->thread_error_occurred) {
        if (ctx->last_error_no != 0) {
            rb_raise(rm_toolkit_native_Error_class, "A worker thread failed: %s", strerror(ctx->last_error_no));
        } else {
            rb_raise(rm_toolkit_native_Error_class, "An unspecified error occurred in a worker thread during extraction.");
        }
    }
    return Qnil;
}

// ============================================================================
// --- Main Orchestrator and Ruby Entry Point ---
// ============================================================================
// ** REFACTORED ORCHESTRATOR **
// Uses memory mapping on all platforms for high performance and cleaner code.
static VALUE rgssad_extraction_orchestrator(VALUE context_val) {
    RgssadContext *ctx = (RgssadContext *)context_val;
    char *target_path_c = StringValueCStr(ctx->target_path_rb);

#ifdef _WIN32
    ctx->h_file = CreateFileA(target_path_c, GENERIC_READ, FILE_SHARE_READ, NULL, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL);
    if (ctx->h_file == INVALID_HANDLE_VALUE) sys_fail_helper("Failed to open input file", target_path_c);
    
    LARGE_INTEGER file_size_li;
    if (!GetFileSizeEx(ctx->h_file, &file_size_li)) { CloseHandle(ctx->h_file); ctx->h_file = NULL; sys_fail_helper("Failed to get file size", target_path_c); }
    ctx->file_size = (size_t)file_size_li.QuadPart;

    ctx->h_map_file = CreateFileMapping(ctx->h_file, NULL, PAGE_READONLY, 0, 0, NULL);
    if (ctx->h_map_file == NULL) { CloseHandle(ctx->h_file); ctx->h_file = NULL; sys_fail_helper("Failed to create file mapping", target_path_c); }

    ctx->mapped_file = (unsigned char*)MapViewOfFile(ctx->h_map_file, FILE_MAP_READ, 0, 0, ctx->file_size);
    if (ctx->mapped_file == NULL) { CloseHandle(ctx->h_map_file); CloseHandle(ctx->h_file); ctx->h_map_file = NULL; ctx->h_file = NULL; sys_fail_helper("Failed to map view of file", target_path_c); }
#else
    int fd = open(target_path_c, O_RDONLY);
    if (fd == -1) sys_fail_helper("Failed to open input file", target_path_c);
    struct stat sb;
    if (fstat(fd, &sb) == -1) { close(fd); sys_fail_helper("Failed to stat input file", target_path_c); }
    ctx->file_size = sb.st_size;
    ctx->mapped_file = mmap(NULL, ctx->file_size, PROT_READ, MAP_PRIVATE, fd, 0);
    close(fd); // fd no longer needed after mmap
    if (ctx->mapped_file == MAP_FAILED) { ctx->mapped_file = NULL; sys_fail_helper("Failed to mmap input file", target_path_c); }
#endif

    if (ctx->file_size < HEADER_SIZE) rb_raise(rm_toolkit_native_Error_class, "File is too small to be a valid archive");
    
    const unsigned char *header_ptr = ctx->mapped_file;
    const unsigned char *data_ptr = header_ptr;
    
    if (memcmp(header_ptr, "RGSSAD\x00\x01", HEADER_SIZE) == 0) {
        ctx->archive_type = RGSSADv1;
        data_ptr += HEADER_SIZE;
    } else if (memcmp(header_ptr, "RGSSAD\x00\x03", HEADER_SIZE) == 0) {
        ctx->archive_type = RGSSADv3;
        data_ptr += HEADER_SIZE;
        if (ctx->file_size < HEADER_SIZE + V3_SEED_SIZE) rb_raise(rm_toolkit_native_Error_class, "Truncated v3 archive: missing seed");
        unsigned int seed;
        memcpy(&seed, data_ptr, V3_SEED_SIZE);
        data_ptr += V3_SEED_SIZE;
        ctx->key_v3 = seed * 9 + 3;
    } else if (memcmp(header_ptr, "Fux2Pack", FUX2PACK2_HEADER_HINT_SIZE) == 0) {
        ctx->archive_type = FUX2PACK2;
        data_ptr += FUX2PACK2_HEADER_HINT_SIZE;
        if (ctx->file_size < FUX2PACK2_HEADER_HINT_SIZE + V3_SEED_SIZE) rb_raise(rm_toolkit_native_Error_class, "Truncated Fux2Pack2 archive: missing seed");
        memcpy(&ctx->key_v3, data_ptr, V3_SEED_SIZE);
        data_ptr += V3_SEED_SIZE;
    } else {
        rb_raise(rm_toolkit_native_Error_class, "Unknown or invalid archive header");
    }

    ctx->plan = calloc(1, sizeof(RgssadExtractionPlan));
    if (!ctx->plan) { rb_raise(rb_eNoMemError, "Failed to allocate extraction plan."); }
    
    ctx->thread_error_occurred = false;
#ifndef _WIN32
    pthread_mutex_init(&ctx->next_entry_mutex, NULL);
#endif
    
    if (ctx->verbose) printf("Processing %s...\n(Phase 1: Building plan from memory...)\n", target_path_c);
    
    int status = build_plan_from_memory(ctx, data_ptr, ctx->file_size - (data_ptr - header_ptr));
    if (status != SUCCESS) { rb_raise(rm_toolkit_native_Error_class, status == READ_ERROR ? "Failed to read entry metadata from archive" : "Failed to allocate memory for plan."); }

#ifdef _WIN32
    SYSTEM_INFO si; GetSystemInfo(&si); ctx->num_threads = si.dwNumberOfProcessors;
#else
    ctx->num_threads = sysconf(_SC_NPROCESSORS_ONLN);
#endif
    if (ctx->num_threads <= 0) ctx->num_threads = 1;
    
    execute_extraction_plan(ctx);
    
    return Qnil;
}

VALUE native_extract_rgssad(VALUE self, VALUE target_path_rb, VALUE output_dir_rb, VALUE verbose_rb) {
    RgssadContext context = {0};
    context.target_path_rb = target_path_rb;
    context.output_dir_rb = output_dir_rb;
    context.verbose = RTEST(verbose_rb);
    return rb_ensure(rgssad_extraction_orchestrator, (VALUE)&context, rgssad_cleanup, (VALUE)&context);
}

// ============================================================================
// --- RPG Maker MV/MZ File Decryption ---
// ============================================================================
#define MV_MZ_HEADER_SIZE 16
typedef struct { FILE *inf, *outf; unsigned char *buf; VALUE in_rb, out_rb, key_rb; } MvMzContext;
static void mv_mz_context_free(void *p) { MvMzContext *c=(MvMzContext*)p; if(c){if(c->inf)fclose(c->inf);if(c->outf)fclose(c->outf);free(c->buf);free(c);}}
static const rb_data_type_t mv_mz_context_data_type = {"RmToolkit/MvMzContext",{0,mv_mz_context_free,0,},0,0,RUBY_TYPED_FREE_IMMEDIATELY};

// ** REFACTORED FOR READABILITY **
static VALUE mv_mz_decryption_body(VALUE ctx_val) {
    MvMzContext* c;
    TypedData_Get_Struct(ctx_val, MvMzContext, &mv_mz_context_data_type, c);

    char* in_c = StringValueCStr(c->in_rb);
    char* out_c = StringValueCStr(c->out_rb);
    const char* key_c = RSTRING_PTR(c->key_rb);
    long key_len = RSTRING_LEN(c->key_rb);

    if (key_len != 16) {
        rb_raise(rb_eArgError, "Key must be 16 bytes");
    }

    c->inf = platform_fopen(in_c, "rb");
    if (!c->inf) {
        sys_fail_helper("Failed to open input", in_c);
    }

    fseek(c->inf, 0, SEEK_END);
    long f_size = ftell(c->inf);
    fseek(c->inf, 0, SEEK_SET);

    if (f_size < MV_MZ_HEADER_SIZE) {
        rb_raise(rb_eIOError, "File too small");
    }
    if (fseek(c->inf, MV_MZ_HEADER_SIZE, SEEK_SET) != 0) {
        sys_fail_helper("Seek failed", in_c);
    }
    
    size_t cont_size = (size_t)(f_size - MV_MZ_HEADER_SIZE);
    if (cont_size == 0) {
        c->outf = platform_fopen(out_c, "wb");
        if (!c->outf) sys_fail_helper("Failed to create empty output", out_c);
        return Qnil; // Empty file created, we are done.
    }

    c->buf = malloc(cont_size);
    if (!c->buf) {
        rb_raise(rb_eNoMemError, "Allocation failed");
    }
    if (fread(c->buf, 1, cont_size, c->inf) != cont_size) {
        sys_fail_helper("Read failed", in_c);
    }

    size_t xor_len = (cont_size < 16) ? cont_size : 16;
    for (size_t i = 0; i < xor_len; ++i) {
        c->buf[i] ^= (unsigned char)key_c[i];
    }

    write_decrypted_file(out_c, c->buf, cont_size);
    return Qnil;
}

static VALUE mv_mz_dummy_cleanup(VALUE context_val) { return Qnil; }

VALUE native_decrypt_mv_mz(VALUE self, VALUE in_rb, VALUE out_rb, VALUE key_rb) {
    Check_Type(in_rb, T_STRING); Check_Type(out_rb, T_STRING); Check_Type(key_rb, T_STRING);
    MvMzContext* c = malloc(sizeof(MvMzContext));
    if (!c) rb_raise(rb_eNoMemError, "Context allocation failed");
    memset(c, 0, sizeof(MvMzContext));
    c->in_rb = in_rb; c->out_rb = out_rb; c->key_rb = key_rb;
    VALUE v = TypedData_Wrap_Struct(rb_cObject, &mv_mz_context_data_type, c);
    return rb_ensure(mv_mz_decryption_body, v, mv_mz_dummy_cleanup, v);
}

// ============================================================================
// --- Ruby Extension Initializer ---
// ============================================================================
void Init_native() {
#ifdef _WIN32
    setlocale(LC_ALL, ".utf-8");
    SetConsoleOutputCP(CP_UTF8);
    SetConsoleCP(CP_UTF8);
#endif
    RmToolkitNative_module = rb_define_module("RmToolkitNative");
    native_File_module = rb_const_get(rb_cObject, rb_intern("File"));
    native_FileUtils_module = rb_const_get(rb_cObject, rb_intern("FileUtils"));
    ID error_id = rb_intern("Error");
    rm_toolkit_native_Error_class = rb_const_defined(RmToolkitNative_module, error_id) ? rb_const_get(RmToolkitNative_module, error_id) : rb_define_class_under(RmToolkitNative_module, "Error", rb_eStandardError);
    native_join_id = rb_intern("join"); native_dirname_id = rb_intern("dirname"); native_mkdir_p_id = rb_intern("mkdir_p"); native_expand_path_id = rb_intern("expand_path");
    
    rb_define_singleton_method(RmToolkitNative_module, "extract_rgssad", native_extract_rgssad, 3);
    rb_define_singleton_method(RmToolkitNative_module, "decrypt_mv_mz", native_decrypt_mv_mz, 3);

    // --- SIMD Decryption Function Selection with Clear Logging ---
#if (defined(__GNUC__) || defined(__clang__))
    #if defined(__AVX2__)
        if (__builtin_cpu_supports("avx2")) {
            g_decrypt_func = decrypt_file_data_avx2_parallel;
            printf("[RmToolkitNative] INFO: CPU supports AVX2. Using AVX2-optimized decryption.\n");
        } else
    #endif
    {
        g_decrypt_func = decrypt_file_data_scalar_wrapper;
        printf("[RmToolkitNative] INFO: AVX2 not supported by CPU. Using standard scalar decryption.\n");
    }
#else
    // Fallback for other compilers like MSVC, which rely on compile-time flags.
    #if defined(__AVX2__)
        g_decrypt_func = decrypt_file_data_avx2_parallel;
        printf("[RmToolkitNative] INFO: Compiled with AVX2 support. Using AVX2-optimized decryption.\n");
    #else
        g_decrypt_func = decrypt_file_data_scalar_wrapper;
        printf("[RmToolkitNative] INFO: Compiled without AVX2 support. Using standard scalar decryption.\n");
    #endif
#endif
    fflush(stdout);
}