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
  void* library;
  void* object;
  const char* (*error)(void*);
  const char* (*json)(void*);
  const uint8_t* (*mjb)(void*,size_t*);
  void (*close)(void*);
  char failure[2048];
} Preparation;
static moonbit_bytes_t copied(const void* s,size_t n){
  if(n>INT32_MAX)n=0;
  moonbit_bytes_t result=moonbit_make_bytes((int32_t)n,0);
  if(n)memcpy(result,s,n);return result;
}
static int clean(moonbit_bytes_t s){return !memchr(s,0,(size_t)Moonbit_array_length(s));}
static void finish(Preparation* p){
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
static void finalized(void* ptr){finish((Preparation*)ptr);}
static void* symbol(Preparation* p,const char* name){
#if defined(_WIN32)
  void* result=(void*)GetProcAddress((HMODULE)p->library,name);
#else
  void* result=dlsym(p->library,name);
#endif
  if(!result)snprintf(p->failure,sizeof(p->failure),"native model preparation ABI missing %s",name);
  return result;
}
static Preparation* opened(moonbit_bytes_t path){
  Preparation* p=(Preparation*)moonbit_make_external_object(finalized,sizeof(Preparation));memset(p,0,sizeof(*p));
  if(!clean(path)||Moonbit_array_length(path)==0){snprintf(p->failure,sizeof(p->failure),"explicit NUL-free preparation adapter path required");return p;}
#if defined(_WIN32)
  p->library=LoadLibraryA((const char*)path);
#else
  p->library=dlopen((const char*)path,RTLD_NOW|RTLD_LOCAL);
#endif
  if(!p->library)snprintf(p->failure,sizeof(p->failure),"cannot load explicit native preparation adapter");
  return p;
}
MOONBIT_FFI_EXPORT Preparation* moonrobo_prepared_model_open(moonbit_bytes_t adapter,moonbit_bytes_t library,moonbit_bytes_t source){
  Preparation* p=opened(adapter);if(p->failure[0])return p;
  if(!clean(library)||!clean(source)){snprintf(p->failure,sizeof(p->failure),"embedded NUL in model path");return p;}
  int(*abi)(void)=(int(*)(void))symbol(p,"mr_prepared_model_abi");
  void*(*open)(const char*,const char*)=(void*(*)(const char*,const char*))symbol(p,"mr_prepared_model_open");
  p->close=(void(*)(void*))symbol(p,"mr_prepared_model_close");
  p->error=(const char*(*)(void*))symbol(p,"mr_prepared_model_error");
  p->json=(const char*(*)(void*))symbol(p,"mr_prepared_model_json");
  p->mjb=(const uint8_t*(*)(void*,size_t*))symbol(p,"mr_prepared_model_mjb");
  if(p->failure[0])return p;
  if(abi()!=1){snprintf(p->failure,sizeof(p->failure),"unsupported native model ABI");return p;}
  p->object=open((const char*)library,(const char*)source);
  if(!p->object)snprintf(p->failure,sizeof(p->failure),"native model preparation allocation failed");
  return p;
}
static int u32(moonbit_bytes_t bytes,size_t* cursor,uint32_t* value){
  size_t n=(size_t)Moonbit_array_length(bytes);if(*cursor>n||n-*cursor<4)return 0;
  const uint8_t* p=bytes+*cursor;*value=((uint32_t)p[0])|((uint32_t)p[1]<<8)|((uint32_t)p[2]<<16)|((uint32_t)p[3]<<24);*cursor+=4;return 1;
}
static char* read_text(moonbit_bytes_t bytes,size_t* cursor){
  uint32_t size=0;if(!u32(bytes,cursor,&size)||!size||size>1048576)return NULL;
  size_t n=(size_t)Moonbit_array_length(bytes);if(*cursor>n||size>n-*cursor||memchr(bytes+*cursor,0,size))return NULL;
  char* result=(char*)malloc((size_t)size+1);if(!result)return NULL;
  memcpy(result,bytes+*cursor,size);result[size]=0;*cursor+=size;return result;
}
MOONBIT_FFI_EXPORT Preparation* moonrobo_prepared_usd_open(moonbit_bytes_t adapter,moonbit_bytes_t source,moonbit_bytes_t wire){
  Preparation* p=opened(adapter);if(p->failure[0])return p;
  size_t cursor=0;uint32_t count=0;
  if(!clean(source)||!u32(wire,&cursor,&count)||count>256){snprintf(p->failure,sizeof(p->failure),"invalid USD variant wire or source path");return p;}
  char* names[256]={0};char* values[256]={0};
  for(uint32_t i=0;i<count;++i){names[i]=read_text(wire,&cursor);values[i]=read_text(wire,&cursor);if(!names[i]||!values[i]){snprintf(p->failure,sizeof(p->failure),"invalid USD variant string wire");break;}}
  if(cursor!=(size_t)Moonbit_array_length(wire))snprintf(p->failure,sizeof(p->failure),"trailing or truncated USD variant wire");
  if(!p->failure[0]){
    int(*abi)(void)=(int(*)(void))symbol(p,"mr_prepared_usd_abi");
    void*(*open)(const char*,const char*const*,const char*const*,size_t)=(void*(*)(const char*,const char*const*,const char*const*,size_t))symbol(p,"mr_prepared_usd_open");
    p->close=(void(*)(void*))symbol(p,"mr_prepared_usd_close");p->error=(const char*(*)(void*))symbol(p,"mr_prepared_usd_error");p->json=(const char*(*)(void*))symbol(p,"mr_prepared_usd_json");
    if(!p->failure[0]){
      if(abi()!=1)snprintf(p->failure,sizeof(p->failure),"unsupported native USD ABI");
      else {p->object=open((const char*)source,(const char*const*)names,(const char*const*)values,count);if(!p->object)snprintf(p->failure,sizeof(p->failure),"native USD metadata allocation failed");}
    }
  }
  for(uint32_t i=0;i<count;++i){free(names[i]);free(values[i]);}return p;
}
MOONBIT_FFI_EXPORT moonbit_bytes_t moonrobo_prepared_error(Preparation* p){
  const char* message=p->failure[0]?p->failure:p->object&&p->error?p->error(p->object):"preparation handle closed";
  return copied(message,strlen(message));
}
MOONBIT_FFI_EXPORT moonbit_bytes_t moonrobo_prepared_json(Preparation* p){
  if(!p->object||!p->json)return copied("",0);const char* text=p->json(p->object);return copied(text,strlen(text));
}
MOONBIT_FFI_EXPORT moonbit_bytes_t moonrobo_prepared_mjb(Preparation* p){
  size_t size=0;const uint8_t* data=p->object&&p->mjb?p->mjb(p->object,&size):NULL;
  if(!data||!size||size>256u*1024u*1024u){snprintf(p->failure,sizeof(p->failure),"compiled MJB buffer missing or exceeds limit");return copied("",0);}
  return copied(data,size);
}
MOONBIT_FFI_EXPORT void moonrobo_prepared_close(Preparation* p){finish(p);}
