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
  int setup_pair[2];
  if(socketpair(AF_UNIX,SOCK_SEQPACKET|SOCK_NONBLOCK,0,setup_pair)<0)return 2;
  NeckJoy setup={dup(setup_pair[0]),setup_pair[0]};
  unsigned char packet[12]={1,0,0,1,0x40,0x40,0,1,0x40,0x40,0x40,1};
  const unsigned char commands[3][2]={{0x40,1},{3,0x30},{0x30,1}};
  for(int i=0;i<3;i++) {
    packet[1]=(unsigned char)i;packet[10]=commands[i][0];packet[11]=commands[i][1];
    moonbit_bytes_t request=moonbit_make_bytes(12,0);memcpy(request,packet,12);
    CHECK(moonrobo_joy_write_setup(&setup,request)==0,"input setup command accepted");
    unsigned char received[12];CHECK(read(setup_pair[1],received,12)==12 && memcmp(received,packet,12)==0,"setup packet preserved");
    moonbit_decref(request);
  }
  // Explicitly forbid SPI writes, arbitrary report modes and changed rumble.
  for(int i=0;i<3;i++) {
    packet[10]=i==0?0x11:3;packet[11]=i==1?0x3f:0x30;packet[2]=i==2?0x80:0;
    moonbit_bytes_t request=moonbit_make_bytes(12,0);memcpy(request,packet,12);
    CHECK(moonrobo_joy_write_setup(&setup,request)<0,"unsafe HID setup rejected");moonbit_decref(request);
  }
  struct pollfd no_output={setup_pair[1],POLLIN,0};CHECK(poll(&no_output,1,10)==0,"rejected HID commands sent zero bytes");
  packet[2]=0;packet[10]=0x40;packet[11]=1;
  moonbit_bytes_t setup_request=moonbit_make_bytes(12,0);memcpy(setup_request,packet,12);
  for(int match=0;match<2;match++) {
    pid_t child=fork();
    if(child==0) {
      struct pollfd ready={setup_pair[1],POLLIN,0};
      if(poll(&ready,1,500)<=0)_exit(4);
      unsigned char request[12];if(read(setup_pair[1],request,12)!=12)_exit(5);
      unsigned char reply[15]={0x21};reply[13]=0x80;reply[14]=match?0x40:3;
      if(write(setup_pair[1],reply,15)!=15)_exit(6);_exit(0);
    }
    moonbit_bytes_t reply=moonrobo_joy_setup_reply(&setup,setup_request);
    CHECK(Moonbit_array_length(reply)==(match?15:0),"setup reply must match requested subcommand");moonbit_decref(reply);
    int status;waitpid(child,&status,0);CHECK(WIFEXITED(status)&&WEXITSTATUS(status)==0,"synthetic setup responder exited");
  }
  moonbit_decref(setup_request);
  joy_destroy(&setup);close(setup_pair[1]);
  printf("{\"physical_device_opened\":false,\"joystick_transport_test_failures\":%d}\n",failures);
  return failures?1:0;
}
