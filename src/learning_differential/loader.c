#include <moonbit.h>
#include <dlfcn.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
typedef struct {
 void *library,*handle;char error[4096];char *name,*dtype;int64_t *shape;double *values;int rank,count;
 int(*abi)(void);const char*(*version)(void);void*(*create)(void);void(*destroy)(void*);void(*clear)(void*);
 int(*put)(void*,const char*,const char*,const int64_t*,int,const double*,int64_t);
 int(*run)(void*,const char*);const char*(*failure)(void*);int(*count_outputs)(void*);
 const char*(*output_name)(void*,int);const char*(*output_dtype)(void*,int);
 int(*rank_of)(void*,int);int64_t(*dim_of)(void*,int,int);int64_t(*size_of)(void*,int);double(*value_of)(void*,int,int64_t);
} Oracle;
static moonbit_bytes_t result_bytes(const char *s){size_t n=strlen(s);moonbit_bytes_t b=moonbit_make_bytes((int)n,0);memcpy(b,s,n);return b;}
static void cleanup(void *p){Oracle *o=p;if(o->handle&&o->destroy)o->destroy(o->handle);free(o->name);free(o->dtype);free(o->shape);free(o->values);/* LibTorch plugins remain loaded for global pools. */}
MOONBIT_FFI_EXPORT Oracle *moonrobo_diff_open(const unsigned char *library){
 Oracle*o=moonbit_make_external_object(cleanup,sizeof(Oracle));memset(o,0,sizeof(*o));
 o->library=dlopen((const char*)library,RTLD_NOW|RTLD_LOCAL);if(!o->library){snprintf(o->error,sizeof(o->error),"%s",dlerror());return o;}
#define LOAD(field,symbol) do{*(void**)(&o->field)=dlsym(o->library,symbol);if(!o->field){snprintf(o->error,sizeof(o->error),"missing oracle ABI symbol: %s",symbol);return o;}}while(0)
 LOAD(abi,"moonrobo_diff_api_version");LOAD(version,"moonrobo_diff_torch_version");LOAD(create,"moonrobo_diff_create");LOAD(destroy,"moonrobo_diff_destroy");LOAD(clear,"moonrobo_diff_clear");LOAD(put,"moonrobo_diff_put");LOAD(run,"moonrobo_diff_evaluate");LOAD(failure,"moonrobo_diff_failure");LOAD(count_outputs,"moonrobo_diff_output_count");LOAD(output_name,"moonrobo_diff_output_name");LOAD(output_dtype,"moonrobo_diff_output_dtype");LOAD(rank_of,"moonrobo_diff_output_rank");LOAD(dim_of,"moonrobo_diff_output_dim");LOAD(size_of,"moonrobo_diff_output_size");LOAD(value_of,"moonrobo_diff_output_value");
#undef LOAD
 if(o->abi()!=1){strcpy(o->error,"unsupported differential oracle ABI");return o;}
 o->handle=o->create();if(!o->handle)strcpy(o->error,"oracle construction failed");return o;
}
MOONBIT_FFI_EXPORT moonbit_bytes_t moonrobo_diff_error(Oracle*o){return result_bytes(o->error);}
MOONBIT_FFI_EXPORT moonbit_bytes_t moonrobo_diff_version(Oracle*o){return result_bytes(o->version());}
MOONBIT_FFI_EXPORT void moonrobo_diff_clear_input(Oracle*o){o->clear(o->handle);o->error[0]=0;}
MOONBIT_FFI_EXPORT int moonrobo_diff_begin(Oracle*o,const unsigned char*name,const unsigned char*dtype,int rank,int count){
 if(rank<0||rank>16||count<0){strcpy(o->error,"invalid bounded tensor shape");return -1;}
 free(o->name);free(o->dtype);free(o->shape);free(o->values);o->name=strdup((const char*)name);o->dtype=strdup((const char*)dtype);o->shape=calloc((size_t)(rank?rank:1),sizeof(int64_t));o->values=calloc((size_t)(count?count:1),sizeof(double));o->rank=rank;o->count=count;
 if(!o->name||!o->dtype||!o->shape||!o->values){strcpy(o->error,"oracle input allocation failed");return -1;}return 0;
}
MOONBIT_FFI_EXPORT void moonrobo_diff_shape(Oracle*o,int index,int value){if(index>=0&&index<o->rank)o->shape[index]=value;}
MOONBIT_FFI_EXPORT void moonrobo_diff_value(Oracle*o,int index,double value){if(index>=0&&index<o->count)o->values[index]=value;}
static int check(Oracle*o,int status){if(status)snprintf(o->error,sizeof(o->error),"%s",o->failure(o->handle));return status;}
MOONBIT_FFI_EXPORT int moonrobo_diff_commit(Oracle*o){return check(o,o->put(o->handle,o->name,o->dtype,o->shape,o->rank,o->values,o->count));}
MOONBIT_FFI_EXPORT int moonrobo_diff_run(Oracle*o,const unsigned char*operation){return check(o,o->run(o->handle,(const char*)operation));}
MOONBIT_FFI_EXPORT int moonrobo_diff_count(Oracle*o){return o->count_outputs(o->handle);}
MOONBIT_FFI_EXPORT moonbit_bytes_t moonrobo_diff_name(Oracle*o,int i){return result_bytes(o->output_name(o->handle,i));}
MOONBIT_FFI_EXPORT moonbit_bytes_t moonrobo_diff_dtype(Oracle*o,int i){return result_bytes(o->output_dtype(o->handle,i));}
MOONBIT_FFI_EXPORT int moonrobo_diff_rank(Oracle*o,int i){return o->rank_of(o->handle,i);}
MOONBIT_FFI_EXPORT int moonrobo_diff_dim(Oracle*o,int i,int j){return (int)o->dim_of(o->handle,i,j);}
MOONBIT_FFI_EXPORT int moonrobo_diff_size(Oracle*o,int i){return (int)o->size_of(o->handle,i);}
MOONBIT_FFI_EXPORT double moonrobo_diff_get(Oracle*o,int i,int j){return o->value_of(o->handle,i,j);}
