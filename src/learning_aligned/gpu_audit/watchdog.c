#include <moonbit.h>
#include <signal.h>
#include <unistd.h>
static void expired(int signal_number) {
  (void)signal_number;
  static const char message[] = "{\"format\":\"moonrobo.apic-replay-audit-error.v1\",\"error\":\"process deadline exceeded\",\"exit_code\":124}\n";
  (void)write(STDERR_FILENO,message,sizeof(message)-1);
  _exit(124);
}
MOONBIT_FFI_EXPORT int32_t mr_apic_audit_watchdog(int32_t seconds) {
  if(seconds==0){alarm(0);return 1;}
  if(seconds<5||seconds>600)return 0;
  struct sigaction action={0};action.sa_handler=expired;sigemptyset(&action.sa_mask);
  if(sigaction(SIGALRM,&action,0)!=0)return 0;
  alarm((unsigned)seconds);return 1;
}
