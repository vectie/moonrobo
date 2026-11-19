/* The external object owns the plan. Autograd also retains its own reference. */
typedef struct {void* value;void* library_id;void (*destroy)(void*);} NativeCompiledBlock;
typedef void* (*mr_compiled_load_fn)(const char*,int,char*,int);
typedef void* (*mr_compiled_run_fn)(void*,void**,int,char*,int);
static void cleanup_compiled_block(void* p) {
  NativeCompiledBlock* v=p;if(v->value && v->destroy)v->destroy(v->value);
}
MOONBIT_FFI_EXPORT int32_t mr_compiled_block_supported_call(Backend* b) {
  return b && b->library && dlsym(b->library,"mr_compiled_block_load_v1") &&
    dlsym(b->library,"mr_compiled_block_run_v1") && dlsym(b->library,"mr_compiled_block_destroy_v1");
}
MOONBIT_FFI_EXPORT NativeCompiledBlock* mr_compiled_block_load_call(Backend* b,moonbit_bytes_t path,int device) {
  NativeCompiledBlock* p=moonbit_make_external_object(cleanup_compiled_block,sizeof(*p));
  memset(p,0,sizeof(*p));b->error[0]=0;p->library_id=b->library;
  if(!mr_compiled_block_supported_call(b)){strcpy(b->error,"plugin lacks compiled block extension");return p;}
  int n=Moonbit_array_length(path);char* s=malloc((size_t)n+1);
  if(!s){strcpy(b->error,"compiled block path allocation");return p;}
  memcpy(s,path,n);s[n]=0;
  if(strlen(s)!=(size_t)n){free(s);strcpy(b->error,"compiled block path contains NUL");return p;}
  mr_compiled_load_fn load;*(void**)(&load)=dlsym(b->library,"mr_compiled_block_load_v1");
  *(void**)(&p->destroy)=dlsym(b->library,"mr_compiled_block_destroy_v1");
  p->value=load(s,device,b->error,sizeof(b->error));free(s);return p;
}
MOONBIT_FFI_EXPORT NativeTensor* mr_compiled_block_run_call(Backend* b,NativeCompiledBlock* p,NativeTensor** xs) {
  b->error[0]=0;
  if(!p || !p->value || p->library_id!=b->library){strcpy(b->error,"compiled block belongs to another/closed backend");return wrap(b,NULL);}
  int n=Moonbit_array_length(xs);void** values=handles(b,xs,n);
  if(!values)return wrap(b,NULL);
  mr_compiled_run_fn run;*(void**)(&run)=dlsym(b->library,"mr_compiled_block_run_v1");
  void* y=run(p->value,values,n,b->error,sizeof(b->error));free(values);return wrap(b,y);
}
MOONBIT_FFI_EXPORT NativeCompiledBlock* mr_compiled_block_many_call(Backend* b,NativeCompiledBlock* p,NativeTensor** xs) {
  NativeCompiledBlock* result=moonbit_make_external_object(cleanup_compiled_block,sizeof(*result));memset(result,0,sizeof(*result));result->library_id=b->library;b->error[0]=0;
  mr_compiled_run_fn run;*(void**)(&run)=dlsym(b->library,"mr_compiled_block_run_many_v1");
  *(void**)(&result->destroy)=dlsym(b->library,"mr_compiled_outputs_destroy_v1");
  if(!run||!result->destroy){strcpy(b->error,"plugin lacks multi-output compiled extension");return result;}
  if(!p||!p->value||p->library_id!=b->library){strcpy(b->error,"compiled block backend mismatch");return result;}
  int n=Moonbit_array_length(xs);void** values=handles(b,xs,n);if(!values)return result;
  result->value=run(p->value,values,n,b->error,sizeof(b->error));free(values);return result;
}
MOONBIT_FFI_EXPORT int32_t mr_compiled_outputs_count_call(Backend* b,NativeCompiledBlock* p) {
  b->error[0]=0;int (*count)(void*);*(void**)(&count)=dlsym(b->library,"mr_compiled_outputs_count_v1");
  if(!count||!p||!p->value||p->library_id!=b->library){strcpy(b->error,"compiled outputs backend mismatch");return 0;}return count(p->value);
}
MOONBIT_FFI_EXPORT NativeTensor* mr_compiled_outputs_get_call(Backend* b,NativeCompiledBlock* p,int i) {
  b->error[0]=0;void* (*get)(void*,int,char*,int);*(void**)(&get)=dlsym(b->library,"mr_compiled_outputs_get_v1");
  if(!get||!p||!p->value||p->library_id!=b->library){strcpy(b->error,"compiled outputs backend mismatch");return wrap(b,NULL);}return wrap(b,get(p->value,i,b->error,sizeof(b->error)));
}
