#define _POSIX_C_SOURCE 200809L
#include <moonbit.h>
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

/* One open shard and one fixed 64 KiB window per reader. Unlike a whole-file
   mmap this places a hard bound on process-resident reference cache memory. */
typedef struct {
  int fd;
  char *path;
  int64_t start;
  size_t size;
  unsigned char bytes[65536];
  char error[1024];
} MotionReader;
typedef struct { FILE *file; char error[1024]; } MotionWriter;
typedef struct { int fd; int64_t size; char error[1024]; } MotionAdviceFile;

static moonbit_bytes_t bytes_of(const char *s) {
  size_t n = strlen(s);
  moonbit_bytes_t out = moonbit_make_bytes((int32_t)n, 0);
  memcpy(out, s, n);
  return out;
}
static char *copy_path(moonbit_bytes_t path) {
  int32_t n = Moonbit_array_length(path);
  if (memchr(path, 0, (size_t)n)) return NULL;
  char *out = malloc((size_t)n + 1);
  if (!out) return NULL;
  memcpy(out, path, (size_t)n);
  out[n] = 0;
  return out;
}
static void reader_destroy(void *pointer) {
  MotionReader *r = pointer;
  if (r->fd >= 0) close(r->fd);
  free(r->path);
}
static void writer_destroy(void *pointer) {
  MotionWriter *w = pointer;
  if (w->file) fclose(w->file);
}
static void advice_file_destroy(void *pointer) {
  MotionAdviceFile *f = pointer;
  if (f->fd >= 0) close(f->fd);
}
MOONBIT_FFI_EXPORT MotionAdviceFile *mr_motion_advice_file_open(moonbit_bytes_t path) {
  MotionAdviceFile *f = moonbit_make_external_object(advice_file_destroy, sizeof(*f));
  memset(f, 0, sizeof(*f));
  f->fd = -1;
  char *name = copy_path(path);
  if (!name) { strcpy(f->error, "invalid motion path or allocation failure"); return f; }
  int flags = O_RDONLY | O_NONBLOCK;
#ifdef O_CLOEXEC
  flags |= O_CLOEXEC;
#endif
#ifdef O_NOFOLLOW
  flags |= O_NOFOLLOW;
#endif
  f->fd = open(name, flags);
  free(name);
  if (f->fd < 0) {
    snprintf(f->error, sizeof(f->error), "open motion advice file: %s", strerror(errno));
    return f;
  }
  struct stat st;
  if (fstat(f->fd, &st) != 0 || !S_ISREG(st.st_mode) || st.st_size < 0) {
    snprintf(f->error, sizeof(f->error), "motion advice requires a regular file: %s", strerror(errno));
    close(f->fd); f->fd = -1; return f;
  }
  f->size = (int64_t)st.st_size;
  return f;
}
MOONBIT_FFI_EXPORT moonbit_bytes_t mr_motion_advice_file_error(MotionAdviceFile *f) {
  return bytes_of(f->error);
}
MOONBIT_FFI_EXPORT int64_t mr_motion_advice_file_size(MotionAdviceFile *f) { return f->size; }
MOONBIT_FFI_EXPORT moonbit_bytes_t mr_motion_advice_file_read_at(MotionAdviceFile *f,
                                                                 int64_t offset, int32_t count) {
  if (f->fd < 0 || offset < 0 || count < 1 || count > 65536 ||
      offset > f->size - (int64_t)count) {
    strcpy(f->error, "invalid motion advice read range");
    return moonbit_make_bytes(0, 0);
  }
  moonbit_bytes_t out = moonbit_make_bytes(count, 0);
  size_t got = 0;
  while (got < (size_t)count) {
    ssize_t n = pread(f->fd, out + got, (size_t)count - got, (off_t)(offset + (int64_t)got));
    if (n < 0 && errno == EINTR) continue;
    if (n <= 0) {
      snprintf(f->error, sizeof(f->error), "read motion advice file: %s",
               n == 0 ? "unexpected EOF" : strerror(errno));
      moonbit_decref(out);
      return moonbit_make_bytes(0, 0);
    }
    got += (size_t)n;
  }
  return out;
}
MOONBIT_FFI_EXPORT int32_t mr_motion_advice_file_dontneed(MotionAdviceFile *f) {
  if (f->fd < 0) { strcpy(f->error, "motion advice file is closed"); return 3; }
  struct stat st;
  if (fstat(f->fd, &st) != 0) {
    snprintf(f->error, sizeof(f->error), "stat motion advice file: %s", strerror(errno));
    return 3;
  }
  if (!S_ISREG(st.st_mode) || st.st_size != (off_t)f->size) {
    strcpy(f->error, "motion advice file changed size or type after verification");
    return 3;
  }
#ifdef __linux__
  int error = posix_fadvise(f->fd, 0, (off_t)f->size, POSIX_FADV_DONTNEED);
  if (error != 0) {
    snprintf(f->error, sizeof(f->error), "posix_fadvise DONTNEED: %s", strerror(error));
    return 2;
  }
  return 0;
#else
  strcpy(f->error, "posix_fadvise DONTNEED is supported only on Linux");
  return 1;
#endif
}
MOONBIT_FFI_EXPORT void mr_motion_advice_file_close(MotionAdviceFile *f) {
  if (f->fd >= 0) { close(f->fd); f->fd = -1; }
}
MOONBIT_FFI_EXPORT MotionReader *mr_motion_reader_new(void) {
  MotionReader *r = moonbit_make_external_object(reader_destroy, sizeof(*r));
  memset(r, 0, sizeof(*r));
  r->fd = -1;
  return r;
}
MOONBIT_FFI_EXPORT moonbit_bytes_t mr_motion_reader_error(MotionReader *r) { return bytes_of(r->error); }
MOONBIT_FFI_EXPORT int32_t mr_motion_reader_read(MotionReader *r, moonbit_bytes_t path,
                                                int32_t row, double *out) {
  int32_t width = Moonbit_array_length(out);
  r->error[0] = 0;
  if (row < 0 || width < 1 || width > 76) {
    strcpy(r->error, "invalid motion row index or width"); return -1;
  }
  size_t path_length = (size_t)Moonbit_array_length(path);
  if (!r->path || strlen(r->path) != path_length || memcmp(r->path, path, path_length)) {
    char *name = copy_path(path);
    if (!name) { strcpy(r->error, "invalid motion path or allocation failure"); return -1; }
    int fd = open(name, O_RDONLY);
    if (fd < 0) {
      snprintf(r->error, sizeof(r->error), "open motion cache: %s", strerror(errno));
      free(name); return -1;
    }
    if (r->fd >= 0) close(r->fd);
    free(r->path);
    r->path = name; r->fd = fd; r->size = 0;
  }
  int64_t offset = (int64_t)row * width * 8;
  size_t length = (size_t)width * 8;
  if (offset < r->start || offset + (int64_t)length > r->start + (int64_t)r->size) {
    r->start = offset;
    ssize_t n;
    do { n = pread(r->fd, r->bytes, sizeof(r->bytes), (off_t)offset); } while (n < 0 && errno == EINTR);
    if (n < 0) { snprintf(r->error, sizeof(r->error), "read motion cache: %s", strerror(errno)); return -1; }
    r->size = (size_t)n;
  }
  if (offset + (int64_t)length > r->start + (int64_t)r->size) {
    strcpy(r->error, "truncated motion cache row"); return -1;
  }
  /* Cache format is little-endian IEEE754 Float64, independent of host. */
  for (int32_t i = 0; i < width; ++i) {
    const unsigned char *p = r->bytes + (size_t)(offset - r->start) + i * 8;
    uint64_t value = 0;
    for (int k = 0; k < 8; ++k) value |= (uint64_t)p[k] << (8 * k);
    memcpy(out + i, &value, 8);
  }
  return 0;
}
MOONBIT_FFI_EXPORT MotionWriter *mr_motion_writer_open(moonbit_bytes_t path) {
  MotionWriter *w = moonbit_make_external_object(writer_destroy, sizeof(*w));
  memset(w, 0, sizeof(*w));
  char *name = copy_path(path);
  if (!name) { strcpy(w->error, "invalid motion path or allocation failure"); return w; }
  int fd = open(name, O_WRONLY | O_CREAT | O_TRUNC, 0600);
  free(name);
  if (fd < 0) { snprintf(w->error, sizeof(w->error), "create motion cache: %s", strerror(errno)); return w; }
  w->file = fdopen(fd, "wb");
  if (!w->file) { snprintf(w->error, sizeof(w->error), "open motion stream: %s", strerror(errno)); close(fd); }
  return w;
}
MOONBIT_FFI_EXPORT moonbit_bytes_t mr_motion_writer_error(MotionWriter *w) { return bytes_of(w->error); }
MOONBIT_FFI_EXPORT int32_t mr_motion_writer_write(MotionWriter *w, const double *row) {
  if (!w->file) { strcpy(w->error, "motion writer is closed"); return -1; }
  int32_t n = Moonbit_array_length(row);
  if (n < 1 || n > 76) { strcpy(w->error, "invalid motion row width"); return -1; }
  unsigned char bytes[76 * 8];
  for (int32_t i = 0; i < n; ++i) {
    uint64_t value;
    memcpy(&value, row + i, 8);
    for (int k = 0; k < 8; ++k) bytes[i * 8 + k] = (unsigned char)(value >> (8 * k));
  }
  if (fwrite(bytes, 8, (size_t)n, w->file) != (size_t)n) {
    snprintf(w->error, sizeof(w->error), "write motion cache: %s", strerror(errno)); return -1;
  }
  return 0;
}
MOONBIT_FFI_EXPORT int32_t mr_motion_writer_finish(MotionWriter *w) {
  if (!w->file) { strcpy(w->error, "motion writer is closed"); return -1; }
  int result = fflush(w->file);
  if (result == 0) result = fsync(fileno(w->file));
  int saved = errno;
  if (fclose(w->file) && result == 0) { result = -1; saved = errno; }
  w->file = NULL;
  if (result != 0) snprintf(w->error, sizeof(w->error), "flush motion cache: %s", strerror(saved));
  return result == 0 ? 0 : -1;
}
