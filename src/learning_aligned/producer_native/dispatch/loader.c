#include <moonbit.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "native/dispatch.h"
#ifdef _WIN32
#include <windows.h>
#else
#include <dlfcn.h>
#endif
typedef struct {
 void* module;int refs;
#define FIELD(name) __typeof__(&mrd_##name) name
 FIELD(error);FIELD(open);FIELD(context_release);FIELD(context_pointer);FIELD(stream_pointer);FIELD(architecture);FIELD(synchronize);
 FIELD(copy_external);FIELD(zero_external);FIELD(allocate);FIELD(buffer_release);FIELD(buffer_pointer);FIELD(buffer_size);
 FIELD(write);FIELD(read);FIELD(load);FIELD(kernel_release);FIELD(launch);
 FIELD(scan);FIELD(segmented_sort);FIELD(partition_create);FIELD(partition_release);FIELD(conditional_begin);FIELD(conditional_enter);FIELD(conditional_leave);FIELD(conditional_finish);FIELD(conditional_abort);FIELD(conditional_release);
 FIELD(graph_begin);FIELD(graph_end);FIELD(graph_launch);FIELD(graph_release);
#undef FIELD
} Library;
typedef struct {Library* library;void* object;int kind;char error[2048];} Handle;
static int clean(moonbit_bytes_t text){return !memchr(text,0,(size_t)Moonbit_array_length(text));}
static moonbit_bytes_t copied(const char* s){size_t n=strlen(s);if(n>INT32_MAX)n=0;moonbit_bytes_t b=moonbit_make_bytes((int)n,0);if(n)memcpy(b,s,n);return b;}
static void finish(Handle* h){
 if(h->object&&h->library){if(h->kind==0)h->library->context_release(h->object);else if(h->kind==1)h->library->buffer_release(h->object);else if(h->kind==2)h->library->kernel_release(h->object);else if(h->kind==3)h->library->conditional_release(h->object);else if(h->kind==4)h->library->partition_release(h->object);else h->library->graph_release(h->object);h->object=NULL;}
 if(h->library){Library* l=h->library;h->library=NULL;if(--l->refs==0){if(l->module){
#ifdef _WIN32
 FreeLibrary((HMODULE)l->module);
#else
 dlclose(l->module);
#endif
 }free(l);}}
}
static void finalize(void* p){finish(p);}
static Handle* box(Library* l,void* object,int kind){Handle* h=moonbit_make_external_object(finalize,sizeof(Handle));memset(h,0,sizeof(*h));h->library=l;h->object=object;h->kind=kind;if(l)++l->refs;if(l&&!object)snprintf(h->error,sizeof(h->error),"%s",l->error());return h;}
static int live(Handle* h,int kind){if(h->object&&h->kind==kind)return 1;snprintf(h->error,sizeof(h->error),"dispatch handle is closed or has the wrong kind");return 0;}
static int status(Handle* h,int code){if(code)snprintf(h->error,sizeof(h->error),"%s",h->library->error());return code;}
static int text(Handle* h,moonbit_bytes_t s){if(clean(s))return 1;snprintf(h->error,sizeof(h->error),"embedded NUL in dispatch string");return 0;}
static void* sym(Handle* h,const char* name){
#ifdef _WIN32
 void* p=(void*)GetProcAddress((HMODULE)h->library->module,name);
#else
 void* p=dlsym(h->library->module,name);
#endif
 if(!p)snprintf(h->error,sizeof(h->error),"dispatch plugin missing %s",name);return p;
}
MOONBIT_FFI_EXPORT Handle* moonrobo_dispatch_open(moonbit_bytes_t plugin,moonbit_bytes_t warp,uint64_t context,uint64_t stream,int32_t arch,int32_t ordinal){
 Handle* h=box(NULL,NULL,0);if(!text(h,plugin)||!text(h,warp)||!Moonbit_array_length(plugin)||!Moonbit_array_length(warp)){snprintf(h->error,sizeof(h->error),"explicit NUL-free dispatch plugin and Warp library paths required");return h;}
 Library* l=calloc(1,sizeof(Library));if(!l){snprintf(h->error,sizeof(h->error),"dispatch loader allocation failed");return h;}h->library=l;l->refs=1;
#ifdef _WIN32
 l->module=LoadLibraryA((const char*)plugin);
#else
 l->module=dlopen((const char*)plugin,RTLD_NOW|RTLD_LOCAL);
#endif
 if(!l->module){snprintf(h->error,sizeof(h->error),"cannot load explicit dispatch plugin");return h;}
 int(*abi)(void)=(int(*)(void))sym(h,"mrd_abi");
#define LOAD(name) l->name=(__typeof__(l->name))sym(h,"mrd_" #name)
 LOAD(error);LOAD(open);LOAD(context_release);LOAD(context_pointer);LOAD(stream_pointer);LOAD(architecture);LOAD(synchronize);LOAD(copy_external);LOAD(zero_external);LOAD(allocate);LOAD(buffer_release);LOAD(buffer_pointer);LOAD(buffer_size);LOAD(write);LOAD(read);LOAD(load);LOAD(kernel_release);LOAD(launch);
 LOAD(scan);LOAD(segmented_sort);LOAD(partition_create);LOAD(partition_release);LOAD(conditional_begin);LOAD(conditional_enter);LOAD(conditional_leave);LOAD(conditional_finish);LOAD(conditional_abort);LOAD(conditional_release);
 LOAD(graph_begin);LOAD(graph_end);LOAD(graph_launch);LOAD(graph_release);
#undef LOAD
 if(h->error[0])return h;if(abi()!=3){snprintf(h->error,sizeof(h->error),"unsupported dispatch ABI (requires 3)");return h;}
 h->object=l->open((const char*)warp,context,stream,arch,ordinal);if(!h->object)snprintf(h->error,sizeof(h->error),"%s",l->error());return h;
}
MOONBIT_FFI_EXPORT moonbit_bytes_t moonrobo_dispatch_error(Handle* h){return copied(h->error[0]?h->error:h->object?"":"dispatch handle is closed or failed to open");}
MOONBIT_FFI_EXPORT void moonrobo_dispatch_close(Handle* h){finish(h);}
MOONBIT_FFI_EXPORT Handle* moonrobo_dispatch_retain(Handle* h){
 if(!live(h,0)){Handle* result=box(NULL,NULL,0);snprintf(result->error,sizeof(result->error),"%s",h->error);return result;}
 Handle* result=box(h->library,NULL,0);result->error[0]=0;
 mrd_context*(*retain)(mrd_context*)=(mrd_context*(*)(mrd_context*))sym(result,"mrd_context_retain");
 if(!retain)return result;
 result->object=retain(h->object);if(!result->object)snprintf(result->error,sizeof(result->error),"%s",h->library->error());
 return result;
}
MOONBIT_FFI_EXPORT uint64_t moonrobo_dispatch_context(Handle* h){return live(h,0)?h->library->context_pointer(h->object):0;}
MOONBIT_FFI_EXPORT uint64_t moonrobo_dispatch_stream(Handle* h){return live(h,0)?h->library->stream_pointer(h->object):0;}
MOONBIT_FFI_EXPORT int32_t moonrobo_dispatch_arch(Handle* h){return live(h,0)?h->library->architecture(h->object):0;}
MOONBIT_FFI_EXPORT int32_t moonrobo_dispatch_sync(Handle* h){return live(h,0)?status(h,h->library->synchronize(h->object)):-1;}
MOONBIT_FFI_EXPORT int32_t moonrobo_dispatch_external_copy(Handle* h,uint64_t dst,uint64_t src,uint64_t bytes,uint64_t state){return live(h,0)?status(h,h->library->copy_external(h->object,dst,src,bytes,state)):-1;}
MOONBIT_FFI_EXPORT int32_t moonrobo_dispatch_external_zero(Handle* h,uint64_t ptr,uint64_t bytes,uint64_t state){return live(h,0)?status(h,h->library->zero_external(h->object,ptr,bytes,state)):-1;}
MOONBIT_FFI_EXPORT Handle* moonrobo_dispatch_allocate(Handle* h,uint64_t size){if(!live(h,0))return box(NULL,NULL,1);return box(h->library,h->library->allocate(h->object,size),1);}
MOONBIT_FFI_EXPORT uint64_t moonrobo_dispatch_buffer_pointer(Handle* h){return live(h,1)?h->library->buffer_pointer(h->object):0;}
MOONBIT_FFI_EXPORT uint64_t moonrobo_dispatch_buffer_size(Handle* h){return live(h,1)?h->library->buffer_size(h->object):0;}
MOONBIT_FFI_EXPORT int32_t moonrobo_dispatch_write(Handle* h,uint64_t off,moonbit_bytes_t bytes){return live(h,1)?status(h,h->library->write(h->object,off,bytes,(size_t)Moonbit_array_length(bytes))):-1;}
MOONBIT_FFI_EXPORT moonbit_bytes_t moonrobo_dispatch_read(Handle* h,uint64_t off,int32_t count){if(count<0||!live(h,1))return copied("");moonbit_bytes_t result=moonbit_make_bytes(count,0);status(h,h->library->read(h->object,off,result,(size_t)count));return result;}
MOONBIT_FFI_EXPORT Handle* moonrobo_dispatch_load(Handle* h,moonbit_bytes_t path,moonbit_bytes_t name,moonbit_bytes_t hash,moonbit_bytes_t key,moonbit_bytes_t forward,moonbit_bytes_t backward,int32_t fs,int32_t bs,int32_t block,int32_t dim){
 if(!live(h,0)||!text(h,path)||!text(h,name)||!text(h,hash)||!text(h,key)||!text(h,forward)||!text(h,backward)){Handle* failed=box(NULL,NULL,2);snprintf(failed->error,sizeof(failed->error),"%s",h->error);return failed;}
 return box(h->library,h->library->load(h->object,(const char*)path,(const char*)name,(const char*)hash,(const char*)key,(const char*)forward,(const char*)backward,fs,bs,block,dim),2);
}
MOONBIT_FFI_EXPORT int32_t moonrobo_dispatch_launch(Handle* h,moonbit_bytes_t wire,Handle** buffers,uint64_t state){
 if(!live(h,2))return -1;int count=Moonbit_array_length(buffers);mrd_buffer** raw=count?malloc((size_t)count*sizeof(*raw)):NULL;if(count&&!raw){snprintf(h->error,sizeof(h->error),"launch buffer handle allocation failed");return -1;}
 for(int i=0;i<count;++i){if(!live(buffers[i],1)||buffers[i]->library!=h->library){free(raw);snprintf(h->error,sizeof(h->error),"launch buffer is closed or belongs to another plugin session");return -1;}raw[i]=buffers[i]->object;}
 int code=status(h,h->library->launch(h->object,wire,(size_t)Moonbit_array_length(wire),raw,(size_t)count,state));free(raw);return code;
}
static int same_buffer(Handle* context,Handle* buffer){if(!live(buffer,1)||context->library!=buffer->library){snprintf(context->error,sizeof(context->error),"primitive buffer is closed or belongs to another plugin session");return 0;}return 1;}
MOONBIT_FFI_EXPORT int32_t moonrobo_dispatch_scan(Handle* c,Handle* input,Handle* output,uint64_t in_offset,uint64_t out_offset,int32_t type,int32_t count,int32_t in_stride,int32_t out_stride,int32_t components,int32_t inclusive,uint64_t state){
 if(!live(c,0)||!same_buffer(c,input)||!same_buffer(c,output))return -1;
 return status(c,c->library->scan(c->object,input->object,output->object,in_offset,out_offset,type,count,in_stride,out_stride,components,inclusive,state));
}
MOONBIT_FFI_EXPORT Handle* moonrobo_dispatch_partition(Handle* c,moonbit_bytes_t values,int32_t count){
 if(!live(c,0)){Handle* failed=box(NULL,NULL,4);snprintf(failed->error,sizeof(failed->error),"%s",c->error);return failed;}
 return box(c->library,c->library->partition_create(c->object,values,(size_t)Moonbit_array_length(values),count),4);
}
MOONBIT_FFI_EXPORT int32_t moonrobo_dispatch_segmented_sort(Handle* c,Handle* keys,Handle* values,Handle* partition,uint64_t key_offset,uint64_t value_offset,int32_t type,uint64_t state){
 if(!live(c,0)||!same_buffer(c,keys)||!same_buffer(c,values))return -1;
 if(!live(partition,4)||c->library!=partition->library){snprintf(c->error,sizeof(c->error),"immutable sort partition is closed or belongs to another context");return -1;}
 return status(c,c->library->segmented_sort(c->object,keys->object,values->object,partition->object,key_offset,value_offset,type,state));
}
MOONBIT_FFI_EXPORT Handle* moonrobo_dispatch_conditional_begin(Handle* c,Handle* condition,uint64_t offset,uint64_t state,int32_t is_while,int32_t ptx,int32_t has_true,int32_t has_false){
 if(!live(c,0)||!same_buffer(c,condition)){Handle* failed=box(NULL,NULL,3);snprintf(failed->error,sizeof(failed->error),"%s",c->error);return failed;}
 return box(c->library,c->library->conditional_begin(c->object,condition->object,offset,state,is_while,ptx,has_true,has_false),3);
}
MOONBIT_FFI_EXPORT int32_t moonrobo_dispatch_conditional_enter(Handle* h,int32_t branch){return live(h,3)?status(h,h->library->conditional_enter(h->object,branch)):-1;}
MOONBIT_FFI_EXPORT int32_t moonrobo_dispatch_conditional_leave(Handle* h){return live(h,3)?status(h,h->library->conditional_leave(h->object)):-1;}
MOONBIT_FFI_EXPORT int32_t moonrobo_dispatch_conditional_finish(Handle* h){return live(h,3)?status(h,h->library->conditional_finish(h->object)):-1;}
MOONBIT_FFI_EXPORT Handle* moonrobo_dispatch_graph_begin(Handle* c,uint64_t state){
 if(!live(c,0)){Handle* failed=box(NULL,NULL,5);snprintf(failed->error,sizeof(failed->error),"%s",c->error);return failed;}
 return box(c->library,c->library->graph_begin(c->object,state),5);
}
MOONBIT_FFI_EXPORT int32_t moonrobo_dispatch_graph_end(Handle* h){return live(h,5)?status(h,h->library->graph_end(h->object)):-1;}
MOONBIT_FFI_EXPORT int32_t moonrobo_dispatch_graph_launch(Handle* h){return live(h,5)?status(h,h->library->graph_launch(h->object)):-1;}

MOONBIT_FFI_EXPORT int32_t moonrobo_dispatch_suggested_block_size(Handle* h,int32_t shared_memory,int32_t* block,int32_t* grid){
 if(!live(h,2))return -1;
 int(*query)(mrd_kernel*,int,int*,int*)=(int(*)(mrd_kernel*,int,int*,int*))sym(h,"mrd_suggested_block_size");
 if(!query)return -1;
 return status(h,query(h->object,shared_memory,block,grid));
}
