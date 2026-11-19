MOONBIT_FFI_EXPORT int32_t mr_tensor_has_compact_heading(Backend *b) {
  return dlsym(b->library,"mr_tensor_compact_heading_v1")!=NULL;
}
MOONBIT_FFI_EXPORT NativeTensor *mr_tensor_compact_heading_call(Backend *b,NativeTensor *a) {
  b->error[0]=0; void *(*op)(void*,char*,int)=NULL;
  *(void**)(&op)=dlsym(b->library,"mr_tensor_compact_heading_v1");
  if(!op||!a||!a->value||a->library_id!=b->library){strcpy(b->error,"compact heading unavailable or backend mismatch");return wrap(b,NULL);}
  return wrap(b,op(a->value,b->error,sizeof(b->error)));
}
