#include <moonbit.h>
#include <zlib.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <dlfcn.h>

MOONBIT_FFI_EXPORT uint32_t moonrobo_learning_crc32(moonbit_bytes_t input) {
  uint32_t crc = 0xffffffffU;
  for (int32_t i=0; i<Moonbit_array_length(input); i++) {
    crc ^= input[i];
    for (int j=0; j<8; j++) crc = (crc >> 1) ^ ((crc & 1) ? 0xedb88320U : 0);
  }
  return crc ^ 0xffffffffU;
}

MOONBIT_FFI_EXPORT moonbit_bytes_t moonrobo_learning_inflate(
    moonbit_bytes_t input, int32_t window_bits, int32_t *status) {
  z_stream stream = {0};
  *status = -1;
  void *lib = dlopen("libz.1.dylib", RTLD_NOW | RTLD_LOCAL);
  if (!lib) lib = dlopen("libz.so.1", RTLD_NOW | RTLD_LOCAL);
  if (!lib) return moonbit_make_bytes(0, 0);
  int (*init)(z_streamp,int,const char *,int) = (void *)dlsym(lib,"inflateInit2_");
  int (*run)(z_streamp,int) = (void *)dlsym(lib,"inflate");
  int (*end)(z_streamp) = (void *)dlsym(lib,"inflateEnd");
  if (!init || !run || !end || init(&stream,window_bits,ZLIB_VERSION,sizeof(z_stream)) != Z_OK) {
    dlclose(lib); return moonbit_make_bytes(0, 0);
  }
  size_t capacity = 65536, length = 0;
  unsigned char *buffer = malloc(capacity);
  if (!buffer) { end(&stream); dlclose(lib); return moonbit_make_bytes(0, 0); }
  stream.next_in = input;
  stream.avail_in = Moonbit_array_length(input);
  int rc;
  do {
    if (length == capacity) {
      if (capacity >= 1073741824) { rc = Z_MEM_ERROR; break; }
      capacity *= 2;
      void *next = realloc(buffer, capacity);
      if (!next) { rc = Z_MEM_ERROR; break; }
      buffer = next;
    }
    stream.next_out = buffer + length;
    stream.avail_out = (uInt)(capacity - length);
    rc = run(&stream, Z_NO_FLUSH);
    length = stream.total_out;
  } while (rc == Z_OK);
  /* Refuse trailing bytes and concatenated gzip members explicitly. */
  if (rc == Z_STREAM_END && stream.avail_in == 0) {
    moonbit_bytes_t output = moonbit_make_bytes((int32_t)length, 0);
    memcpy(output, buffer, length);
    free(buffer); end(&stream); dlclose(lib); *status = 0; return output;
  }
  free(buffer); end(&stream); dlclose(lib); return moonbit_make_bytes(0, 0);
}

MOONBIT_FFI_EXPORT moonbit_bytes_t moonrobo_learning_gzip(
    moonbit_bytes_t input, int32_t *status) {
  *status = -1;
  int32_t size = Moonbit_array_length(input);
  if (size > 1000000000) return moonbit_make_bytes(0, 0);
  void *lib = dlopen("libz.1.dylib", RTLD_NOW | RTLD_LOCAL);
  if (!lib) lib = dlopen("libz.so.1", RTLD_NOW | RTLD_LOCAL);
  if (!lib) return moonbit_make_bytes(0, 0);
  int (*init)(z_streamp,int,int,int,int,int,const char *,int) = (void *)dlsym(lib,"deflateInit2_");
  int (*run)(z_streamp,int) = (void *)dlsym(lib,"deflate");
  int (*end)(z_streamp) = (void *)dlsym(lib,"deflateEnd");
  z_stream stream = {0};
  if (!init || !run || !end || init(&stream,6,Z_DEFLATED,31,8,Z_DEFAULT_STRATEGY,ZLIB_VERSION,sizeof(z_stream)) != Z_OK) {
    dlclose(lib); return moonbit_make_bytes(0, 0);
  }
  size_t capacity = (size_t)size + (size_t)size / 10 + 65536;
  unsigned char *buffer = malloc(capacity);
  if (!buffer) { end(&stream); dlclose(lib); return moonbit_make_bytes(0, 0); }
  stream.next_in = input; stream.avail_in = size;
  stream.next_out = buffer; stream.avail_out = capacity;
  int rc = run(&stream, Z_FINISH);
  if (rc == Z_STREAM_END && stream.avail_in == 0) {
    moonbit_bytes_t output = moonbit_make_bytes((int32_t)stream.total_out, 0);
    memcpy(output,buffer,stream.total_out);
    free(buffer); end(&stream); dlclose(lib); *status=0; return output;
  }
  free(buffer); end(&stream); dlclose(lib); return moonbit_make_bytes(0, 0);
}
