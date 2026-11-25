#include "moonbit.h"
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#ifdef __linux__
#include <errno.h>
#include <fcntl.h>
#include <linux/hidraw.h>
#include <linux/input.h>
#include <poll.h>
#include <strings.h>
#include <sys/file.h>
#include <sys/ioctl.h>
#endif

// OS I/O only. Calibration, neutral/deadman admission, speeds, goals and
// fault policy live in MoonBit. Only a whitelisted input-report/LED setup
// can be sent to this Joy-Con. This file never opens the servo port.
typedef struct { int input_fd; int hid_fd; int64_t last_setup_ms; } NeckJoy;
static char joy_last_error[256];
MOONBIT_FFI_EXPORT moonbit_bytes_t moonrobo_joy_error(void) {
  int n=(int)strlen(joy_last_error);moonbit_bytes_t b=moonbit_make_bytes(n,0);memcpy(b,joy_last_error,(size_t)n);return b;
}
static void joy_destroy(void *p) {
  NeckJoy *j = p;
  if (j->input_fd >= 0) close(j->input_fd);
  if (j->hid_fd >= 0) close(j->hid_fd);
  j->input_fd = j->hid_fd = -1;
  j->last_setup_ms = 0;
}
MOONBIT_FFI_EXPORT void moonrobo_joy_close(NeckJoy *j) { joy_destroy(j); }
MOONBIT_FFI_EXPORT int32_t moonrobo_joy_valid(NeckJoy *j) { return j->input_fd >= 0 && j->hid_fd >= 0; }
MOONBIT_FFI_EXPORT int32_t moonrobo_joy_event_fd(NeckJoy *j) { return j->input_fd; }

#ifdef __linux__
static int64_t joy_clock(void) {
  struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t);
  return (int64_t)t.tv_sec * 1000 + t.tv_nsec / 1000000;
}
static int joy_keys(int fd, int *zl, int *minus) {
  unsigned char keys[(KEY_MAX + 8) / 8] = {0};
  if (ioctl(fd, EVIOCGKEY(sizeof(keys)), keys) < 0) return -1;
  *zl = !!(keys[BTN_TL2 / 8] & (1u << (BTN_TL2 % 8)));
  *minus = !!(keys[BTN_SELECT / 8] & (1u << (BTN_SELECT % 8)));
  return 0;
}

// A newly opened or paused reader must discard backlog first. Then require
// an actual fresh periodic full HID report; unchanged stick values alone
// are not a Bluetooth heartbeat. Never wait longer than 125 ms; MoonBit also
// enforces the stricter combined 150 ms sample-to-dispatch deadline.
static int joy_fresh_report(int fd, int64_t *captured, unsigned char *buttons) {
  unsigned char report[128];
  int drained = 0;
  for (;;) {
    ssize_t n = read(fd, report, sizeof(report));
    if (n > 0) { if (++drained > 256) return -1; continue; }
    if (n < 0 && errno == EINTR) continue;
    if (n < 0 && errno == EAGAIN) break;
    return -1;
  }
  *captured = joy_clock();
  int64_t deadline = *captured + 125;
  for (;;) {
    int wait = (int)(deadline - joy_clock());
    if (wait <= 0) return -1;
    struct pollfd p = {fd, POLLIN, 0};
    int n = poll(&p, 1, wait);
    if (n < 0 && errno == EINTR) continue;
    if (n <= 0 || (p.revents & (POLLHUP | POLLERR | POLLNVAL))) {snprintf(joy_last_error,sizeof(joy_last_error),"HID heartbeat poll: result=%d events=%d errno=%d",n,p.revents,errno);return -1;}
    ssize_t got = read(fd, report, sizeof(report));
    if (got < 0 && (errno == EAGAIN || errno == EINTR)) continue;
    if (got >= 49 && report[0] == 0x30) {
      if (buttons) *buttons = report[5] & 15;
      return 0;
    }
    if (got > 0) snprintf(joy_last_error,sizeof(joy_last_error),"Unexpected HID report: id=%02x bytes=%ld",report[0],(long)got);
    if (got <= 0) return -1;
  }
}
#endif

MOONBIT_FFI_EXPORT NeckJoy *moonrobo_joy_open(void) {
  NeckJoy *j = (NeckJoy *)moonbit_make_external_object(joy_destroy, sizeof(NeckJoy));
  j->input_fd = j->hid_fd = -1;
  j->last_setup_ms = 0;
#ifdef __linux__
  const char *expected = "98:b6:e9:20:21:41";
  for (int i = 0; i < 128; ++i) {
    char path[64], uniq[128] = {0}; struct input_id id = {0};
    snprintf(path, sizeof(path), "/dev/input/event%d", i);
    int fd = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC);
    if (fd < 0) continue;
    if (ioctl(fd, EVIOCGID, &id) == 0 && id.bustype == BUS_BLUETOOTH &&
        id.vendor == 0x057e && id.product == 0x2006 &&
        ioctl(fd, EVIOCGUNIQ(sizeof(uniq)-1), uniq) >= 0 && strcasecmp(uniq, expected) == 0) {
      unsigned long props = 0;
      struct input_absinfo x, y;
      // The same MAC has a separate IMU node: do not read it as a stick.
      if (ioctl(fd, EVIOCGPROP(sizeof(props)), &props) >= 0 &&
          !(props & (1UL << INPUT_PROP_ACCELEROMETER)) &&
          ioctl(fd, EVIOCGABS(ABS_X), &x) == 0 && ioctl(fd, EVIOCGABS(ABS_Y), &y) == 0 &&
          flock(fd, LOCK_EX | LOCK_NB) == 0) {
        j->input_fd = fd; break;
      }
    }
    close(fd);
  }
  if (j->input_fd >= 0) {
    for (int i = 0; i < 64; ++i) {
      char path[64], uniq[128] = {0}; struct hidraw_devinfo id = {0};
      snprintf(path, sizeof(path), "/dev/hidraw%d", i);
      int fd = open(path, O_RDWR | O_NONBLOCK | O_CLOEXEC);
      if (fd < 0) continue;
      if (ioctl(fd, HIDIOCGRAWINFO, &id) == 0 && id.bustype == BUS_BLUETOOTH &&
          id.vendor == 0x057e && id.product == 0x2006 &&
          ioctl(fd, HIDIOCGRAWUNIQ(sizeof(uniq)-1), uniq) >= 0 && strcasecmp(uniq, expected) == 0 &&
          flock(fd, LOCK_EX | LOCK_NB) == 0) {
        j->hid_fd = fd; break;
      }
      close(fd);
    }
  }
#endif
  if (!moonrobo_joy_valid(j)) joy_destroy(j);
  return j;
}

MOONBIT_FFI_EXPORT int32_t moonrobo_joy_write_setup(NeckJoy *j, moonbit_bytes_t packet) {
#ifdef __linux__
  // No raw HID command API: permit only sensor enable, full input report
  // mode and one steady player LED. Never permit rumble or SPI writes.
  static const unsigned char neutral_rumble[8]={0,1,0x40,0x40,0,1,0x40,0x40};
  if (!moonrobo_joy_valid(j) || Moonbit_array_length(packet)!=12 ||
      packet[0]!=1 || packet[1]>15 || memcmp(packet+2,neutral_rumble,8)!=0 ||
      !((packet[10]==0x40 && packet[11]==1) ||
        (packet[10]==3 && packet[11]==0x30) ||
        (packet[10]==0x30 && packet[11]==1))) return -1;
  struct pollfd p={j->hid_fd,POLLOUT,0};
  if(poll(&p,1,100)<=0 || (p.revents&(POLLERR|POLLHUP|POLLNVAL))) return -1;
  int64_t now=joy_clock();
  if(j->last_setup_ms && now-j->last_setup_ms<50) return -1;
  j->last_setup_ms=now;
  return write(j->hid_fd,packet,12)==12 ? 0 : -1;
#else
  (void)j;(void)packet;return -1;
#endif
}

MOONBIT_FFI_EXPORT moonbit_bytes_t moonrobo_joy_setup_reply(NeckJoy *j, moonbit_bytes_t packet) {
#ifdef __linux__
  if (moonrobo_joy_write_setup(j,packet)<0) return moonbit_make_bytes(0,0);
  int64_t deadline=joy_clock()+250;
  while (joy_clock()<deadline) {
    struct pollfd p={j->hid_fd,POLLIN,0};
    int wait=(int)(deadline-joy_clock());
    if(wait<=0 || poll(&p,1,wait)<=0 || (p.revents&(POLLERR|POLLHUP|POLLNVAL))) break;
    unsigned char report[128];ssize_t n=read(j->hid_fd,report,sizeof(report));
    if(n<0 && (errno==EINTR || errno==EAGAIN)) continue;
    if(n<=0)break;
    if(n>=15 && report[0]==0x21 && report[14]==packet[10]) {
      moonbit_bytes_t reply=moonbit_make_bytes((int)n,0);memcpy(reply,report,(size_t)n);return reply;
    }
  }
#else
  (void)j;(void)packet;
#endif
  return moonbit_make_bytes(0,0);
}

MOONBIT_FFI_EXPORT moonbit_bytes_t moonrobo_joy_read(NeckJoy *j) {
#ifdef __linux__
  joy_last_error[0]=0;
  int64_t captured;
  unsigned char buttons = 0;
  struct input_absinfo x, y;
  int zl, minus;
  if (!moonrobo_joy_valid(j) || joy_fresh_report(j->hid_fd, &captured, &buttons) < 0 ||
      ioctl(j->input_fd, EVIOCGABS(ABS_X), &x) < 0 ||
      ioctl(j->input_fd, EVIOCGABS(ABS_Y), &y) < 0 || joy_keys(j->input_fd, &zl, &minus) < 0)
    {if(!joy_last_error[0])snprintf(joy_last_error,sizeof(joy_last_error),"Joystick state read failed: errno=%d",errno);return moonbit_make_bytes(0, 0);}
  char json[512];
  int n = snprintf(json, sizeof(json),
    "{\"captured_ms\":\"%lld\",\"x\":%d,\"y\":%d,\"min_x\":%d,\"max_x\":%d,\"min_y\":%d,\"max_y\":%d,\"zl\":%s,\"minus\":%s,\"buttons\":%u}",
    (long long)captured, x.value, y.value, x.minimum, x.maximum, y.minimum, y.maximum,
    zl ? "true" : "false", minus ? "true" : "false", (unsigned)buttons);
  if (n < 0 || n >= (int)sizeof(json)) return moonbit_make_bytes(0, 0);
  moonbit_bytes_t result = moonbit_make_bytes(n, 0); memcpy(result, json, (size_t)n); return result;
#else
  (void)j; return moonbit_make_bytes(0, 0);
#endif
}
