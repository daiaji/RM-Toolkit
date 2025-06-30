#include "ruby.h"
#include <errno.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// --- Platform Specific Includes ---
#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#include <wchar.h>
#include <windows.h>
#else
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/mman.h> // For mmap
#include <fcntl.h>    // For O_RDONLY
#include <unistd.h>
#include <pthread.h>
#endif

// --- SIMD Intrinsics Includes ---
#if defined(__AVX512F__) || defined(__AVX2__)
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
// --- Utility Functions ---
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

FILE *platform_fopen(const char *utf8_path, const char *mode) {
#ifdef _WIN32
  int required_size = MultiByteToWideChar(CP_UTF8, 0, utf8_path, -1, NULL, 0);
  if (required_size <= 0) {
    errno = EILSEQ;
    return NULL;
  }
  wchar_t *w_path = (wchar_t *)malloc(required_size * sizeof(wchar_t));
  if (!w_path) {
      errno = ENOMEM;
      return NULL;
  }
  if (!MultiByteToWideChar(CP_UTF8, 0, utf8_path, -1, w_path, required_size)) {
    free(w_path);
    errno = EILSEQ;
    return NULL;
  }
  wchar_t w_mode[10] = {0};
  mbstowcs(w_mode, mode, (sizeof(w_mode) / sizeof(wchar_t)) - 1);
  FILE* file = _wfopen(w_path, w_mode);
  free(w_path);
  return file;
#else
  return fopen(utf8_path, mode);
#endif
}

// ============================================================================
// --- RGSSAD Decryption Logic ---
// ============================================================================
#define MOD_4_MASK 0b11
enum RGSSAD_TYPE { UNKNOWN_ARCHIVE, RGSSADv1, RGSSADv3 };
#define RGSSADv1_INITIAL_KEY 0xDEADCAFE
#define HEADER_SIZE 8
#define V3_SEED_SIZE 4

unsigned int decrypt_integer_v1(unsigned int encrypted_val, unsigned int *key) {
  unsigned int decrypted_val = encrypted_val ^ (*key);
  *key = (*key) * 7 + 3;
  return decrypted_val;
}
void decrypt_filename_v1(unsigned char *data, size_t n, unsigned int *key) {
  for (size_t i = 0; i < n; ++i) {
    data[i] ^= ((*key) & 0xFF);
    *key = (*key) * 7 + 3;
  }
}

unsigned int decrypt_integer_v3(unsigned int encrypted_val, unsigned int key) { return encrypted_val ^ key; }
void decrypt_filename_v3(unsigned char *data, size_t n, unsigned int key) {
  size_t q = n >> 2; int r = n & MOD_4_MASK;
  unsigned int *data_p = (unsigned int *)data;
  for (size_t i = 0; i < q; ++i) data_p[i] ^= key;
  unsigned char *remainder_p = (unsigned char *)(data_p + q);
  if (r > 0) {
    unsigned char* key_bytes = (unsigned char*)&key;
    for (int i = 0; i < r; ++i) remainder_p[i] ^= key_bytes[i];
  }
}

// ============================================================================
// --- Data Decryption (Runtime SIMD Dispatch + Alignment Optimizations) ---
// ============================================================================
typedef void (*decrypt_func_t)(unsigned char*, size_t, unsigned int);
static decrypt_func_t g_decrypt_func = NULL;

static void decrypt_file_data_scalar(unsigned char *data, size_t n, unsigned int key) {
  size_t q = n >> 2; int r = n & MOD_4_MASK;
  unsigned int *data_p = (unsigned int *)data;
  for (size_t i = 0; i < q; ++i) {
    data_p[i] ^= key;
    key = key * 7 + 3;
  }
  if (r > 0) {
    unsigned char *remainder_p = (unsigned char *)(data_p + q);
    unsigned char *key_bytes = (unsigned char *)&key;
    for (int i = 0; i < r; ++i) remainder_p[i] ^= key_bytes[i];
  }
}

#if defined(__AVX512F__)
#define VEC_SIZE_AVX512 16
#define MOD_64_MASK 0x3F
#if __STDC_VERSION__ >= 201112L
_Alignas(64)
#elif defined(__GNUC__) || defined(__clang__)
__attribute__((aligned(64)))
#endif
static const unsigned int POWERS_OF_7_AVX512[VEC_SIZE_AVX512] = { 1, 7, 49, 343, 2401, 16807, 117649, 823543, 5764801, 40353607, 282475249, 1977326743, 13841287201 & 0xFFFFFFFF, 96888910407 & 0xFFFFFFFF, 678222372849 & 0xFFFFFFFF, 4747556609943 & 0xFFFFFFFF };
#if __STDC_VERSION__ >= 201112L
_Alignas(64)
#elif defined(__GNUC__) || defined(__clang__)
__attribute__((aligned(64)))
#endif
static const unsigned int GEOMETRIC_SUMS_AVX512[VEC_SIZE_AVX512] = { 0, 3, 24, 171, 1200, 8403, 58824, 411771, 2882390, 20176743, 141237204, 988660431, 6920623010 & 0xFFFFFFFF, 48444361083 & 0xFFFFFFFF, 339110527584 & 0xFFFFFFFF, 2373773693091 & 0xFFFFFFFF };
#define POWER_OF_7_STEP_AVX512 (4747556609943 * 7 + 3) & 0xFFFFFFFF
#define GEOMETRIC_SUM_STEP_AVX512 (2373773693091 * 7 + 3) & 0xFFFFFFFF
_Static_assert(sizeof(POWERS_OF_7_AVX512) == sizeof(unsigned int) * VEC_SIZE_AVX512, "AVX512 powers table size mismatch");

__attribute__((target("avx512f")))
static void decrypt_file_data_avx512_parallel(unsigned char* data, size_t n, unsigned int key) {
    const __m512i v_powers = _mm512_load_si512((const __m512i*)POWERS_OF_7_AVX512);
    const __m512i v_geometrics = _mm512_load_si512((const __m512i*)GEOMETRIC_SUMS_AVX512);
    size_t offset = 0;
    if (((uintptr_t)data & MOD_64_MASK) != 0) {
        offset = 64 - ((uintptr_t)data & MOD_64_MASK);
        if (offset > n) offset = n;
        decrypt_file_data_scalar(data, offset, key);
        key = key * POWERS_OF_7_AVX512[offset/4] + GEOMETRIC_SUMS_AVX512[offset/4];
    }
    const size_t q = (n - offset) >> 6;
    const int r = (n - offset) & MOD_64_MASK;
    __m512i* data_p = (__m512i*)(data + offset);
    for (size_t i = 0; i < q; ++i) {
        __m512i v_key_base = _mm512_set1_epi32(key);
        __m512i v_keys = _mm512_add_epi32(_mm512_mullo_epi32(v_key_base, v_powers), v_geometrics);
        __m512i v_data = _mm512_load_si512(data_p);
        v_data = _mm512_xor_si512(v_data, v_keys);
        _mm512_store_si512(data_p, v_data);
        data_p++;
        key = key * POWER_OF_7_STEP_AVX512 + GEOMETRIC_SUM_STEP_AVX512;
    }
    if (r > 0) {
        decrypt_file_data_scalar((unsigned char*)data_p, (size_t)r, key);
    }
}
#endif

#if defined(__AVX2__)
#define VEC_SIZE_AVX2 8
#define MOD_32_MASK 0x1F
#if __STDC_VERSION__ >= 201112L
_Alignas(32)
#elif defined(__GNUC__) || defined(__clang__)
__attribute__((aligned(32)))
#endif
static const unsigned int POWERS_OF_7_AVX2[VEC_SIZE_AVX2] = { 1, 7, 49, 343, 2401, 16807, 117649, 823543 };
#if __STDC_VERSION__ >= 201112L
_Alignas(32)
#elif defined(__GNUC__) || defined(__clang__)
__attribute__((aligned(32)))
#endif
static const unsigned int GEOMETRIC_SUMS_AVX2[VEC_SIZE_AVX2] = { 0, 3, 24, 171, 1200, 8403, 58824, 411771 };
#define POWER_OF_7_STEP_AVX2 5764801
#define GEOMETRIC_SUM_STEP_AVX2 2882390
_Static_assert(sizeof(POWERS_OF_7_AVX2) == sizeof(unsigned int) * VEC_SIZE_AVX2, "AVX2 powers table size mismatch");

__attribute__((target("avx2")))
static void decrypt_file_data_avx2_parallel(unsigned char* data, size_t n, unsigned int key) {
    const __m256i v_powers = _mm256_load_si256((const __m256i*)POWERS_OF_7_AVX2);
    const __m256i v_geometrics = _mm256_load_si256((const __m256i*)GEOMETRIC_SUMS_AVX2);
    size_t offset = 0;
    if (((uintptr_t)data & MOD_32_MASK) != 0) {
        offset = 32 - ((uintptr_t)data & MOD_32_MASK);
        if (offset > n) offset = n;
        decrypt_file_data_scalar(data, offset, key);
        key = key * POWERS_OF_7_AVX2[offset/4] + GEOMETRIC_SUMS_AVX2[offset/4];
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

void decrypt_file_data(unsigned char *data, size_t n, unsigned int key) {
    g_decrypt_func(data, n, key);
}

// ============================================================================
// --- RGSSAD Extraction Logic (Refactored for mmap Parallel I/O) ---
// ============================================================================
enum EntryReadStatus { SUCCESS = 0, END_OF_FILE = 1, READ_ERROR = -1, ALLOC_ERROR = -2 };

typedef struct {
    unsigned int offset;
    unsigned int size;
    unsigned int data_key;
    unsigned int filename_size;
    char *decrypted_filename;
    char *final_output_path_c;
} RgssadEntry;

typedef struct {
    RgssadEntry **entries;
    size_t count;
    size_t capacity;
} RgssadExtractionPlan;

struct RgssadContext;

typedef struct {
    int thread_id;
    struct RgssadContext *main_ctx;
    unsigned char *reusable_buffer;
    size_t buffer_capacity;
} RgssadThreadContext;

typedef struct RgssadContext {
    VALUE target_path_rb;
    VALUE output_dir_rb;
    bool verbose;
    RgssadExtractionPlan *plan;
    
#ifndef _WIN32
    unsigned char *mapped_file;
    size_t file_size;
#endif

    enum RGSSAD_TYPE archive_type;
    unsigned int key_v3;
    int num_threads;
    bool thread_error_occurred;
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

static VALUE rgssad_cleanup(VALUE context_val) {
    RgssadContext *ctx = (RgssadContext *)context_val;
    free_extraction_plan(ctx->plan);
    if (ctx->thread_contexts) {
        for (int i = 0; i < ctx->num_threads; i++) {
            free(ctx->thread_contexts[i].reusable_buffer);
        }
        free(ctx->thread_contexts);
    }
#ifndef _WIN32
    if (ctx->mapped_file) {
        munmap(ctx->mapped_file, ctx->file_size);
    }
    pthread_mutex_destroy(&ctx->next_entry_mutex);
#endif
    return Qnil;
}

// --- 修复: 将这些函数包裹起来，只为 Windows 编译 ---
#ifdef _WIN32
static int read_rgssad_v1_entry_from_file(FILE *input_file, RgssadEntry *entry, unsigned int *key) {
    unsigned int encrypted_val;
    if (fread(&encrypted_val, sizeof(int), 1, input_file) != 1) return feof(input_file) ? END_OF_FILE : READ_ERROR;
    entry->filename_size = decrypt_integer_v1(encrypted_val, key);
    if (entry->filename_size == 0 || entry->filename_size > 4096) return READ_ERROR;
    
    entry->decrypted_filename = malloc(entry->filename_size + 1);
    if (!entry->decrypted_filename) return ALLOC_ERROR;
    if (fread(entry->decrypted_filename, 1, entry->filename_size, input_file) != entry->filename_size) { free(entry->decrypted_filename); return READ_ERROR; }
    entry->decrypted_filename[entry->filename_size] = '\0';
    
    if (fread(&encrypted_val, sizeof(int), 1, input_file) != 1) { free(entry->decrypted_filename); return READ_ERROR; }
    entry->size = decrypt_integer_v1(encrypted_val, key);
    entry->data_key = *key;
    entry->offset = ftell(input_file);
    return SUCCESS;
}

static int read_rgssad_v3_entry_from_file(FILE *input_file, RgssadEntry *entry, unsigned int key) {
    unsigned int metadata_block[4];
    if (fread(metadata_block, sizeof(int), 4, input_file) != 4) return feof(input_file) ? END_OF_FILE : READ_ERROR;
    entry->offset = decrypt_integer_v3(metadata_block[0], key);
    if (entry->offset == 0) return END_OF_FILE;
    entry->size = decrypt_integer_v3(metadata_block[1], key);
    entry->data_key = decrypt_integer_v3(metadata_block[2], key);
    entry->filename_size = decrypt_integer_v3(metadata_block[3], key);
    if (entry->filename_size == 0 || entry->filename_size > 4096) return READ_ERROR;

    entry->decrypted_filename = malloc(entry->filename_size + 1);
    if (!entry->decrypted_filename) return ALLOC_ERROR;
    if (fread(entry->decrypted_filename, 1, entry->filename_size, input_file) != entry->filename_size) { free(entry->decrypted_filename); return READ_ERROR; }
    entry->decrypted_filename[entry->filename_size] = '\0';
    return SUCCESS;
}

static int build_extraction_plan(RgssadContext *ctx, FILE *main_file) {
    unsigned int key_v1 = RGSSADv1_INITIAL_KEY;
    while(1) {
        if (ctx->plan->count >= ctx->plan->capacity) {
            size_t new_capacity = ctx->plan->capacity == 0 ? 256 : ctx->plan->capacity * 2;
            RgssadEntry **new_entries = realloc(ctx->plan->entries, new_capacity * sizeof(RgssadEntry*));
            if (!new_entries) return ALLOC_ERROR;
            ctx->plan->entries = new_entries;
            ctx->plan->capacity = new_capacity;
        }
        
        RgssadEntry *entry = calloc(1, sizeof(RgssadEntry));
        if (!entry) return ALLOC_ERROR;

        int status;
        long metadata_pos = ftell(main_file);
        if (ctx->archive_type == RGSSADv1) {
            status = read_rgssad_v1_entry_from_file(main_file, entry, &key_v1);
        } else {
            status = read_rgssad_v3_entry_from_file(main_file, entry, ctx->key_v3);
        }

        if (status == END_OF_FILE) { free(entry); break; }
        if (status != SUCCESS) { free(entry->decrypted_filename); free(entry); return status; }
        
        ctx->plan->entries[ctx->plan->count++] = entry;

        if (ctx->archive_type == RGSSADv1) {
            fseek(main_file, entry->offset + entry->size, SEEK_SET);
        } else {
            fseek(main_file, metadata_pos + (sizeof(unsigned int) * 4) + entry->filename_size, SEEK_SET);
        }
    }
    return SUCCESS;
}
#endif

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

static void perform_extraction_io(RgssadThreadContext *thread_ctx, RgssadEntry *entry) {
    RgssadContext *ctx = thread_ctx->main_ctx;
    const char *output_path = entry->final_output_path_c;

    if (entry->size > 0) {
        if (entry->size > thread_ctx->buffer_capacity) {
            unsigned char* new_buffer = realloc(thread_ctx->reusable_buffer, entry->size);
            if (!new_buffer) { ctx->thread_error_occurred = true; return; }
            thread_ctx->reusable_buffer = new_buffer;
            thread_ctx->buffer_capacity = entry->size;
        }

#ifndef _WIN32
        if (entry->offset + entry->size > ctx->file_size) {
            ctx->thread_error_occurred = true;
            return;
        }
        memcpy(thread_ctx->reusable_buffer, ctx->mapped_file + entry->offset, entry->size);
#else
        FILE* file = platform_fopen(StringValueCStr(ctx->target_path_rb), "rb");
        if (!file) { ctx->thread_error_occurred = true; return; }
        if (fseek(file, (long)entry->offset, SEEK_SET) != 0) { fclose(file); ctx->thread_error_occurred = true; return; }
        if (fread(thread_ctx->reusable_buffer, 1, entry->size, file) != entry->size) { fclose(file); ctx->thread_error_occurred = true; return; }
        fclose(file);
#endif
        
        decrypt_file_data(thread_ctx->reusable_buffer, entry->size, entry->data_key);
        write_decrypted_file(output_path, thread_ctx->reusable_buffer, entry->size);
    } else {
        write_decrypted_file(output_path, NULL, 0);
    }
    
    if (ctx->verbose) { printf("  Extracted: %s (Thread %d)\n", entry->decrypted_filename, thread_ctx->thread_id); }
}

#ifndef _WIN32
static void* rgssad_worker_thread(void* arg) {
    RgssadThreadContext *thread_ctx = (RgssadThreadContext*)arg;
    RgssadContext *ctx = thread_ctx->main_ctx;

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
    return NULL;
}
#endif

static int compare_entries_by_offset(const void *a, const void *b) {
    RgssadEntry *entry_a = *(RgssadEntry**)a;
    RgssadEntry *entry_b = *(RgssadEntry**)b;
    if (entry_a->offset < entry_b->offset) return -1;
    if (entry_a->offset > entry_b->offset) return 1;
    return 0;
}

static VALUE execute_extraction_plan(RgssadContext *ctx) {
    qsort(ctx->plan->entries, ctx->plan->count, sizeof(RgssadEntry*), compare_entries_by_offset);

    if (ctx->verbose) printf("(Phase 2a: Pre-processing filenames and paths in main thread)\n");
    unsigned int key_v1 = RGSSADv1_INITIAL_KEY;
    VALUE output_dir_abs_rb = rb_funcall(native_File_module, native_expand_path_id, 1, ctx->output_dir_rb);
    const char *output_dir_abs_c = StringValueCStr(output_dir_abs_rb);

    for (size_t i = 0; i < ctx->plan->count; i++) {
        RgssadEntry *entry = ctx->plan->entries[i];
        char* filename_buffer = entry->decrypted_filename;

        if (ctx->archive_type == RGSSADv1) {
            decrypt_filename_v1((unsigned char*)filename_buffer, entry->filename_size, &key_v1);
        } else {
            decrypt_filename_v3((unsigned char*)filename_buffer, entry->filename_size, ctx->key_v3);
        }
        for (unsigned int j = 0; j < entry->filename_size; ++j) if (filename_buffer[j] == '\\') filename_buffer[j] = '/';
        sanitize_unicode_escapes_in_place(filename_buffer);
        sanitize_path_in_place(filename_buffer);

        if (!is_path_safe_precheck(filename_buffer)) {
            rb_raise(rm_toolkit_native_Error_class, "Insecure path detected (pre-check failed): %s", filename_buffer);
        }

        VALUE rb_filename_str = rb_utf8_str_new_cstr(filename_buffer);
        VALUE output_full_path_rb = rb_funcall(native_File_module, native_join_id, 2, ctx->output_dir_rb, rb_filename_str);
        
        VALUE output_file_abs_rb = rb_funcall(native_File_module, native_expand_path_id, 1, output_full_path_rb);
        const char *output_file_abs_c = StringValueCStr(output_file_abs_rb);
        if (strncmp(output_file_abs_c, output_dir_abs_c, strlen(output_dir_abs_c)) != 0) {
            rb_raise(rm_toolkit_native_Error_class, "Insecure path detected after canonicalization: %s", filename_buffer);
        }

        rb_funcall(native_FileUtils_module, native_mkdir_p_id, 1, rb_funcall(native_File_module, native_dirname_id, 1, output_full_path_rb));
        
        entry->final_output_path_c = strdup(output_file_abs_c);
        if (!entry->final_output_path_c) rb_raise(rb_eNoMemError, "Failed to duplicate final path string.");
    }

    if (ctx->verbose) printf("(Phase 2b: Concurrently extracting %zu files across %d threads)\n", ctx->plan->count, ctx->num_threads);

#ifdef _WIN32
    RgssadThreadContext t_ctx;
    t_ctx.thread_id = 0;
    t_ctx.main_ctx = ctx;
    t_ctx.reusable_buffer = NULL;
    t_ctx.buffer_capacity = 0;
    for(size_t i = 0; i < ctx->plan->count; i++) {
        perform_extraction_io(&t_ctx, ctx->plan->entries[i]);
        if(ctx->thread_error_occurred) break;
    }
    free(t_ctx.reusable_buffer);
#else
    pthread_t threads[ctx->num_threads];
    ctx->next_entry_index = 0;
    
    ctx->thread_contexts = calloc(ctx->num_threads, sizeof(RgssadThreadContext));
    if(!ctx->thread_contexts) rb_raise(rb_eNoMemError, "Failed to allocate thread contexts");

    for (int i = 0; i < ctx->num_threads; i++) {
        ctx->thread_contexts[i].thread_id = i;
        ctx->thread_contexts[i].main_ctx = ctx;
        ctx->thread_contexts[i].reusable_buffer = NULL;
        ctx->thread_contexts[i].buffer_capacity = 0;
        if (pthread_create(&threads[i], NULL, rgssad_worker_thread, &ctx->thread_contexts[i]) != 0) {
            rb_sys_fail("Failed to create thread");
        }
    }
    for (int i = 0; i < ctx->num_threads; i++) {
        pthread_join(threads[i], NULL);
    }
#endif
    if(ctx->thread_error_occurred) rb_raise(rm_toolkit_native_Error_class, "An error occurred in a worker thread during extraction.");
    return Qnil;
}

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
            unsigned int enc_fn_size;
            memcpy(&enc_fn_size, ptr + current_offset, 4);
            entry->filename_size = decrypt_integer_v1(enc_fn_size, &key_v1);
            if (entry->filename_size == 0 || entry->filename_size > 4096) { free(entry); return READ_ERROR; }
            current_offset += 4;
            
            entry->decrypted_filename = malloc(entry->filename_size + 1);
            memcpy(entry->decrypted_filename, ptr + current_offset, entry->filename_size);
            entry->decrypted_filename[entry->filename_size] = '\0';
            current_offset += entry->filename_size;

            unsigned int enc_size;
            memcpy(&enc_size, ptr + current_offset, 4);
            entry->size = decrypt_integer_v1(enc_size, &key_v1);
            current_offset += 4;

            entry->data_key = key_v1;
            entry->offset = (ptr - memory) + current_offset;
            current_offset += entry->size;
        } else {
            unsigned int metadata[4];
            memcpy(metadata, ptr + current_offset, 16);
            entry->offset = decrypt_integer_v3(metadata[0], ctx->key_v3);
            if (entry->offset == 0) { free(entry); break; }
            entry->size = decrypt_integer_v3(metadata[1], ctx->key_v3);
            entry->data_key = decrypt_integer_v3(metadata[2], ctx->key_v3);
            entry->filename_size = decrypt_integer_v3(metadata[3], ctx->key_v3);
            current_offset += 16;
            
            if (entry->filename_size == 0 || entry->filename_size > 4096) { free(entry); return READ_ERROR; }
            entry->decrypted_filename = malloc(entry->filename_size + 1);
            memcpy(entry->decrypted_filename, ptr + current_offset, entry->filename_size);
            entry->decrypted_filename[entry->filename_size] = '\0';
            current_offset += entry->filename_size;
        }
        ctx->plan->entries[ctx->plan->count++] = entry;
    }
    return SUCCESS;
}

static VALUE rgssad_extraction_orchestrator(VALUE context_val) {
    RgssadContext *ctx = (RgssadContext *)context_val;
    char *target_path_c = StringValueCStr(ctx->target_path_rb);
    
#ifndef _WIN32
    int fd = open(target_path_c, O_RDONLY);
    if (fd == -1) sys_fail_helper("Failed to open input file", target_path_c);
    struct stat sb;
    if (fstat(fd, &sb) == -1) { close(fd); sys_fail_helper("Failed to stat input file", target_path_c); }
    ctx->file_size = sb.st_size;
    ctx->mapped_file = mmap(NULL, ctx->file_size, PROT_READ, MAP_PRIVATE, fd, 0);
    if (ctx->mapped_file == MAP_FAILED) { close(fd); sys_fail_helper("Failed to mmap input file", target_path_c); }
    close(fd);

    const unsigned char *header_ptr = ctx->mapped_file;
    const unsigned char *data_ptr = header_ptr;
#else
    FILE* main_file = platform_fopen(target_path_c, "rb");
    if(!main_file) sys_fail_helper("Failed to open input file", target_path_c);
#endif
    
    unsigned char header[HEADER_SIZE];
#ifndef _WIN32
    if (ctx->file_size < HEADER_SIZE) { munmap(ctx->mapped_file, ctx->file_size); rb_raise(rm_toolkit_native_Error_class, "File is too small"); }
    memcpy(header, header_ptr, HEADER_SIZE);
    data_ptr += HEADER_SIZE;
#else
    if(fread(header, 1, HEADER_SIZE, main_file) < HEADER_SIZE) { fclose(main_file); rb_raise(rm_toolkit_native_Error_class, "File is too small"); }
#endif

    enum RGSSAD_TYPE archive_type = UNKNOWN_ARCHIVE;
    unsigned int metadata_key_v3 = 0;
    if (memcmp(header, "RGSSAD\x00\x01", HEADER_SIZE) == 0) { archive_type = RGSSADv1; }
    else if (memcmp(header, "RGSSAD\x00\x03", HEADER_SIZE) == 0) {
        archive_type = RGSSADv3;
        unsigned int seed;
#ifndef _WIN32
        if (ctx->file_size < HEADER_SIZE + V3_SEED_SIZE) { munmap(ctx->mapped_file, ctx->file_size); rb_raise(rm_toolkit_native_Error_class, "Truncated v3 archive"); }
        memcpy(&seed, data_ptr, V3_SEED_SIZE);
        data_ptr += V3_SEED_SIZE;
#else
        if(fread(&seed, 1, V3_SEED_SIZE, main_file) < V3_SEED_SIZE) { fclose(main_file); rb_raise(rm_toolkit_native_Error_class, "Truncated v3 archive"); }
#endif
        metadata_key_v3 = seed * 9 + 3;
    } else {
#ifndef _WIN32
        munmap(ctx->mapped_file, ctx->file_size);
        ctx->mapped_file = NULL;
#else
        fclose(main_file);
#endif
        rb_raise(rm_toolkit_native_Error_class, "Unknown or invalid archive header");
    }
    
    ctx->archive_type = archive_type;
    ctx->key_v3 = metadata_key_v3;
    ctx->plan = calloc(1, sizeof(RgssadExtractionPlan));
    if (!ctx->plan) { rb_raise(rb_eNoMemError, "Failed to allocate extraction plan."); }
    ctx->thread_error_occurred = false;

#ifndef _WIN32
    pthread_mutex_init(&ctx->next_entry_mutex, NULL);
#endif

    if (ctx->verbose) printf("Processing %s...\n(Phase 1: Building plan from memory)\n", target_path_c);
#ifndef _WIN32
    int status = build_plan_from_memory(ctx, data_ptr, ctx->file_size - (data_ptr - header_ptr));
#else
    int status = build_extraction_plan(ctx, main_file);
    fclose(main_file);
#endif
    if (status != SUCCESS) { rb_raise(rm_toolkit_native_Error_class, status == READ_ERROR ? "Failed to read entry metadata" : "Failed to allocate memory for plan."); }
    
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
static VALUE mv_mz_decryption_body(VALUE ctx_val) { MvMzContext*c;TypedData_Get_Struct(ctx_val,MvMzContext,&mv_mz_context_data_type,c);char*in_c=StringValueCStr(c->in_rb);char*out_c=StringValueCStr(c->out_rb);const char*key_c=RSTRING_PTR(c->key_rb);long key_len=RSTRING_LEN(c->key_rb);if(key_len!=16)rb_raise(rb_eArgError,"Key must be 16 bytes");c->inf=platform_fopen(in_c,"rb");if(!c->inf)sys_fail_helper("Failed to open input",in_c);fseek(c->inf,0,SEEK_END);long f_size=ftell(c->inf);fseek(c->inf,0,SEEK_SET);if(f_size<MV_MZ_HEADER_SIZE)rb_raise(rb_eIOError,"File too small");if(fseek(c->inf,MV_MZ_HEADER_SIZE,SEEK_SET)!=0)sys_fail_helper("Seek failed",in_c);size_t cont_size=(size_t)(f_size-MV_MZ_HEADER_SIZE);if(cont_size==0){c->outf=platform_fopen(out_c,"wb");if(!c->outf)sys_fail_helper("Failed to create empty output",out_c);return Qnil;}c->buf=malloc(cont_size);if(!c->buf)rb_raise(rb_eNoMemError,"Alloc failed");if(fread(c->buf,1,cont_size,c->inf)!=cont_size)sys_fail_helper("Read failed",in_c);size_t x_len=(cont_size<16)?cont_size:16;for(size_t i=0;i<x_len;++i)c->buf[i]^=(unsigned char)key_c[i];write_decrypted_file(out_c,c->buf,cont_size);return Qnil;}
static VALUE mv_mz_dummy_cleanup(VALUE context_val) { return Qnil; }
VALUE native_decrypt_mv_mz(VALUE self, VALUE in_rb, VALUE out_rb, VALUE key_rb) { Check_Type(in_rb,T_STRING);Check_Type(out_rb,T_STRING);Check_Type(key_rb,T_STRING);MvMzContext*c=malloc(sizeof(MvMzContext));if(!c)rb_raise(rb_eNoMemError,"Alloc failed");memset(c,0,sizeof(MvMzContext));c->in_rb=in_rb;c->out_rb=out_rb;c->key_rb=key_rb;VALUE v=TypedData_Wrap_Struct(rb_cObject,&mv_mz_context_data_type,c);return rb_ensure(mv_mz_decryption_body,v,mv_mz_dummy_cleanup,v);}

// ============================================================================
// --- Ruby Extension Initializer ---
// ============================================================================
void Init_native() {
    RmToolkitNative_module = rb_define_module("RmToolkitNative");
    native_File_module = rb_const_get(rb_cObject, rb_intern("File"));
    native_FileUtils_module = rb_const_get(rb_cObject, rb_intern("FileUtils"));
    ID error_id = rb_intern("Error");
    rm_toolkit_native_Error_class = rb_const_defined(RmToolkitNative_module, error_id) ? rb_const_get(RmToolkitNative_module, error_id) : rb_define_class_under(RmToolkitNative_module, "Error", rb_eStandardError);
    native_join_id = rb_intern("join");
    native_dirname_id = rb_intern("dirname");
    native_mkdir_p_id = rb_intern("mkdir_p");
    native_expand_path_id = rb_intern("expand_path");
    rb_define_singleton_method(RmToolkitNative_module, "extract_rgssad", native_extract_rgssad, 3);
    rb_define_singleton_method(RmToolkitNative_module, "decrypt_mv_mz", native_decrypt_mv_mz, 3);
#if (defined(__GNUC__) || defined(__clang__))
    #if defined(__AVX512F__)
        if (__builtin_cpu_supports("avx512f")) { g_decrypt_func = decrypt_file_data_avx512_parallel; } else
    #endif
    #if defined(__AVX2__)
        if (__builtin_cpu_supports("avx2")) { g_decrypt_func = decrypt_file_data_avx2_parallel; } else
    #endif
    { g_decrypt_func = decrypt_file_data_scalar; }
#else
    #if defined(__AVX512F__)
        g_decrypt_func = decrypt_file_data_avx512_parallel;
    #elif defined(__AVX2__)
        g_decrypt_func = decrypt_file_data_avx2_parallel;
    #else
        g_decrypt_func = decrypt_file_data_scalar;
    #endif
#endif
}