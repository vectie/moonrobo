#include <moonbit.h>
#include <dlfcn.h>
#include <stdint.h>
#include <string.h>
#ifdef __linux__
#include <pthread.h>
#include <stdio.h>
#include <unistd.h>

static long long number(const char *path) {
  FILE *f = fopen(path, "r"); long long v = -1;
  if (f) { if (fscanf(f, "%lld", &v) != 1) v = -1; fclose(f); }
  return v;
}

static int budgets(int startup) {
  FILE *f = fopen("/proc/meminfo", "r"); if (!f) return 0;
  long long a=-1,b=-1; char line[256];
  while (fgets(line,sizeof(line),f)) {
    if (sscanf(line,"MemFree: %lld kB",&b)==1) continue;
    if (sscanf(line,"MemAvailable: %lld kB",&a)==1) continue;
  }
  fclose(f);
  long long current=number("/sys/fs/cgroup/memory.current"), max=number("/sys/fs/cgroup/memory.max");
  int ok=a >= (startup?32LL:24LL)*1048576 && b >= (startup?24LL:12LL)*1048576 &&
    current>0 && current <= (84LL<<30) && max>0 && max-current >= (16LL<<30) &&
    number("/sys/fs/cgroup/memory.swap.current")==0 && number("/sys/fs/cgroup/memory.swap.max")==0;
  f=fopen("/sys/fs/cgroup/memory.events","r"); if (!f) return 0;
  int seen=0; char key[64]; long long n;
  while (fscanf(f,"%63s %lld",key,&n)==2) {
    if (!strcmp(key,"high") || !strcmp(key,"max") || !strcmp(key,"oom") || !strcmp(key,"oom_kill")) {
      seen++; if(n!=0) ok=0;
    }
  }
  fclose(f);
  if(!ok || seen!=4) fprintf(stderr,"BF16 memory guard: available_kib=%lld free_kib=%lld cgroup_bytes=%lld limit_bytes=%lld\n",a,b,current,max);
  return ok && seen==4;
}
static void *watch(void *unused) {
  (void)unused;
  for (;;) { sleep(1); if(!budgets(0)) _exit(75); }
  return NULL;
}
#endif
MOONBIT_FFI_EXPORT int32_t mr_start_bf16_watch(void) {
#ifdef __linux__
  pthread_t t;
  if(!budgets(1) || pthread_create(&t,NULL,watch,NULL)!=0) return 0;
  return pthread_detach(t)==0;
#else
  return 0;
#endif
}

MOONBIT_FFI_EXPORT int64_t mr_install_compiled_allocator(const uint8_t *path) {
  if (!path || path[0] != '/') return -10;
  // Keep the verified DSO and its allocator dependencies alive until exit.
  void *handle = dlopen((const char *)path, RTLD_NOW | RTLD_LOCAL);
  if (!handle) return -11;
  typedef int64_t (*install_fn)(int);
  install_fn install = (install_fn)dlsym(handle, "mr_install_compiled_allocator_cap_v1");
  return install ? install(0) : -12;
}
