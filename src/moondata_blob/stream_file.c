#define _FILE_OFFSET_BITS 64

#include "moonbit.h"

#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#if defined(_WIN32)
#include <io.h>
#include <windows.h>
#define moondata_access _access
#define moondata_fileno _fileno
#define moondata_fsync _commit
#define moondata_fseek _fseeki64
#define moondata_ftell _ftelli64
#else
#include <unistd.h>
#define moondata_access access
#define moondata_fileno fileno
#define moondata_fsync fsync
#define moondata_fseek fseeko
#define moondata_ftell ftello
#endif

static FILE *moondata_blob_open_staged_file(
    char *temp_path,
    size_t temp_capacity,
    const char *destination_path) {
  snprintf(
      temp_path,
      temp_capacity,
      "%s.next.XXXXXX",
      destination_path);
#if defined(_WIN32)
  if (_mktemp_s(temp_path, temp_capacity) != 0) {
    return NULL;
  }
  return fopen(temp_path, "wb");
#else
  int descriptor = mkstemp(temp_path);
  if (descriptor < 0) {
    return NULL;
  }
  FILE *file = fdopen(descriptor, "wb");
  if (file == NULL) {
    close(descriptor);
    remove(temp_path);
  }
  return file;
#endif
}

static int moondata_blob_publish_staged_file(
    const char *temp_path,
    const char *destination_path) {
#if defined(_WIN32)
  if (MoveFileA(temp_path, destination_path) != 0) {
    return 0;
  }
  if (GetLastError() == ERROR_FILE_EXISTS ||
      GetLastError() == ERROR_ALREADY_EXISTS) {
    remove(temp_path);
    return 1;
  }
  return -1;
#else
  if (link(temp_path, destination_path) == 0) {
    remove(temp_path);
    return 0;
  }
  if (errno == EEXIST) {
    remove(temp_path);
    return 1;
  }
  return -1;
#endif
}

MOONBIT_FFI_EXPORT int64_t moondata_blob_file_size(const char *path) {
  if (path == NULL || path[0] == '\0') {
    return -1;
  }
  FILE *file = fopen(path, "rb");
  if (file == NULL) {
    return -1;
  }
  if (moondata_fseek(file, 0, SEEK_END) != 0) {
    fclose(file);
    return -1;
  }
  int64_t size = (int64_t)moondata_ftell(file);
  fclose(file);
  return size;
}

MOONBIT_FFI_EXPORT moonbit_bytes_t moondata_blob_read_file_range(
    const char *path,
    int64_t offset,
    int32_t length) {
  if (path == NULL || offset < 0 || length < 0) {
    return moonbit_make_bytes(0, 0);
  }
  FILE *file = fopen(path, "rb");
  if (file == NULL) {
    return moonbit_make_bytes(0, 0);
  }
  if (moondata_fseek(file, offset, SEEK_SET) != 0) {
    fclose(file);
    return moonbit_make_bytes(0, 0);
  }
  moonbit_bytes_t out = moonbit_make_bytes(length, 0);
  size_t read_count = fread(out, 1, (size_t)length, file);
  fclose(file);
  if (read_count != (size_t)length) {
    return moonbit_make_bytes(0, 0);
  }
  return out;
}

static int moondata_blob_copy_stream(FILE *source, FILE *destination) {
  const size_t capacity = 1024 * 1024;
  unsigned char *buffer = (unsigned char *)malloc(capacity);
  if (buffer == NULL) {
    return -1;
  }
  int result = 0;
  while (!feof(source)) {
    size_t count = fread(buffer, 1, capacity, source);
    if (count > 0 && fwrite(buffer, 1, count, destination) != count) {
      result = -1;
      break;
    }
    if (ferror(source)) {
      result = -1;
      break;
    }
  }
  free(buffer);
  return result;
}

MOONBIT_FFI_EXPORT int32_t moondata_blob_copy_file_staged(
    const char *source_path,
    const char *destination_path) {
  if (source_path == NULL || destination_path == NULL ||
      source_path[0] == '\0' || destination_path[0] == '\0') {
    return -1;
  }
  if (moondata_access(destination_path, 0) == 0) {
    return 1;
  }
  size_t temp_capacity = strlen(destination_path) + 64;
  char *temp_path = (char *)malloc(temp_capacity);
  if (temp_path == NULL) {
    return -1;
  }
  FILE *source = fopen(source_path, "rb");
  FILE *destination = moondata_blob_open_staged_file(
      temp_path,
      temp_capacity,
      destination_path);
  if (source == NULL || destination == NULL) {
    if (source != NULL) fclose(source);
    if (destination != NULL) fclose(destination);
    remove(temp_path);
    free(temp_path);
    return -1;
  }
  int result = moondata_blob_copy_stream(source, destination);
  if (result == 0 && fflush(destination) != 0) {
    result = -1;
  }
  if (result == 0 && moondata_fsync(moondata_fileno(destination)) != 0) {
    result = -1;
  }
  if (fclose(source) != 0) {
    result = -1;
  }
  if (fclose(destination) != 0) {
    result = -1;
  }
  if (result == 0) {
    result = moondata_blob_publish_staged_file(temp_path, destination_path);
  }
  if (result < 0) {
    remove(temp_path);
  }
  free(temp_path);
  return result;
}
