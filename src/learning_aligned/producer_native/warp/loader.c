#include <moonbit.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include "native/warp_writer.h"
#ifdef _WIN32
#include <windows.h>
#else
#include <dlfcn.h>
#endif
typedef struct {
 void* module; mrw_writer* writer; char failure[2048];
#define FIELD(name) __typeof__(&mrw_##name) name
 FIELD(error); FIELD(borrow); FIELD(create); FIELD(release); FIELD(version); FIELD(library);
 FIELD(state_pointer); FIELD(begin); FIELD(end); FIELD(operation_count); FIELD(register_region); FIELD(snapshot_region);
 FIELD(register_module); FIELD(register_kernel); FIELD(register_binding); FIELD(register_pointer_location);
 FIELD(register_mesh); FIELD(save); FIELD(host_region); FIELD(host_pointer); FIELD(host_memset); FIELD(host_copy);
#undef FIELD
} Writer;
static int clean(moonbit_bytes_t s){return !memchr(s,0,(size_t)Moonbit_array_length(s));}
static moonbit_bytes_t copied(const char* text){size_t n=strlen(text);if(n>INT32_MAX)n=0;moonbit_bytes_t b=moonbit_make_bytes((int32_t)n,0);if(n)memcpy(b,text,n);return b;}
static int finish(Writer* w){
 if(w->writer){if(w->release(w->writer)!=0)return -1;w->writer=NULL;}
 if(w->module){
#ifdef _WIN32
 FreeLibrary((HMODULE)w->module);
#else
 dlclose(w->module);
#endif
 w->module=NULL;}
 return 0;
}
static void finalized(void* p){(void)finish((Writer*)p);}
static void* sym(Writer* w,const char* name){
#ifdef _WIN32
 void* result=(void*)GetProcAddress((HMODULE)w->module,name);
#else
 void* result=dlsym(w->module,name);
#endif
 if(!result)snprintf(w->failure,sizeof(w->failure),"Warp authoring plugin missing %s",name);return result;
}
MOONBIT_FFI_EXPORT Writer* moonrobo_warp_writer_open(moonbit_bytes_t plugin,moonbit_bytes_t library,uint64_t state,uint64_t context,uint64_t stream,int32_t arch,int32_t owned){
 Writer* w=moonbit_make_external_object(finalized,sizeof(Writer));memset(w,0,sizeof(*w));
 if(!clean(plugin)||!clean(library)||!Moonbit_array_length(plugin)||!Moonbit_array_length(library)){snprintf(w->failure,sizeof(w->failure),"explicit NUL-free plugin and Warp paths required");return w;}
#ifdef _WIN32
 w->module=LoadLibraryA((const char*)plugin);
#else
 w->module=dlopen((const char*)plugin,RTLD_NOW|RTLD_LOCAL);
#endif
 if(!w->module){snprintf(w->failure,sizeof(w->failure),"cannot load explicit Warp authoring plugin");return w;}
 int(*abi)(void)=(int(*)(void))sym(w,"mrw_api_version");
#define LOAD(name) w->name=(__typeof__(w->name))sym(w,"mrw_" #name)
 LOAD(error);LOAD(borrow);LOAD(create);LOAD(release);LOAD(version);LOAD(library);
 LOAD(state_pointer);LOAD(begin);LOAD(end);LOAD(operation_count);LOAD(register_region);LOAD(snapshot_region);LOAD(register_module);
 LOAD(register_kernel);LOAD(register_binding);LOAD(register_pointer_location);LOAD(register_mesh);LOAD(save);
 LOAD(host_region);LOAD(host_pointer);LOAD(host_memset);LOAD(host_copy);
#undef LOAD
 if(w->failure[0])return w;
 if(abi()!=2){snprintf(w->failure,sizeof(w->failure),"unsupported Warp authoring plugin ABI (requires 2)");return w;}
 w->writer=owned?w->create((const char*)library,arch==0,context,stream,arch):w->borrow((const char*)library,state,context,stream,arch);
 if(!w->writer)snprintf(w->failure,sizeof(w->failure),"%s",w->error(NULL));return w;
}
static int live(Writer* w){if(w->writer)return 1;if(!w->failure[0])snprintf(w->failure,sizeof(w->failure),"Warp writer is closed");return 0;}
static int text(Writer* w,moonbit_bytes_t s){if(clean(s))return 1;snprintf(w->failure,sizeof(w->failure),"embedded NUL in authoring metadata");return 0;}
MOONBIT_FFI_EXPORT moonbit_bytes_t moonrobo_warp_writer_error(Writer* w){return copied(w->failure[0]?w->failure:w->writer?w->error(w->writer):"Warp writer is closed");}
MOONBIT_FFI_EXPORT moonbit_bytes_t moonrobo_warp_writer_version(Writer* w){return copied(live(w)?w->version(w->writer):"");}
MOONBIT_FFI_EXPORT moonbit_bytes_t moonrobo_warp_writer_library(Writer* w){return copied(live(w)?w->library(w->writer):"");}
MOONBIT_FFI_EXPORT int32_t moonrobo_warp_writer_close(Writer* w){return finish(w);}
#define SIMPLE(name) MOONBIT_FFI_EXPORT int32_t moonrobo_warp_writer_##name(Writer* w){return live(w)?w->name(w->writer):-1;}
SIMPLE(begin) SIMPLE(end)
MOONBIT_FFI_EXPORT uint32_t moonrobo_warp_writer_count(Writer* w){return live(w)?w->operation_count(w->writer):0;}
MOONBIT_FFI_EXPORT uint64_t moonrobo_warp_writer_state(Writer* w){return live(w)?w->state_pointer(w->writer):0;}
MOONBIT_FFI_EXPORT uint32_t moonrobo_warp_writer_region(Writer* w,uint64_t ptr,uint64_t size,uint32_t element){return live(w)?w->register_region(w->writer,ptr,size,element):0;}
MOONBIT_FFI_EXPORT int32_t moonrobo_warp_writer_snapshot(Writer* w,uint32_t id,uint64_t ptr,uint64_t size,uint32_t element,int32_t transient){return live(w)?w->snapshot_region(w->writer,id,ptr,size,element,transient):-1;}
MOONBIT_FFI_EXPORT int32_t moonrobo_warp_writer_module(Writer* w,moonbit_bytes_t hash,moonbit_bytes_t name,moonbit_bytes_t binary){return live(w)&&text(w,hash)&&text(w,name)&&text(w,binary)?w->register_module(w->writer,(const char*)hash,(const char*)name,(const char*)binary):-1;}
MOONBIT_FFI_EXPORT int32_t moonrobo_warp_writer_kernel(Writer* w,moonbit_bytes_t key,moonbit_bytes_t hash,moonbit_bytes_t forward,moonbit_bytes_t backward,int32_t fs,int32_t bs,int32_t block){return live(w)&&text(w,key)&&text(w,hash)&&text(w,forward)&&text(w,backward)?w->register_kernel(w->writer,(const char*)key,(const char*)hash,(const char*)forward,(const char*)backward,fs,bs,block):-1;}
MOONBIT_FFI_EXPORT int32_t moonrobo_warp_writer_binding(Writer* w,moonbit_bytes_t name,uint32_t id){return live(w)&&text(w,name)?w->register_binding(w->writer,(const char*)name,id):-1;}
MOONBIT_FFI_EXPORT int32_t moonrobo_warp_writer_pointer(Writer* w,uint32_t id,uint64_t offset,uint64_t stride){return live(w)?w->register_pointer_location(w->writer,id,offset,stride):-1;}
MOONBIT_FFI_EXPORT int32_t moonrobo_warp_writer_mesh(Writer* w,uint64_t mesh){return live(w)?w->register_mesh(w->writer,mesh):-1;}
MOONBIT_FFI_EXPORT int32_t moonrobo_warp_writer_save(Writer* w,moonbit_bytes_t path){return live(w)&&text(w,path)?w->save(w->writer,(const char*)path):-1;}
MOONBIT_FFI_EXPORT uint32_t moonrobo_warp_writer_host(Writer* w,moonbit_bytes_t bytes,uint32_t element){return live(w)?w->host_region(w->writer,bytes,(uint64_t)Moonbit_array_length(bytes),element):0;}
MOONBIT_FFI_EXPORT uint64_t moonrobo_warp_writer_host_pointer(Writer* w,uint32_t id){return live(w)?w->host_pointer(w->writer,id):0;}
MOONBIT_FFI_EXPORT int32_t moonrobo_warp_writer_memset(Writer* w,uint32_t id,uint64_t offset,int32_t value,uint64_t count){return live(w)?w->host_memset(w->writer,id,offset,value,count):-1;}
MOONBIT_FFI_EXPORT int32_t moonrobo_warp_writer_copy(Writer* w,uint32_t dst,uint64_t doff,uint32_t src,uint64_t soff,uint64_t count){return live(w)?w->host_copy(w->writer,dst,doff,src,soff,count):-1;}
