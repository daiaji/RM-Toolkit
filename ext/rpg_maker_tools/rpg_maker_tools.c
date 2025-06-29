#include "ruby.h"
#include <errno.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#include <wchar.h>
#include <windows.h>
#else
#include <sys/stat.h>
#include <sys/types.h>
#endif

// --- 平台特定路径处理 (Platform specific path handling) ---
#ifdef _WIN32
wchar_t *wchar_buffer = NULL;
size_t wchar_buffer_size = 0;

int utf8_to_wchar(const char *utf8_str, size_t len) {
  int required_size_int =
      MultiByteToWideChar(CP_UTF8, 0, utf8_str, (int)len, NULL, 0);
  if (required_size_int <= 0 && len > 0) {
    errno = EILSEQ;
    return -1;
  }
  size_t required_size = (size_t)required_size_int + 1;

  if (required_size > wchar_buffer_size) {
    wchar_t *new_buffer =
        (wchar_t *)realloc(wchar_buffer, sizeof(wchar_t) * required_size);
    if (!new_buffer) {
      errno = ENOMEM;
      return -1;
    }
    wchar_buffer = new_buffer;
    wchar_buffer_size = required_size;
  }

  int chars_converted = MultiByteToWideChar(CP_UTF8, 0, utf8_str, (int)len,
                                            wchar_buffer, (int)required_size);
  if (chars_converted <= 0 && len > 0) {
    errno = EILSEQ;
    return -1;
  }
  wchar_buffer[chars_converted] = L'\0';
  return 0;
}
#else // Linux/macOS etc. - Use UTF-8 directly
char *char_buffer = NULL;
size_t char_buffer_size = 0;

int utf8_to_mb(const char *utf8_str, size_t len) {
  size_t required_size = len + 1;
  if (required_size > char_buffer_size) {
    char *new_buffer =
        (char *)realloc(char_buffer, sizeof(char) * required_size);
    if (!new_buffer) {
      errno = ENOMEM;
      return -1;
    }
    char_buffer = new_buffer;
    char_buffer_size = required_size;
  }
  memcpy(char_buffer, utf8_str, len);
  char_buffer[len] = '\0';
  return 0;
}
#endif

// --- Ruby 集成变量 (Ruby Integration Variables) ---
VALUE RpgMakerTools_module = Qnil;
VALUE rpg_maker_tools_Error_class;
VALUE rpg_maker_tools_File_module;
VALUE rpg_maker_tools_FileUtils_module;
ID rpg_maker_tools_join_id;
ID rpg_maker_tools_dirname_id;
ID rpg_maker_tools_mkdir_p_id;

// --- 辅助函数 (Helper Functions) ---

// --- NEW: 添加路径清理函数 ---
// 原地清理路径字符串，移除在大多数文件系统中非法的字符。
// 使用双指针法，原地修改字符串。
static void sanitize_path_in_place(char *path) {
    if (!path) return;

    char *read_ptr = path;
    char *write_ptr = path;

    while (*read_ptr) {
        unsigned char current_char = (unsigned char)*read_ptr;
        bool is_invalid = false;

        // 检查常见非法字符 (不包括 '/' 和 '\'，因为它们是路径分隔符)
        switch (current_char) {
            case '<':
            case '>':
            case ':':
            case '"':
            case '|':
            case '?':
            case '*':
                is_invalid = true;
                break;
            default:
                // 检查 ASCII 控制字符 (0x00-0x1F)
                if (current_char > 0 && current_char < 32) {
                    is_invalid = true;
                }
                break;
        }

        if (!is_invalid) {
            *write_ptr = *read_ptr;
            write_ptr++;
        }
        read_ptr++;
    }
    *write_ptr = '\0'; // 终止新字符串
}
// --- NEW END ---

static void sys_fail_helper(const char *msg, const char *path) {
  char full_msg[1024];
  snprintf(full_msg, sizeof(full_msg), "%s: %s", msg, path);
  rb_sys_fail(full_msg);
}

FILE *platform_fopen(const char *utf8_path, const char *mode) {
#ifdef _WIN32
  wchar_t w_mode[10] = {0};
  // 修正: 确保 i 不会越界
  size_t i = 0;
  for (; mode[i] != '\0' && i < (sizeof(w_mode) / sizeof(wchar_t)) - 1; ++i) {
    w_mode[i] = (wchar_t)mode[i];
  }
  w_mode[i] = L'\0';
  if (utf8_to_wchar(utf8_path, strlen(utf8_path)) == -1) { return NULL; }
  return _wfopen(wchar_buffer, w_mode);
#else
  return fopen(utf8_path, mode);
#endif
}

// --- RGSSAD 解密逻辑 (RGSSAD Decryption Logic) ---
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

unsigned int decrypt_integer_v3(unsigned int encrypted_val, unsigned int key) {
  return encrypted_val ^ key;
}

void decrypt_filename_v3(unsigned char *data, size_t n, unsigned int key) {
  size_t q = n >> 2;
  char r = n & MOD_4_MASK;
  unsigned int *data_p = (unsigned int *)data;
  for (size_t i = 0; i < q; ++i) data_p[i] ^= key;
  unsigned char *remainder_p = (unsigned char *)(data_p + q);
  if (r > 0) {
    unsigned char* key_bytes = (unsigned char*)&key;
    for (char i = 0; i < r; ++i) remainder_p[i] ^= key_bytes[i];
  }
}

void decrypt_file_data(unsigned char *data, size_t n, unsigned int key) {
  size_t q = n >> 2;
  char r = n & MOD_4_MASK;
  unsigned int *data_p = (unsigned int *)data;
  for (size_t i = 0; i < q; ++i) {
    data_p[i] ^= key;
    key = key * 7 + 3;
  }
  if (r > 0) {
    unsigned char *remainder_p = (unsigned char *)(data_p + q);
    unsigned char *key_bytes = (unsigned char *)&key;
    for (char i = 0; i < r; ++i) remainder_p[i] ^= key_bytes[i];
  }
}

// --- RGSSAD 主提取函数 (RGSSAD Main Extraction Function) ---
VALUE rpg_tools_extract_rgssad(VALUE _self, VALUE target_path_rb, VALUE output_dir_rb, VALUE verbose_rb) {
    bool verbose = RTEST(verbose_rb);
    char *target_path_c = StringValueCStr(target_path_rb);

    FILE *input_file = NULL;
    FILE *output_file = NULL;
    unsigned char *entry_data_buffer = NULL;
    unsigned char *encrypted_filename_buffer = NULL;
    char *decrypted_filename_c = NULL;
    
    int error_occurred = 0;
    const char* error_message = "";
    const char* error_path = "";

    enum RGSSAD_TYPE archive_type = UNKNOWN_ARCHIVE;
    unsigned int metadata_key_v3 = 0;
    unsigned int current_key_v1 = RGSSADv1_INITIAL_KEY;

    input_file = platform_fopen(target_path_c, "rb");
    if (!input_file) {
        error_occurred = 1; error_message = "Failed to open input file"; error_path = target_path_c;
        goto cleanup_rgssad;
    }

    unsigned char header[HEADER_SIZE];
    if (fread(header, 1, HEADER_SIZE, input_file) < HEADER_SIZE) {
        rb_raise(rpg_maker_tools_Error_class, "File is too small (header missing): %s", target_path_c);
        goto cleanup_rgssad;
    }

    if (memcmp(header, "RGSSAD\x00\x01", HEADER_SIZE) == 0) {
        archive_type = RGSSADv1;
    } else if (memcmp(header, "RGSSAD\x00\x03", HEADER_SIZE) == 0) {
        archive_type = RGSSADv3;
        unsigned int seed;
        if (fread(&seed, 1, V3_SEED_SIZE, input_file) < V3_SEED_SIZE) {
            rb_raise(rpg_maker_tools_Error_class, "Truncated after v3 header (seed missing): %s", target_path_c);
            goto cleanup_rgssad;
        }
        metadata_key_v3 = seed * 9 + 3;
    } else {
        rb_raise(rpg_maker_tools_Error_class, "Unknown or invalid archive header: %s", target_path_c);
        goto cleanup_rgssad;
    }

    if (verbose) { printf("Processing %s...\n", target_path_c); }

    while (1) {
        unsigned int file_offset = 0, entry_file_size = 0, file_data_key = 0, filename_size = 0;
        long metadata_read_pos = -1;

        free(encrypted_filename_buffer); encrypted_filename_buffer = NULL;
        free(decrypted_filename_c); decrypted_filename_c = NULL;
        free(entry_data_buffer); entry_data_buffer = NULL;

        if (archive_type == RGSSADv1) {
            unsigned int encrypted_val;
            if (fread(&encrypted_val, sizeof(int), 1, input_file) != 1) {
                if(feof(input_file)) break;
                rb_raise(rpg_maker_tools_Error_class, "Read error on v1 filename size: %s", target_path_c);
                goto cleanup_rgssad;
            }
            filename_size = decrypt_integer_v1(encrypted_val, &current_key_v1);
            if (filename_size == 0 || filename_size > 4096) {
                 rb_raise(rpg_maker_tools_Error_class, "Invalid v1 filename size (%u): %s", filename_size, target_path_c);
                 goto cleanup_rgssad;
            }
            
            encrypted_filename_buffer = (unsigned char*)malloc(filename_size);
            if (!encrypted_filename_buffer) { error_occurred = 1; error_message = "malloc for v1 filename failed"; goto cleanup_rgssad; }
            if (fread(encrypted_filename_buffer, 1, filename_size, input_file) != filename_size) { rb_raise(rpg_maker_tools_Error_class, "Read error on v1 filename data: %s", target_path_c); goto cleanup_rgssad; }
            
            decrypt_filename_v1(encrypted_filename_buffer, filename_size, &current_key_v1);

            if (fread(&encrypted_val, sizeof(int), 1, input_file) != 1) { rb_raise(rpg_maker_tools_Error_class, "Read error on v1 file size: %s", target_path_c); goto cleanup_rgssad; }
            entry_file_size = decrypt_integer_v1(encrypted_val, &current_key_v1);
            file_data_key = current_key_v1;
            file_offset = ftell(input_file);
        } else { // RGSSADv3
            unsigned int metadata_block[4];
            metadata_read_pos = ftell(input_file);
            if (fread(metadata_block, sizeof(int), 4, input_file) != 4) {
                if(feof(input_file)) break;
                rb_raise(rpg_maker_tools_Error_class, "Read error on v3 metadata: %s", target_path_c);
                goto cleanup_rgssad;
            }
            file_offset = decrypt_integer_v3(metadata_block[0], metadata_key_v3);
            if (file_offset == 0) break;
            entry_file_size = decrypt_integer_v3(metadata_block[1], metadata_key_v3);
            file_data_key = decrypt_integer_v3(metadata_block[2], metadata_key_v3);
            filename_size = decrypt_integer_v3(metadata_block[3], metadata_key_v3);
            if (filename_size == 0 || filename_size > 4096) {
                 rb_raise(rpg_maker_tools_Error_class, "Invalid v3 filename size (%u): %s", filename_size, target_path_c);
                 goto cleanup_rgssad;
            }
            
            encrypted_filename_buffer = (unsigned char*)malloc(filename_size);
            if (!encrypted_filename_buffer) { error_occurred = 1; error_message = "malloc for v3 filename failed"; goto cleanup_rgssad; }
            if (fread(encrypted_filename_buffer, 1, filename_size, input_file) != filename_size) { rb_raise(rpg_maker_tools_Error_class, "Read error on v3 filename data: %s", target_path_c); goto cleanup_rgssad; }

            decrypt_filename_v3(encrypted_filename_buffer, filename_size, metadata_key_v3);
        }

        decrypted_filename_c = (char *)malloc(filename_size + 1);
        if(!decrypted_filename_c) { error_occurred = 1; error_message = "malloc for decrypted filename failed"; goto cleanup_rgssad; }
        memcpy(decrypted_filename_c, encrypted_filename_buffer, filename_size);
        decrypted_filename_c[filename_size] = '\0';
        free(encrypted_filename_buffer); encrypted_filename_buffer = NULL;
        
        for (unsigned int i = 0; i < filename_size; ++i) if (decrypted_filename_c[i] == '\\') decrypted_filename_c[i] = '/';

        // --- MODIFICATION: 调用路径清理函数 ---
        sanitize_path_in_place(decrypted_filename_c);
        // --- MODIFICATION END ---
        
        // --- MODIFICATION: 使用 strlen 获取可能变短的路径长度 ---
        VALUE rb_filename_str = rb_utf8_str_new(decrypted_filename_c, strlen(decrypted_filename_c));
        // --- MODIFICATION END ---
        
        VALUE output_full_path_rb = rb_funcall(rpg_maker_tools_File_module, rpg_maker_tools_join_id, 2, output_dir_rb, rb_filename_str);
        VALUE output_dir_part_rb = rb_funcall(rpg_maker_tools_File_module, rpg_maker_tools_dirname_id, 1, output_full_path_rb);
        rb_funcall(rpg_maker_tools_FileUtils_module, rpg_maker_tools_mkdir_p_id, 1, output_dir_part_rb);
        char *output_full_path_c = StringValueCStr(output_full_path_rb);

        if (entry_file_size > 0) {
            entry_data_buffer = (unsigned char *)malloc(entry_file_size);
            if (!entry_data_buffer) { error_occurred = 1; error_message = "malloc for entry data failed"; goto cleanup_rgssad; }
            if (fseek(input_file, (long)file_offset, SEEK_SET) != 0) { error_occurred = 1; error_message = "fseek to data offset"; error_path = target_path_c; goto cleanup_rgssad; }
            if (fread(entry_data_buffer, 1, entry_file_size, input_file) != entry_file_size) { rb_raise(rpg_maker_tools_Error_class, "Read error on file data for %s", decrypted_filename_c); goto cleanup_rgssad; }
            decrypt_file_data(entry_data_buffer, entry_file_size, file_data_key);
        }

        output_file = platform_fopen(output_full_path_c, "wb");
        if (!output_file) { error_occurred = 1; error_message = "Failed to open output file"; error_path = output_full_path_c; goto cleanup_rgssad; }
        if (entry_file_size > 0) { if (fwrite(entry_data_buffer, 1, entry_file_size, output_file) != entry_file_size) { error_occurred = 1; error_message = "Failed to write to output file"; error_path = output_full_path_c; goto cleanup_rgssad; } }
        fclose(output_file); output_file = NULL;

        if (verbose) { printf("  Extracted: %s\n", decrypted_filename_c); }
        
        free(decrypted_filename_c); decrypted_filename_c = NULL;
        free(entry_data_buffer); entry_data_buffer = NULL;

        if (archive_type != RGSSADv1) {
            long next_metadata_pos = metadata_read_pos + (sizeof(unsigned int) * 4) + filename_size;
            if (fseek(input_file, next_metadata_pos, SEEK_SET) != 0) { error_occurred = 1; error_message = "fseek to next metadata"; error_path = target_path_c; goto cleanup_rgssad; }
        } else {
            fseek(input_file, file_offset + entry_file_size, SEEK_SET);
        }
    }

cleanup_rgssad:
    if (input_file) fclose(input_file);
    if (output_file) fclose(output_file);
    free(entry_data_buffer);
    free(encrypted_filename_buffer);
    free(decrypted_filename_c);
    #ifdef _WIN32
    if(wchar_buffer) { free(wchar_buffer); wchar_buffer = NULL; wchar_buffer_size = 0; }
    #else
    if(char_buffer) { free(char_buffer); char_buffer = NULL; char_buffer_size = 0; }
    #endif
    if (error_occurred) {
        if (error_path) { sys_fail_helper(error_message, error_path); } 
        else { rb_sys_fail(error_message); }
    }
    return Qnil;
}

// --- RPG Maker MV/MZ 文件解密函数 ---
#define MV_MZ_HEADER_SIZE 16

VALUE rpg_tools_decrypt_mv_mz(VALUE _self, VALUE input_path_rb, VALUE output_path_rb, VALUE key_rb) {
    Check_Type(input_path_rb, T_STRING);
    Check_Type(output_path_rb, T_STRING);
    Check_Type(key_rb, T_STRING);

    char *input_path_c = StringValueCStr(input_path_rb);
    char *output_path_c = StringValueCStr(output_path_rb);
    const char *key_c = RSTRING_PTR(key_rb);
    long key_len = RSTRING_LEN(key_rb);

    if (key_len != 16) {
        rb_raise(rb_eArgError, "Encryption key must be 16 bytes, but got %ld", key_len);
    }

    FILE *input_file = NULL;
    FILE *output_file = NULL;
    unsigned char *buffer = NULL;
    long file_size = 0;
    long content_size = 0;
    int error_occurred = 0;
    const char *error_message = "";
    const char *error_path = "";

    input_file = platform_fopen(input_path_c, "rb");
    if (!input_file) {
        error_occurred = 1; error_message = "Failed to open input file"; error_path = input_path_c;
        goto cleanup_mv_mz;
    }

    fseek(input_file, 0, SEEK_END);
    file_size = ftell(input_file);
    fseek(input_file, 0, SEEK_SET);

    if (file_size < MV_MZ_HEADER_SIZE) {
        rb_raise(rb_eIOError, "File is too small to be a valid MV/MZ encrypted file: %s", input_path_c);
        goto cleanup_mv_mz;
    }

    if (fseek(input_file, MV_MZ_HEADER_SIZE, SEEK_SET) != 0) {
        error_occurred = 1; error_message = "Failed to seek past header in file"; error_path = input_path_c;
        goto cleanup_mv_mz;
    }
    
    content_size = file_size - MV_MZ_HEADER_SIZE;
    if (content_size <= 0) {
        output_file = platform_fopen(output_path_c, "wb");
        if (!output_file) { error_occurred = 1; error_message = "Failed to create empty output file"; error_path = output_path_c; }
        goto cleanup_mv_mz;
    }
    
    buffer = (unsigned char *)malloc(content_size);
    if (!buffer) { rb_raise(rb_eNoMemError, "Failed to allocate memory for file content"); goto cleanup_mv_mz; }
    
    if (fread(buffer, 1, content_size, input_file) != content_size) {
        error_occurred = 1; error_message = "Failed to read file content"; error_path = input_path_c;
        goto cleanup_mv_mz;
    }
    
    size_t xor_len = (content_size < 16) ? content_size : 16;
    for (size_t i = 0; i < xor_len; ++i) {
        buffer[i] ^= (unsigned char)key_c[i];
    }
    
    output_file = platform_fopen(output_path_c, "wb");
    if (!output_file) {
        error_occurred = 1; error_message = "Failed to open output file"; error_path = output_path_c;
        goto cleanup_mv_mz;
    }

    if (fwrite(buffer, 1, content_size, output_file) != content_size) {
        error_occurred = 1; error_message = "Failed to write to output file"; error_path = output_path_c;
        goto cleanup_mv_mz;
    }

cleanup_mv_mz:
    if (input_file) fclose(input_file);
    if (output_file) fclose(output_file);
    if (buffer) free(buffer);
    if (error_occurred) {
        if (error_path) { sys_fail_helper(error_message, error_path); } 
        else { rb_sys_fail(error_message); }
    }
    return Qnil;
}

// --- Ruby 扩展初始化函数 ---
void Init_rpg_maker_tools() {
    RpgMakerTools_module = rb_define_module("RpgMakerTools");
    
    rpg_maker_tools_File_module = rb_const_get(rb_cObject, rb_intern("File"));
    rpg_maker_tools_FileUtils_module = rb_const_get(rb_cObject, rb_intern("FileUtils"));
    
    ID rpg_maker_tools_Error_id = rb_intern("Error");
    if (!rb_const_defined(RpgMakerTools_module, rpg_maker_tools_Error_id)) {
        rpg_maker_tools_Error_class = rb_define_class_under(RpgMakerTools_module, "Error", rb_eStandardError);
    } else {
        rpg_maker_tools_Error_class = rb_const_get(RpgMakerTools_module, rpg_maker_tools_Error_id);
    }

    rpg_maker_tools_join_id = rb_intern("join");
    rpg_maker_tools_dirname_id = rb_intern("dirname");
    rpg_maker_tools_mkdir_p_id = rb_intern("mkdir_p");
    
    rb_define_singleton_method(RpgMakerTools_module, "extract_rgssad", rpg_tools_extract_rgssad, 3);
    rb_define_singleton_method(RpgMakerTools_module, "decrypt_mv_mz", rpg_tools_decrypt_mv_mz, 3);
}