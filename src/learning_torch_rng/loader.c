#include <moonbit.h>
#include <stdint.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <limits.h>
#include <dlfcn.h>
typedef struct {
 void *library,*handle;
 char error[2048];
 double *normal;int64_t *indices;
 int32_t normal_count,index_count;
 int (*api_version)(void);const char *(*version)(void);
 void *(*create)(uint64_t,char *,int);void (*destroy)(void *);
 int (*draw_normal)(void *,int64_t,double *,char *,int);
 int (*draw_indices)(void *,int64_t,int64_t,int64_t *,char *,int);
 int64_t (*state_size)(void *,char *,int);
 int (*state_copy)(void *,uint8_t *,int64_t,char *,int);
 int (*restore)(void *,const uint8_t *,int64_t,char *,int);
} Rng;
static moonbit_bytes_t bytes(const char *s){size_t n=strlen(s);moonbit_bytes_t b=moonbit_make_bytes((int32_t)n,0);memcpy(b,s,n);return b;}
static void cleanup(void *p){
 Rng *r=p;if(r->handle && r->destroy)r->destroy(r->handle);free(r->normal);free(r->indices);
 /* LibTorch owns global pools and background threads: retain the plugin module
  * for process lifetime, even after the final Generator is collected. */
}
MOONBIT_FFI_EXPORT Rng *moonrobo_torch_rng_open(const unsigned char *adapter,int64_t seed){
 Rng *r=moonbit_make_external_object(cleanup,sizeof(Rng));memset(r,0,sizeof(*r));
 r->library=dlopen((const char *)adapter,RTLD_NOW|RTLD_LOCAL);
 if(!r->library){snprintf(r->error,sizeof(r->error),"%s",dlerror());return r;}
#define LOAD(field,symbol) do{*(void **)(&r->field)=dlsym(r->library,symbol);if(!r->field){snprintf(r->error,sizeof(r->error),"missing ATen RNG symbol: %s",symbol);return r;}}while(0)
 LOAD(api_version,"moonrobo_aten_rng_api_version");LOAD(version,"moonrobo_aten_rng_version");LOAD(create,"moonrobo_aten_rng_create");LOAD(destroy,"moonrobo_aten_rng_destroy");LOAD(draw_normal,"moonrobo_aten_rng_normal");LOAD(draw_indices,"moonrobo_aten_rng_indices");LOAD(state_size,"moonrobo_aten_rng_state_size");LOAD(state_copy,"moonrobo_aten_rng_state_copy");LOAD(restore,"moonrobo_aten_rng_restore");
#undef LOAD
 if(r->api_version()!=1){strcpy(r->error,"unsupported ATen RNG adapter ABI version");return r;}
 r->handle=r->create((uint64_t)seed,r->error,sizeof(r->error));
 if(!r->handle && !r->error[0])strcpy(r->error,"ATen generator construction failed");return r;
}
MOONBIT_FFI_EXPORT moonbit_bytes_t moonrobo_torch_rng_error(Rng *r){return bytes(r->error);}
MOONBIT_FFI_EXPORT int32_t moonrobo_torch_rng_normal(Rng *r,int32_t count){
 r->error[0]=0;if(count<0){strcpy(r->error,"negative normal count");return -1;}
 double *values=count?malloc((size_t)count*sizeof(double)):NULL;
 if(count && !values){strcpy(r->error,"normal buffer allocation failed");return -1;}
 if(r->draw_normal(r->handle,count,values,r->error,sizeof(r->error))){free(values);if(!r->error[0])strcpy(r->error,"ATen normal failed");return -1;}
 free(r->normal);r->normal=values;r->normal_count=count;return 0;
}
MOONBIT_FFI_EXPORT int32_t moonrobo_torch_rng_indices(Rng *r,int32_t high,int32_t count){
 r->error[0]=0;if(high<=0||count<0){strcpy(r->error,"invalid randint arguments");return -1;}
 int64_t *values=count?malloc((size_t)count*sizeof(int64_t)):NULL;
 if(count && !values){strcpy(r->error,"index buffer allocation failed");return -1;}
 if(r->draw_indices(r->handle,high,count,values,r->error,sizeof(r->error))){free(values);if(!r->error[0])strcpy(r->error,"ATen randint failed");return -1;}
 for(int32_t i=0;i<count;i++)if(values[i]<0||values[i]>=high){free(values);strcpy(r->error,"ATen index outside requested bounds");return -1;}
 free(r->indices);r->indices=values;r->index_count=count;return 0;
}
MOONBIT_FFI_EXPORT double moonrobo_torch_rng_normal_value(Rng *r,int32_t index){return r->normal[index];}
MOONBIT_FFI_EXPORT int32_t moonrobo_torch_rng_index_value(Rng *r,int32_t index){return (int32_t)r->indices[index];}
MOONBIT_FFI_EXPORT moonbit_bytes_t moonrobo_torch_rng_state(Rng *r){
 r->error[0]=0;int64_t size=r->state_size(r->handle,r->error,sizeof(r->error));
 if(size<0||size>INT32_MAX){if(!r->error[0])strcpy(r->error,"ATen generator state size is invalid");return moonbit_make_bytes(0,0);}
 moonbit_bytes_t result=moonbit_make_bytes((int32_t)size,0);
 if(r->state_copy(r->handle,result,size,r->error,sizeof(r->error)) && !r->error[0])strcpy(r->error,"ATen state copy failed");
 return result;
}
MOONBIT_FFI_EXPORT int32_t moonrobo_torch_rng_restore(Rng *r,moonbit_bytes_t state){
 r->error[0]=0;int status=r->restore(r->handle,state,Moonbit_array_length(state),r->error,sizeof(r->error));
 if(status && !r->error[0])strcpy(r->error,"ATen state restore failed");return status;
}
MOONBIT_FFI_EXPORT moonbit_bytes_t moonrobo_torch_rng_version(Rng *r){return bytes(r->version());}
