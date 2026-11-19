#include <moonbit.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <limits.h>
#if defined(_WIN32)
#include <windows.h>
#else
#include <dlfcn.h>
#endif
typedef struct {
  void* library;void* object;
  const char* (*error)(void*);const char* (*json)(void*);
  int (*run)(void*,const double*,size_t);void (*close)(void*);
  char failure[2048];
} Collision;
static moonbit_bytes_t copied(const char* s){size_t n=strlen(s);if(n>INT32_MAX)n=0;moonbit_bytes_t out=moonbit_make_bytes((int32_t)n,0);if(n)memcpy(out,s,n);return out;}
static int clean(moonbit_bytes_t s){return Moonbit_array_length(s)>0&&!memchr(s,0,(size_t)Moonbit_array_length(s));}
static void finish(Collision* p){
  if(p->object&&p->close)p->close(p->object);p->object=NULL;
  if(p->library){
#if defined(_WIN32)
    FreeLibrary((HMODULE)p->library);
#else
    dlclose(p->library);
#endif
    p->library=NULL;
  }
}
static void finalized(void* p){finish((Collision*)p);}
static void* symbol(Collision* p,const char* name){
#if defined(_WIN32)
  void* result=(void*)GetProcAddress((HMODULE)p->library,name);
#else
  void* result=dlsym(p->library,name);
#endif
  if(!result)snprintf(p->failure,sizeof(p->failure),"native collision ABI missing %s",name);return result;
}
MOONBIT_FFI_EXPORT Collision* moonrobo_collision_open(moonbit_bytes_t adapter,moonbit_bytes_t library,moonbit_bytes_t mjb,int32_t capacity){
  Collision* p=(Collision*)moonbit_make_external_object(finalized,sizeof(Collision));memset(p,0,sizeof(*p));
  if(!clean(adapter)||!clean(library)||!clean(mjb)||capacity<0){snprintf(p->failure,sizeof(p->failure),"explicit NUL-free paths/nonnegative capacity required");return p;}
#if defined(_WIN32)
  p->library=LoadLibraryA((const char*)adapter);
#else
  p->library=dlopen((const char*)adapter,RTLD_NOW|RTLD_LOCAL);
#endif
  if(!p->library){snprintf(p->failure,sizeof(p->failure),"cannot load explicit native collision adapter");return p;}
  int(*abi)(void)=(int(*)(void))symbol(p,"mr_collision_abi");
  void*(*open)(const char*,const char*,int)=(void*(*)(const char*,const char*,int))symbol(p,"mr_collision_open");
  p->close=(void(*)(void*))symbol(p,"mr_collision_close");
  p->error=(const char*(*)(void*))symbol(p,"mr_collision_error");
  p->json=(const char*(*)(void*))symbol(p,"mr_collision_json");
  p->run=(int(*)(void*,const double*,size_t))symbol(p,"mr_collision_run");
  if(p->failure[0])return p;
  if(abi()!=1){snprintf(p->failure,sizeof(p->failure),"native collision ABI version mismatch");return p;}
  p->object=open((const char*)library,(const char*)mjb,capacity);
  if(!p->object)snprintf(p->failure,sizeof(p->failure),"native collision allocation failed");return p;
}
MOONBIT_FFI_EXPORT moonbit_bytes_t moonrobo_collision_error(Collision* p){return copied(p->failure[0]?p->failure:p->object&&p->error?p->error(p->object):"native collision session closed");}
MOONBIT_FFI_EXPORT moonbit_bytes_t moonrobo_collision_json(Collision* p){return copied(p->object&&p->json?p->json(p->object):"");}
MOONBIT_FFI_EXPORT int32_t moonrobo_collision_run(Collision* p,double* qpos){
  if(p->failure[0]||!p->object||!p->run)return -1;
  return p->run(p->object,qpos,(size_t)Moonbit_array_length(qpos));
}
MOONBIT_FFI_EXPORT void moonrobo_collision_close(Collision* p){finish(p);}
