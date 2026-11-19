MOONBIT_FFI_EXPORT int32_t mr_tensor_has_geometry_tail(Backend *b) {
  return dlsym(b->library,"mr_tensor_so3_tail_v1")&&dlsym(b->library,"mr_tensor_fused_cross_forward_v1");
}
MOONBIT_FFI_EXPORT NativeTensor *mr_tensor_so3_tail_call(Backend *b,NativeTensor *k,NativeTensor *kk,NativeTensor *a,NativeTensor *c) {
  b->error[0]=0;void *(*op)(void*,void*,void*,void*,char*,int)=NULL;
  *(void**)(&op)=dlsym(b->library,"mr_tensor_so3_tail_v1");
  if(!op||!k||!kk||!a||!c||!k->value||!kk->value||!a->value||!c->value||k->library_id!=b->library||kk->library_id!=b->library||a->library_id!=b->library||c->library_id!=b->library){strcpy(b->error,"SO3 tail unavailable or backend mismatch");return wrap(b,NULL);}
  return wrap(b,op(k->value,kk->value,a->value,c->value,b->error,sizeof(b->error)));
}
MOONBIT_FFI_EXPORT NativeTensor *mr_tensor_fused_cross_forward_call(Backend *b,NativeTensor *a,NativeTensor *c) {
  b->error[0]=0;void *(*op)(void*,void*,char*,int)=NULL;
  *(void**)(&op)=dlsym(b->library,"mr_tensor_fused_cross_forward_v1");
  if(!op||!a||!c||!a->value||!c->value||a->library_id!=b->library||c->library_id!=b->library){strcpy(b->error,"fused cross unavailable or backend mismatch");return wrap(b,NULL);}
  return wrap(b,op(a->value,c->value,b->error,sizeof(b->error)));
}
