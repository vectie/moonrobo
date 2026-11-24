// Linux pseudo-terminal integration tests. Never opens a physical device.
// Compile with serial.c and the matching MoonBit runtime using the deployment
// script's verify mode. This standalone harness uses only runtime Bytes.
#define _GNU_SOURCE
#include "moonbit.h"
#include <fcntl.h>
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>

extern int32_t moonrobo_neck_open(moonbit_bytes_t);
extern void moonrobo_neck_close(int32_t);
extern int64_t moonrobo_neck_clock(void);
extern moonbit_bytes_t moonrobo_neck_exchange(int32_t,moonbit_bytes_t,int32_t,int64_t);
static moonbit_bytes_t bytes(const void *p,int n) {moonbit_bytes_t b=moonbit_make_bytes(n,0);memcpy(b,p,n);return b;}
static int failures;
#define CHECK(condition,name) do {if(!(condition)){fprintf(stderr,"FAIL %s\n",name);failures++;}}while(0)

int main(void) {
  int master=posix_openpt(O_RDWR|O_NOCTTY|O_CLOEXEC);
  if(master<0 || grantpt(master)<0 || unlockpt(master)<0) return 2;
  const char *path=ptsname(master);
  moonbit_bytes_t name=bytes(path,(int)strlen(path));
  int fd=moonrobo_neck_open(name);
  CHECK(fd>=0,"raw 1Mbps pseudo-terminal open");
  if(fd<0)return 3;
  int second=moonrobo_neck_open(name);
  CHECK(second<0,"second serial owner rejected");
  if(second>=0)moonrobo_neck_close(second);
  unsigned char request[]={255,255,7,4,2,3,2,237};
  unsigned char reply[]={255,255,7,4,0,9,3,232};
  moonbit_bytes_t tx=bytes(request,8);
  for(int partial=0;partial<2;partial++) {
    pid_t child=fork();
    if(child==0) {
      close(fd);struct pollfd p={master,POLLIN,0};
      if(poll(&p,1,500)<=0)_exit(4);
      unsigned char received[8];if(read(master,received,8)!=8)_exit(5);
      if(partial){if(write(master,reply,3)!=3)_exit(6);}else{if(write(master,reply,1)!=1)_exit(7);usleep(5000);if(write(master,reply+1,7)!=7)_exit(8);}
      _exit(0);
    }
    moonbit_bytes_t raw=moonrobo_neck_exchange(fd,tx,8,moonrobo_neck_clock()+150);
    CHECK(Moonbit_array_length(raw)==(partial?3:8),partial?"partial reply bounded and returned":"fragmented reply assembled");
    if(!partial && Moonbit_array_length(raw)==8)CHECK(memcmp(raw,reply,8)==0,"reply bytes preserved");
    moonbit_decref(raw);int status=0;waitpid(child,&status,0);CHECK(WIFEXITED(status)&&WEXITSTATUS(status)==0,"responder completed");
  }
  moonbit_bytes_t stale=moonrobo_neck_exchange(fd,tx,8,moonrobo_neck_clock()-1);
  CHECK(Moonbit_array_length(stale)==0,"stale dispatch rejected");moonbit_decref(stale);
  struct pollfd p={master,POLLIN,0};CHECK(poll(&p,1,30)==0,"stale dispatch sent zero bytes");
  moonbit_bytes_t invalid=moonrobo_neck_exchange(fd,tx,999,0);
  CHECK(Moonbit_array_length(invalid)==0,"invalid response bound rejected");moonbit_decref(invalid);
  moonrobo_neck_close(fd);
  int reopened=moonrobo_neck_open(name);CHECK(reopened>=0,"exclusive ownership released on close");
  if(reopened>=0)moonrobo_neck_close(reopened);
  moonbit_decref(tx);moonbit_decref(name);close(master);
  printf("{\"physical_device_opened\":false,\"transport_test_failures\":%d}\n",failures);
  return failures?1:0;
}
