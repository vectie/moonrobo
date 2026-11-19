MOONBIT_FFI_EXPORT int32_t mr_tensor_has_compact_rotation(Backend *b) {
  return dlsym(b->library,"mr_tensor_compact_axis_v1")&&dlsym(b->library,"mr_tensor_compact_skew_v1");
}
MOONBIT_FFI_EXPORT NativeTensor *mr_tensor_compact_axis_call(Backend *b,NativeTensor *a,int32_t axis,double sign) {
  b->error[0]=0;
  void *(*op)(void*,int,double,char*,int)=NULL;
  *(void**)(&op)=dlsym(b->library,"mr_tensor_compact_axis_v1");
  if(!op||!a||!a->value||a->library_id!=b->library){strcpy(b->error,"compact axis unavailable or backend mismatch");return wrap(b,NULL);}
  return wrap(b,op(a->value,axis,sign,b->error,sizeof(b->error)));
}
MOONBIT_FFI_EXPORT NativeTensor *mr_tensor_compact_skew_call(Backend *b,NativeTensor *a) {
  b->error[0]=0;
  void *(*op)(void*,char*,int)=NULL;
  *(void**)(&op)=dlsym(b->library,"mr_tensor_compact_skew_v1");
  if(!op||!a||!a->value||a->library_id!=b->library){strcpy(b->error,"compact skew unavailable or backend mismatch");return wrap(b,NULL);}
  return wrap(b,op(a->value,b->error,sizeof(b->error)));
}
