/* Only a dynamic C ABI bridge; no CUDA/SDK fallback and no Python linkage. */
#include <moonbit.h>
#include <dlfcn.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
typedef struct {
  void *library,*runtime;
  void *(*open)(int,int);void (*close)(void*);const char *(*error)(void*);
  int (*graph)(void*,int,const char*);int (*share)(void*,const char*,int64_t,int);
  int (*view)(void*,const char*,const char*,int64_t,int64_t,int64_t,int,int);
  int (*origin)(void*,int,double,double,double);int (*seal)(void*);
  int (*read)(void*,double*);int (*step)(void*,const double*);
  int (*reset)(void*,const double*,const double*);int (*refresh)(void*);
  int (*context_write)(void*,const char*,int64_t,double);int (*context_commit)(void*);
  int (*audit_view)(void*,const char*,double*,int);
  int (*audit_values)(void*,const char*,const int64_t*,int,double*);
  int64_t (*audit_free_bytes)(void*);
  int (*audit_view_selected)(void*,const char*,const int32_t*,int,double*,int);
  int (*audit_read_selected)(void*,const int32_t*,int,double*,int);
  int (*audit_capacity_v1)(void*,int);
  char failure[1024];
} Handle;
static void cleanup(void *p){Handle *h=p;if(h->runtime&&h->close)h->close(h->runtime);h->runtime=NULL;if(h->library)dlclose(h->library);h->library=NULL;}
static int ready(Handle *h){if(!h->runtime){if(!h->failure[0])snprintf(h->failure,sizeof(h->failure),"native APIC runtime is closed");return 0;}return 1;}
MOONBIT_FFI_EXPORT Handle *mr_mbt_apic_open(const unsigned char *library,int32_t device,int32_t worlds){
  Handle *h=moonbit_make_external_object(cleanup,sizeof(Handle));memset(h,0,sizeof(*h));
  h->library=dlopen((const char*)library,RTLD_NOW|RTLD_LOCAL);
  if(!h->library){snprintf(h->failure,sizeof(h->failure),"%s",dlerror());return h;}
#define LOAD(field,symbol) do{*(void**)(&h->field)=dlsym(h->library,symbol);if(!h->field){snprintf(h->failure,sizeof(h->failure),"missing native APIC symbol %s",symbol);return h;}}while(0)
  LOAD(open,"mr_apic_open");LOAD(close,"mr_apic_close");LOAD(error,"mr_apic_error");LOAD(graph,"mr_apic_graph");LOAD(share,"mr_apic_share");LOAD(view,"mr_apic_view");LOAD(origin,"mr_apic_origin");LOAD(seal,"mr_apic_seal");LOAD(read,"mr_apic_read");LOAD(step,"mr_apic_step");LOAD(reset,"mr_apic_reset");LOAD(refresh,"mr_apic_refresh");LOAD(context_write,"mr_apic_context_write");LOAD(context_commit,"mr_apic_context_commit");
#undef LOAD
  *(void**)(&h->audit_view)=dlsym(h->library,"mr_apic_audit_view");
  *(void**)(&h->audit_values)=dlsym(h->library,"mr_apic_audit_values");
  *(void**)(&h->audit_free_bytes)=dlsym(h->library,"mr_apic_audit_free_bytes");
  *(void**)(&h->audit_view_selected)=dlsym(h->library,"mr_apic_audit_view_selected");
  *(void**)(&h->audit_read_selected)=dlsym(h->library,"mr_apic_audit_read_selected");
  *(void**)(&h->audit_capacity_v1)=dlsym(h->library,"mr_apic_audit_capacity_v1");
  h->runtime=h->open(device,worlds);
  if(!h->runtime)snprintf(h->failure,sizeof(h->failure),"%s",h->error(NULL));
  return h;
}
MOONBIT_FFI_EXPORT moonbit_bytes_t mr_mbt_apic_error(Handle *h){const char *s=h->failure[0]?h->failure:(h->runtime?h->error(h->runtime):"native APIC runtime is closed");size_t n=strlen(s);moonbit_bytes_t b=moonbit_make_bytes((int32_t)n,0);memcpy(b,s,n);return b;}
MOONBIT_FFI_EXPORT void mr_mbt_apic_close(Handle *h){cleanup(h);}
MOONBIT_FFI_EXPORT int32_t mr_mbt_apic_graph(Handle *h,int32_t role,const unsigned char *path){return ready(h)&&h->graph(h->runtime,role,(const char*)path);}
MOONBIT_FFI_EXPORT int32_t mr_mbt_apic_share(Handle *h,const unsigned char *name,int64_t bytes,int32_t scalar){return ready(h)&&h->share(h->runtime,(const char*)name,bytes,scalar);}
MOONBIT_FFI_EXPORT int32_t mr_mbt_apic_view(Handle *h,const unsigned char *name,const unsigned char *binding,int64_t offset,int64_t row,int64_t component,int32_t width,int32_t scalar){return ready(h)&&h->view(h->runtime,(const char*)name,(const char*)binding,offset,row,component,width,scalar);}
MOONBIT_FFI_EXPORT int32_t mr_mbt_apic_origin(Handle *h,int32_t world,double x,double y,double z){return ready(h)&&h->origin(h->runtime,world,x,y,z);}
MOONBIT_FFI_EXPORT int32_t mr_mbt_apic_operation(Handle *h,int32_t operation){if(!ready(h))return 0;switch(operation){case 0:return h->seal(h->runtime);case 1:return h->refresh(h->runtime);case 2:return h->context_commit(h->runtime);default:snprintf(h->failure,sizeof(h->failure),"unknown native APIC operation");return 0;}}
MOONBIT_FFI_EXPORT int32_t mr_mbt_apic_read(Handle *h,double *out){return ready(h)&&h->read(h->runtime,out);}
MOONBIT_FFI_EXPORT int32_t mr_mbt_apic_step(Handle *h,const double *targets){return ready(h)&&h->step(h->runtime,targets);}
MOONBIT_FFI_EXPORT int32_t mr_mbt_apic_reset(Handle *h,const double *mask,const double *state){return ready(h)&&h->reset(h->runtime,mask,state);}
MOONBIT_FFI_EXPORT int32_t mr_mbt_apic_context(Handle *h,const unsigned char *binding,int64_t index,double value){return ready(h)&&h->context_write(h->runtime,(const char*)binding,index,value);}
MOONBIT_FFI_EXPORT int32_t mr_mbt_apic_audit_view(Handle *h,const unsigned char *name,double *out){if(!ready(h))return 0;if(!h->audit_view){snprintf(h->failure,sizeof(h->failure),"APIC plugin lacks optional bounded audit view ABI; rebuild runtime plugin");return 0;}return h->audit_view(h->runtime,(const char*)name,out,Moonbit_array_length(out));}
MOONBIT_FFI_EXPORT int32_t mr_mbt_apic_audit_values(Handle *h,const unsigned char *binding,const int64_t *indices,double *out){if(!ready(h))return 0;int n=Moonbit_array_length(indices);if(n!=Moonbit_array_length(out)||n<=0||n>4096){snprintf(h->failure,sizeof(h->failure),"invalid audit array lengths");return 0;}if(!h->audit_values){snprintf(h->failure,sizeof(h->failure),"APIC plugin lacks optional bounded audit index ABI; rebuild runtime plugin");return 0;}return h->audit_values(h->runtime,(const char*)binding,indices,n,out);}
MOONBIT_FFI_EXPORT int64_t mr_mbt_apic_audit_free_bytes(Handle *h){if(!ready(h))return 0;if(!h->audit_free_bytes){snprintf(h->failure,sizeof(h->failure),"APIC plugin lacks optional CUDA memory audit ABI; rebuild runtime plugin");return 0;}return h->audit_free_bytes(h->runtime);}
MOONBIT_FFI_EXPORT int32_t mr_mbt_apic_audit_view_selected(Handle *h,const unsigned char *name,const int32_t *worlds,double *out){if(!ready(h))return 0;int n=Moonbit_array_length(worlds);if(n<1||n>3||Moonbit_array_length(out)>4096){snprintf(h->failure,sizeof(h->failure),"invalid selected audit array lengths");return 0;}if(!h->audit_view_selected){snprintf(h->failure,sizeof(h->failure),"APIC plugin lacks optional v2 selected audit view ABI; rebuild runtime plugin");return 0;}return h->audit_view_selected(h->runtime,(const char*)name,worlds,n,out,Moonbit_array_length(out));}
MOONBIT_FFI_EXPORT int32_t mr_mbt_apic_audit_read_selected(Handle *h,const int32_t *worlds,double *out){if(!ready(h))return 0;int n=Moonbit_array_length(worlds);if(n<1||n>3||Moonbit_array_length(out)!=n*71){snprintf(h->failure,sizeof(h->failure),"invalid selected state71 array lengths");return 0;}if(!h->audit_read_selected){snprintf(h->failure,sizeof(h->failure),"APIC plugin lacks optional v2 selected state71 ABI; rebuild runtime plugin");return 0;}return h->audit_read_selected(h->runtime,worlds,n,out,Moonbit_array_length(out));}
MOONBIT_FFI_EXPORT int32_t mr_mbt_apic_audit_capacity_v1(Handle *h,int32_t maximum_worlds){if(!ready(h))return 0;if(maximum_worlds!=128&&maximum_worlds!=4096){snprintf(h->failure,sizeof(h->failure),"invalid explicit APIC audit capacity");return 0;}if(!h->audit_capacity_v1||!h->audit_view_selected||!h->audit_read_selected||!h->audit_values){snprintf(h->failure,sizeof(h->failure),"APIC plugin lacks optional paper-4096 capacity/selected-audit ABI; rebuild runtime plugin; ordinary replay remains compatible");return 0;}return h->audit_capacity_v1(h->runtime,maximum_worlds);}
