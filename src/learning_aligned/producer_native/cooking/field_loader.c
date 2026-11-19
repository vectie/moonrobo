#include <moonbit.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#if !defined(_WIN32)
#include <dlfcn.h>
#endif
typedef struct {void* library;void* field;void* context_owner;const char*(*error)(void*);uint64_t(*host)(void*);uint64_t(*device)(void*);uint64_t(*array)(void*);void(*upload)(void*,uint64_t,uint64_t);const uint8_t*(*snapshot)(void*,size_t*);void(*close)(void*);char failure[1024];} FieldHandle;
static void finish(FieldHandle* h){if(h->field&&h->close)h->close(h->field);h->field=NULL;
#if !defined(_WIN32)
if(h->library)dlclose(h->library);
#endif
h->library=NULL;if(h->context_owner){void* p=h->context_owner;h->context_owner=NULL;moonbit_decref(p);}}
static void finalized(void* p){finish((FieldHandle*)p);}
static void setup(FieldHandle* h,moonbit_bytes_t adapter){
#if defined(_WIN32)
snprintf(h->failure,sizeof(h->failure),"native cooked fields currently require POSIX adapter");
#else
 if(!Moonbit_array_length(adapter)||memchr(adapter,0,Moonbit_array_length(adapter))){snprintf(h->failure,sizeof(h->failure),"explicit NUL-free field adapter path required");return;}
 h->library=dlopen((const char*)adapter,RTLD_NOW|RTLD_LOCAL);if(!h->library){snprintf(h->failure,sizeof(h->failure),"cannot load explicit field adapter");return;}
 int(*abi)(void)=(int(*)(void))dlsym(h->library,"mr_cooked_field_abi");
 h->error=(const char*(*)(void*))dlsym(h->library,"mr_cooked_field_error");h->host=(uint64_t(*)(void*))dlsym(h->library,"mr_cooked_field_host_id");h->device=(uint64_t(*)(void*))dlsym(h->library,"mr_cooked_field_device_id");h->array=(uint64_t(*)(void*))dlsym(h->library,"mr_cooked_field_array_id");
 h->upload=(void(*)(void*,uint64_t,uint64_t))dlsym(h->library,"mr_cooked_field_make_device");h->snapshot=(const uint8_t*(*)(void*,size_t*))dlsym(h->library,"mr_cooked_field_snapshot");h->close=(void(*)(void*))dlsym(h->library,"mr_cooked_field_close");
 if(!abi||!h->error||!h->host||!h->device||!h->array||!h->upload||!h->snapshot||!h->close||abi()!=1)snprintf(h->failure,sizeof(h->failure),"incompatible cooked field adapter ABI");
#endif
}
MOONBIT_FFI_EXPORT FieldHandle* moonrobo_field_open(moonbit_bytes_t adapter,moonbit_bytes_t library,int kind,moonbit_bytes_t data,int nx,int ny,int nz,int channels,int dtype,moonbit_bytes_t placement,float background){
 FieldHandle* h=(FieldHandle*)moonbit_make_external_object(finalized,sizeof(FieldHandle));memset(h,0,sizeof(*h));
#if defined(_WIN32)
snprintf(h->failure,sizeof(h->failure),"native cooked fields currently require POSIX adapter");
#else
 if(!Moonbit_array_length(adapter)||!Moonbit_array_length(library)||memchr(adapter,0,Moonbit_array_length(adapter))||memchr(library,0,Moonbit_array_length(library))){snprintf(h->failure,sizeof(h->failure),"explicit NUL-free field library paths required");return h;}
 setup(h,adapter);if(h->failure[0])return h;
 void*(*open)(const char*,int,const uint8_t*,size_t,int,int,int,int,int,const uint8_t*,size_t,float)=(void*(*)(const char*,int,const uint8_t*,size_t,int,int,int,int,int,const uint8_t*,size_t,float))dlsym(h->library,"mr_cooked_field_open");
 if(!open){snprintf(h->failure,sizeof(h->failure),"missing native field open symbol");return h;}
 h->field=open((const char*)library,kind,data,(size_t)Moonbit_array_length(data),nx,ny,nz,channels,dtype,placement,(size_t)Moonbit_array_length(placement),background);
 if(!h->field)snprintf(h->failure,sizeof(h->failure),"native field owner allocation failed");
#endif
 return h;
}
MOONBIT_FFI_EXPORT moonbit_bytes_t moonrobo_field_error(FieldHandle* h){const char* p=h->failure[0]?h->failure:h->field&&h->error?h->error(h->field):"field is closed";size_t n=strlen(p);moonbit_bytes_t out=moonbit_make_bytes((int32_t)n,0);if(n)memcpy(out,p,n);return out;}
MOONBIT_FFI_EXPORT uint64_t moonrobo_field_id(FieldHandle* h,int kind){return h->field&&!h->failure[0]?(kind==0?h->host(h->field):kind==1?h->device(h->field):h->array(h->field)):0;}
MOONBIT_FFI_EXPORT void moonrobo_field_owner(FieldHandle* h,void* token){if(h->context_owner||!h->field){moonbit_decref(token);snprintf(h->failure,sizeof(h->failure),"field context owner already set or field is closed");return;}h->context_owner=token;}
MOONBIT_FFI_EXPORT void moonrobo_field_upload(FieldHandle* h,uint64_t context,uint64_t stream){if(h->field&&!h->failure[0])h->upload(h->field,context,stream);}
MOONBIT_FFI_EXPORT moonbit_bytes_t moonrobo_field_snapshot(FieldHandle* h){size_t n=0;const uint8_t* p=h->field&&h->snapshot?h->snapshot(h->field,&n):NULL;if(n>INT32_MAX)n=0;moonbit_bytes_t out=moonbit_make_bytes((int32_t)n,0);if(n)memcpy(out,p,n);return out;}
MOONBIT_FFI_EXPORT void moonrobo_field_close(FieldHandle* h){finish(h);}
MOONBIT_FFI_EXPORT FieldHandle* moonrobo_volume_tiles(moonbit_bytes_t adapter,moonbit_bytes_t library,moonbit_bytes_t tiles,moonbit_bytes_t values,moonbit_bytes_t placement,float background){
 FieldHandle* h=(FieldHandle*)moonbit_make_external_object(finalized,sizeof(FieldHandle));memset(h,0,sizeof(*h));setup(h,adapter);
#if !defined(_WIN32)
 if(h->failure[0])return h;
 if(!Moonbit_array_length(library)||memchr(library,0,Moonbit_array_length(library))){snprintf(h->failure,sizeof(h->failure),"explicit NUL-free Warp volume path required");return h;}
 void*(*open)(const char*,const uint8_t*,size_t,const uint8_t*,size_t,const uint8_t*,size_t,float)=(void*(*)(const char*,const uint8_t*,size_t,const uint8_t*,size_t,const uint8_t*,size_t,float))dlsym(h->library,"mr_cooked_volume_open_tiles");
 if(!open){snprintf(h->failure,sizeof(h->failure),"adapter does not provide native sparse tile cooking");return h;}
 h->field=open((const char*)library,tiles,(size_t)Moonbit_array_length(tiles),values,(size_t)Moonbit_array_length(values),placement,(size_t)Moonbit_array_length(placement),background);
 if(!h->field)snprintf(h->failure,sizeof(h->failure),"native sparse volume allocation failed");
#endif
 return h;
}
MOONBIT_FFI_EXPORT moonbit_bytes_t moonrobo_volume_sample(FieldHandle* h,moonbit_bytes_t xyz){
 int32_t size=Moonbit_array_length(xyz);moonbit_bytes_t out=moonbit_make_bytes(size/3,0);
#if !defined(_WIN32)
 if(h->field&&!h->failure[0]){
  void(*sample)(void*,const uint8_t*,size_t,uint8_t*,size_t)=(void(*)(void*,const uint8_t*,size_t,uint8_t*,size_t))dlsym(h->library,"mr_cooked_volume_sample");
  if(!sample){snprintf(h->failure,sizeof(h->failure),"adapter does not provide native volume query");return out;}
  sample(h->field,xyz,(size_t)size,out,(size_t)(size/3));
 }
#endif
 return out;
}
