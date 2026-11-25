// Linux synthetic input transport tests: no physical devices are opened.
#define _GNU_SOURCE
#include "joystick.c"
#include <stdlib.h>
#include <sys/socket.h>
#include <sys/wait.h>
static int failures;
#define CHECK(condition,name) do {if(!(condition)){fprintf(stderr,"FAIL %s\n",name);failures++;}}while(0)
static int sample(int reader, int writer, int malformed) {
  pid_t child=fork();
  if(child==0) {
    unsigned char report[49]={0x30};
    if(malformed)report[0]=0x21;
    usleep(10000);
    if(write(writer,report,sizeof(report))!=(ssize_t)sizeof(report))_exit(2);
    _exit(0);
  }
  int64_t captured=0;
  int status=joy_fresh_report(reader,&captured);
  int child_status=0;waitpid(child,&child_status,0);
  CHECK(WIFEXITED(child_status)&&WEXITSTATUS(child_status)==0,"synthetic HID producer exited");
  return status;
}
int main(void) {
  int pair[2];
  if(socketpair(AF_UNIX,SOCK_SEQPACKET|SOCK_NONBLOCK,0,pair)<0)return 2;
  unsigned char old[49]={0x30};int64_t captured;
  CHECK(write(pair[1],old,sizeof(old))==(ssize_t)sizeof(old),"queued old HID report");
  CHECK(joy_fresh_report(pair[0],&captured)<0,"queued stale report alone cannot count as heartbeat");
  CHECK(sample(pair[0],pair[1],0)==0,"fresh full HID report accepted");
  CHECK(sample(pair[0],pair[1],1)<0,"non-streaming report rejected");
  close(pair[1]);
  CHECK(joy_fresh_report(pair[0],&captured)<0,"disconnection stops input");
  close(pair[0]);
  NeckJoy *j=(NeckJoy *)moonbit_make_external_object(joy_destroy,sizeof(NeckJoy));
  j->input_fd=j->hid_fd=-1;
  moonbit_bytes_t raw=moonrobo_joy_read(j);
  CHECK(Moonbit_array_length(raw)==0,"closed device returns no sample");moonbit_decref(raw);
  moonrobo_joy_close(j);moonrobo_joy_close(j);moonbit_decref(j);
  printf("{\"physical_device_opened\":false,\"joystick_transport_test_failures\":%d}\n",failures);
  return failures?1:0;
}
