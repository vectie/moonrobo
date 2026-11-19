MOONBIT_FFI_EXPORT int32_t mr_tensor_has_native_cross(Backend *b) {
  return dlsym(b->library,"mr_tensor_native_cross_v1")!=NULL;
}
MOONBIT_FFI_EXPORT NativeTensor *mr_tensor_native_cross_call(Backend *b, NativeTensor *a, NativeTensor *c) {
  b->error[0]=0;
  void *(*op)(void*,void*,char*,int)=NULL;
  *(void**)(&op)=dlsym(b->library,"mr_tensor_native_cross_v1");
  if (!op) {strcpy(b->error,"plugin lacks native cross");return wrap(b,NULL);}
  if (!a||!c||!a->value||!c->value||a->library_id!=b->library||c->library_id!=b->library) {
    strcpy(b->error,"native cross backend mismatch");return wrap(b,NULL);
  }
  return wrap(b,op(a->value,c->value,b->error,sizeof(b->error)));
}
MOONBIT_FFI_EXPORT int32_t mr_tensor_has_cross_preserve_forward(Backend *b) {
  return dlsym(b->library,"mr_tensor_cross_preserve_forward_v1")!=NULL;
}
MOONBIT_FFI_EXPORT NativeTensor *mr_tensor_cross_preserve_forward_call(Backend *b, NativeTensor *a, NativeTensor *c) {
  b->error[0]=0;
  void *(*op)(void*,void*,char*,int)=NULL;
  *(void**)(&op)=dlsym(b->library,"mr_tensor_cross_preserve_forward_v1");
  if (!op) {strcpy(b->error,"plugin lacks forward-preserving cross VJP");return wrap(b,NULL);}
  if (!a||!c||!a->value||!c->value||a->library_id!=b->library||c->library_id!=b->library) {
    strcpy(b->error,"cross VJP backend mismatch");return wrap(b,NULL);
  }
  return wrap(b,op(a->value,c->value,b->error,sizeof(b->error)));
}
