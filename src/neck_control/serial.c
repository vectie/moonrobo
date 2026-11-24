#include "moonbit.h"
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/file.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>
#ifdef __linux__
#include <termios.h>
#endif

static char last_error[256];
static volatile sig_atomic_t interrupted;
static void (*old_int)(int);
static void (*old_term)(int);
static void on_signal(int sig) { (void)sig; interrupted = 1; }
static void set_error(const char *what) { snprintf(last_error, sizeof(last_error), "%s: %s", what, strerror(errno)); }
static int64_t monotonic_ms(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return (int64_t)t.tv_sec * 1000 + t.tv_nsec / 1000000; }
MOONBIT_FFI_EXPORT int64_t moonrobo_neck_clock(void) { return monotonic_ms(); }
MOONBIT_FFI_EXPORT int64_t moonrobo_neck_epoch(void) { struct timespec t; clock_gettime(CLOCK_REALTIME, &t); return (int64_t)t.tv_sec * 1000 + t.tv_nsec / 1000000; }
MOONBIT_FFI_EXPORT int32_t moonrobo_neck_interrupted(void) { return interrupted != 0; }
MOONBIT_FFI_EXPORT void moonrobo_neck_sleep(int32_t ms) { if (ms > 0 && ms <= 1000) { struct timespec t = { ms/1000, (ms%1000)*1000000L }; nanosleep(&t, NULL); } }
MOONBIT_FFI_EXPORT moonbit_bytes_t moonrobo_neck_error(void) { int n=(int)strlen(last_error); moonbit_bytes_t b=moonbit_make_bytes(n,0); memcpy(b,last_error,n); return b; }

MOONBIT_FFI_EXPORT int32_t moonrobo_neck_open(moonbit_bytes_t path) {
#ifdef __linux__
  interrupted=0;
  int fd=open((char *)path,O_RDWR|O_NOCTTY|O_NONBLOCK|O_CLOEXEC);
  if(fd<0) {set_error("open serial"); return -1;}
  if(flock(fd,LOCK_EX|LOCK_NB)<0) {set_error("serial already owned");close(fd);return -1;}
  if(ioctl(fd,TIOCEXCL)<0) {set_error("TIOCEXCL");close(fd);return -1;}
  struct termios t;
  if(tcgetattr(fd,&t)<0) goto fail;
  cfmakeraw(&t); t.c_cflag |= CLOCAL|CREAD; t.c_cflag &= ~(HUPCL|CSTOPB|PARENB|CRTSCTS);
  t.c_cflag=(t.c_cflag&~CSIZE)|CS8; t.c_cc[VMIN]=0;t.c_cc[VTIME]=0;
  if(cfsetispeed(&t,B1000000)<0 || cfsetospeed(&t,B1000000)<0 || tcsetattr(fd,TCSANOW,&t)<0) goto fail;
  if(tcflush(fd,TCIFLUSH)<0) goto fail;
  old_int=signal(SIGINT,on_signal); old_term=signal(SIGTERM,on_signal);
  return fd;
fail:
  set_error("configure serial");ioctl(fd,TIOCNXCL);close(fd);return -1;
#else
  (void)path; errno=ENOTSUP;set_error("ELF serial transport requires Linux");return -1;
#endif
}
MOONBIT_FFI_EXPORT void moonrobo_neck_close(int32_t fd) {
  if(fd>=0) {ioctl(fd,TIOCNXCL);flock(fd,LOCK_UN);close(fd);signal(SIGINT,old_int);signal(SIGTERM,old_term);}
  // Closing never writes goals, toggles torque, or restores a register block.
}

MOONBIT_FFI_EXPORT moonbit_bytes_t moonrobo_neck_exchange(int32_t fd, moonbit_bytes_t tx, int32_t expected, int64_t expires_at) {
  unsigned char rx[256]; int used=0, sent=0, length=Moonbit_array_length(tx);
  last_error[0]=0;
  if(fd<0 || expected<6 || expected>256 || length<6 || length>256) {errno=EINVAL;set_error("invalid serial bounds");return moonbit_make_bytes(0,0);}
#ifdef __linux__
  if(tcflush(fd,TCIFLUSH)<0) {set_error("flush stale input");return moonbit_make_bytes(0,0);}
#endif
  int64_t deadline=monotonic_ms()+100;
  while(sent<length) {
    if(expires_at>0 && monotonic_ms()>expires_at) break;
    int wait=(int)(deadline-monotonic_ms()); if(wait<=0) break;
    struct pollfd p={fd,POLLOUT,0}; int n=poll(&p,1,wait);
    if(n<0&&errno==EINTR) continue;
    if(n<=0 || (p.revents&(POLLERR|POLLHUP|POLLNVAL))) break;
    if(expires_at>0 && monotonic_ms()>expires_at) break;
    ssize_t wrote=write(fd,tx+sent,(size_t)(length-sent));
    if(wrote>0) sent+=(int)wrote; else if(errno!=EAGAIN&&errno!=EINTR) break;
  }
  if(sent!=length) {errno=ETIMEDOUT;set_error("serial transmit incomplete; no retry");return moonbit_make_bytes(0,0);}
  while(used<expected) {
    int wait=(int)(deadline-monotonic_ms()); if(wait<=0) break;
    struct pollfd p={fd,POLLIN,0};int n=poll(&p,1,wait);
    if(n<0&&errno==EINTR) continue;
    if(n<=0 || (p.revents&(POLLERR|POLLHUP|POLLNVAL))) break;
    ssize_t got=read(fd,rx+used,(size_t)(expected-used));
    if(got>0) used+=(int)got; else if(errno!=EAGAIN&&errno!=EINTR) break;
  }
  if(used!=expected) {errno=ETIMEDOUT;set_error("serial response incomplete; no retry");}
  moonbit_bytes_t result=moonbit_make_bytes(used,0);memcpy(result,rx,(size_t)used);return result;
}

static int append_all(int fd,const unsigned char *data,size_t length) {
  while(length) {ssize_t n=write(fd,data,length);if(n<0&&errno==EINTR) continue;if(n<=0)return -1;data+=n;length-=(size_t)n;}return 0;
}
static int sync_parent(const char *path) {
  char parent[4096];size_t n=strlen(path);
  if(n>=sizeof(parent)){errno=ENAMETOOLONG;return -1;}
  memcpy(parent,path,n+1);char *slash=strrchr(parent,'/');
  if(!slash){strcpy(parent,".");}else if(slash==parent){parent[1]=0;}else{*slash=0;}
  int fd=open(parent,O_RDONLY|O_DIRECTORY|O_CLOEXEC);
  if(fd<0)return -1;int result=fsync(fd);close(fd);return result;
}
MOONBIT_FFI_EXPORT int32_t moonrobo_neck_audit(moonbit_bytes_t path, moonbit_bytes_t line) {
  int fd=open((char *)path,O_CREAT|O_APPEND|O_WRONLY|O_CLOEXEC|O_NOFOLLOW,0600);
  if(fd<0) {set_error("open audit log");return -1;}
  int n=Moonbit_array_length(line);
  int ok=append_all(fd,line,(size_t)n)==0 && append_all(fd,(const unsigned char *)"\n",1)==0 && fsync(fd)==0 && sync_parent((char *)path)==0;
  if(!ok)set_error("persist audit log");close(fd);return ok?0:-1;
}
MOONBIT_FFI_EXPORT int32_t moonrobo_neck_fault_exists(moonbit_bytes_t path) { return access((char *)path,F_OK)==0; }
MOONBIT_FFI_EXPORT int32_t moonrobo_neck_latch_fault(moonbit_bytes_t path) {
  int fd=open((char *)path,O_CREAT|O_WRONLY|O_CLOEXEC|O_NOFOLLOW,0600);
  if(fd<0){set_error("persist fault latch");return -1;}
  int result=fsync(fd);close(fd);if(result==0)result=sync_parent((char *)path);return result;
}
MOONBIT_FFI_EXPORT int32_t moonrobo_neck_clear_fault(moonbit_bytes_t path) {if(unlink((char *)path)<0)return -1;return sync_parent((char *)path);}
MOONBIT_FFI_EXPORT int32_t moonrobo_neck_consume_receipt(moonbit_bytes_t path) {
  int fd=open((char *)path,O_CREAT|O_EXCL|O_WRONLY|O_CLOEXEC|O_NOFOLLOW,0600);
  if(fd<0){set_error("execution intent already consumed or journal unavailable");return -1;}
  int result=fsync(fd);close(fd);if(result==0)result=sync_parent((char *)path);return result;
}
