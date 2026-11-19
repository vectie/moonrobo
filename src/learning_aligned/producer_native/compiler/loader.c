/* NVRTC's public C ABI only: this adapter does not include, initialize, or load
 * the CUDA driver and cannot translate Python/Warp source into CUDA. */
#include <moonbit.h>
#include <stdint.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <limits.h>
#if defined(_WIN32)
#include <windows.h>
#endif
#if !defined(_WIN32)
#include <dlfcn.h>
#endif
/* NVRTC's public declarations use the platform C calling convention, unlike
 * CUDA Driver's CUDAAPI declarations. */
#define NRCALL
#if defined(MOONROBO_NVRTC_VERIFY_HEADERS)
#include <nvrtc.h>
typedef nvrtcResult NRResult;
typedef nvrtcProgram NRProgram;
#else
typedef int NRResult;
typedef void* NRProgram;
#endif
typedef struct {
  void* library;
  NRResult (NRCALL *version)(int*,int*);
  const char* (NRCALL *error_string)(NRResult);
  NRResult (NRCALL *create)(NRProgram*,const char*,const char*,int,const char* const*,const char* const*);
  NRResult (NRCALL *compile)(NRProgram,int,const char* const*);
  NRResult (NRCALL *log_size)(NRProgram,size_t*);
  NRResult (NRCALL *log)(NRProgram,char*);
  NRResult (NRCALL *ptx_size)(NRProgram,size_t*);
  NRResult (NRCALL *ptx)(NRProgram,char*);
  NRResult (NRCALL *cubin_size)(NRProgram,size_t*);
  NRResult (NRCALL *cubin)(NRProgram,char*);
  NRResult (NRCALL *destroy)(NRProgram*);
  int major,minor;
  char error[2048];
} Compiler;
#if defined(MOONROBO_NVRTC_VERIFY_HEADERS)
/* Optional syntax-only signature verification against an installed genuine
 * NVIDIA SDK header. No stubs or replacement nvrtc.h files are accepted. */
#define VERIFY(field,name) _Static_assert(__builtin_types_compatible_p(__typeof__(((Compiler*)0)->field),__typeof__(&name)),"NVRTC C ABI mismatch: " #name)
VERIFY(version,nvrtcVersion);VERIFY(error_string,nvrtcGetErrorString);
VERIFY(create,nvrtcCreateProgram);VERIFY(compile,nvrtcCompileProgram);
VERIFY(log_size,nvrtcGetProgramLogSize);VERIFY(log,nvrtcGetProgramLog);
VERIFY(ptx_size,nvrtcGetPTXSize);VERIFY(ptx,nvrtcGetPTX);
VERIFY(cubin_size,nvrtcGetCUBINSize);VERIFY(cubin,nvrtcGetCUBIN);
VERIFY(destroy,nvrtcDestroyProgram);
#undef VERIFY
#endif
typedef struct {
  unsigned char* image; size_t image_size;
  char* log; size_t log_size;
  char error[2048];
} Compilation;
static moonbit_bytes_t copied(const void* ptr,size_t n){
  if(n>INT32_MAX)n=0;
  moonbit_bytes_t b=moonbit_make_bytes((int32_t)n,0);
  if(n)memcpy(b,ptr,n);return b;
}
static int clean(moonbit_bytes_t value){return !memchr(value,0,(size_t)Moonbit_array_length(value));}
static void compiler_cleanup(void* ptr){Compiler* c=ptr;if(c->library){
#if defined(_WIN32)
  FreeLibrary((HMODULE)c->library);
#else
  dlclose(c->library);
#endif
  c->library=NULL;
}}
static void compilation_cleanup(void* ptr){Compilation* c=ptr;free(c->image);free(c->log);c->image=NULL;c->log=NULL;}
static void* symbol(Compiler* c,const char* name){
#if defined(_WIN32)
  return (void*)GetProcAddress((HMODULE)c->library,name);
#else
  return dlsym(c->library,name);
#endif
}
MOONBIT_FFI_EXPORT Compiler* mr_apic_nvrtc_open(moonbit_bytes_t path){
  Compiler* c=moonbit_make_external_object(compiler_cleanup,sizeof(Compiler));memset(c,0,sizeof(*c));
  if(!clean(path)||!Moonbit_array_length(path)){strcpy(c->error,"explicit NUL-free NVRTC library path required");return c;}
#if defined(_WIN32)
  c->library=LoadLibraryA((const char*)path);
#else
  c->library=dlopen((const char*)path,RTLD_NOW|RTLD_LOCAL);
#endif
  if(!c->library){strcpy(c->error,"cannot load explicit NVRTC library (and its native dependencies)");return c;}
#define LOAD(field,name) do { *(void**)(&c->field)=symbol(c,name);if(!c->field){snprintf(c->error,sizeof(c->error),"NVRTC C ABI missing %s",name);return c;} }while(0)
  LOAD(version,"nvrtcVersion");LOAD(error_string,"nvrtcGetErrorString");
  LOAD(create,"nvrtcCreateProgram");LOAD(compile,"nvrtcCompileProgram");
  LOAD(log_size,"nvrtcGetProgramLogSize");LOAD(log,"nvrtcGetProgramLog");
  LOAD(ptx_size,"nvrtcGetPTXSize");LOAD(ptx,"nvrtcGetPTX");LOAD(destroy,"nvrtcDestroyProgram");
#undef LOAD
  *(void**)(&c->cubin_size)=symbol(c,"nvrtcGetCUBINSize");*(void**)(&c->cubin)=symbol(c,"nvrtcGetCUBIN");
  NRResult status=c->version(&c->major,&c->minor);
  if(status)snprintf(c->error,sizeof(c->error),"nvrtcVersion: %s (%d)",c->error_string(status),status);
  return c;
}
MOONBIT_FFI_EXPORT moonbit_bytes_t mr_apic_nvrtc_error(Compiler* c){return copied(c->error,strlen(c->error));}
MOONBIT_FFI_EXPORT int32_t mr_apic_nvrtc_major(Compiler* c){return c->major;}
MOONBIT_FFI_EXPORT int32_t mr_apic_nvrtc_minor(Compiler* c){return c->minor;}
static void failure(Compiler* c,Compilation* r,const char* stage,NRResult status){
  snprintf(r->error,sizeof(r->error),"%s: %s (%d)",stage,c->error_string(status),status);
}
MOONBIT_FFI_EXPORT Compilation* mr_apic_nvrtc_compile(Compiler* c,moonbit_bytes_t source,moonbit_bytes_t name,moonbit_bytes_t* headers,moonbit_bytes_t* names,moonbit_bytes_t* options,int32_t kind){
  Compilation* r=moonbit_make_external_object(compilation_cleanup,sizeof(Compilation));memset(r,0,sizeof(*r));
  if(c->error[0]){snprintf(r->error,sizeof(r->error),"%s",c->error);return r;}
  int nh=Moonbit_array_length(headers),nn=Moonbit_array_length(names),no=Moonbit_array_length(options);
  if(!clean(source)||!clean(name)||!Moonbit_array_length(name)||nh!=nn||(kind!=0&&kind!=1)){
    strcpy(r->error,"invalid NVRTC source/name/header arrays/output kind");return r;
  }
  for(int i=0;i<nh;i++)if(!clean(headers[i])||!clean(names[i])||!Moonbit_array_length(names[i])){strcpy(r->error,"invalid NUL in header or empty include name");return r;}
  for(int i=0;i<no;i++)if(!clean(options[i])||!Moonbit_array_length(options[i])){strcpy(r->error,"invalid NVRTC option");return r;}
  if(kind&&(!c->cubin_size||!c->cubin)){strcpy(r->error,"this NVRTC library has no CUBIN API");return r;}
  NRProgram p=NULL;
  NRResult status=c->create(&p,(const char*)source,(const char*)name,nh,(const char* const*)headers,(const char* const*)names);
  if(status){failure(c,r,"nvrtcCreateProgram",status);if(p)c->destroy(&p);return r;}
  status=c->compile(p,no,(const char* const*)options);
  NRResult log_status=c->log_size(p,&r->log_size);
  if(!log_status&&r->log_size){
    if(r->log_size>INT32_MAX){strcpy(r->error,"NVRTC log exceeds MoonBit capacity");goto done;}
    r->log=calloc(r->log_size,1);
    if(!r->log){strcpy(r->error,"cannot allocate NVRTC log");goto done;}
    log_status=c->log(p,r->log);
  }
  if(status){failure(c,r,"nvrtcCompileProgram",status);goto done;}
  if(log_status){failure(c,r,"nvrtcGetProgramLog",log_status);goto done;}
  status=kind?c->cubin_size(p,&r->image_size):c->ptx_size(p,&r->image_size);
  if(status){failure(c,r,"NVRTC image size",status);goto done;}
  if(!r->image_size||r->image_size>INT32_MAX){strcpy(r->error,"NVRTC produced empty or oversized image (CUBIN requires a real sm_ architecture)");goto done;}
  r->image=malloc(r->image_size);
  if(!r->image){strcpy(r->error,"cannot allocate NVRTC image");goto done;}
  status=kind?c->cubin(p,(char*)r->image):c->ptx(p,(char*)r->image);
  if(status)failure(c,r,"NVRTC get image",status);
done:
  status=c->destroy(&p);
  if(status&&!r->error[0])failure(c,r,"nvrtcDestroyProgram",status);
  return r;
}
MOONBIT_FFI_EXPORT moonbit_bytes_t mr_apic_nvrtc_compile_error(Compilation* r){return copied(r->error,strlen(r->error));}
MOONBIT_FFI_EXPORT moonbit_bytes_t mr_apic_nvrtc_compile_log(Compilation* r){size_t n=r->log?r->log_size:0;if(n&&r->log[n-1]==0)n--;return copied(r->log,n);}
MOONBIT_FFI_EXPORT moonbit_bytes_t mr_apic_nvrtc_image(Compilation* r){return copied(r->image,r->error[0]?0:r->image_size);}
