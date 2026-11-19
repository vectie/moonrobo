MOONBIT_FFI_EXPORT int32_t mr_tensor_has_geometry_vjp(Backend *b) {
  return dlsym(b->library,"mr_tensor_fused_cross_vjp_v1")&&dlsym(b->library,"mr_tensor_so3_coefficients_v1");
}
MOONBIT_FFI_EXPORT NativeTensor *mr_tensor_fused_cross_vjp_call(Backend *b,NativeTensor *a,NativeTensor *c) {
  b->error[0]=0;void *(*op)(void*,void*,char*,int)=NULL;
  *(void**)(&op)=dlsym(b->library,"mr_tensor_fused_cross_vjp_v1");
  if(!op||!a||!c||!a->value||!c->value||a->library_id!=b->library||c->library_id!=b->library){strcpy(b->error,"cross VJP unavailable or backend mismatch");return wrap(b,NULL);}
  return wrap(b,op(a->value,c->value,b->error,sizeof(b->error)));
}
MOONBIT_FFI_EXPORT NativeTensor *mr_tensor_so3_coefficients_call(Backend *b,NativeTensor *x) {
  b->error[0]=0;void *(*op)(void*,char*,int)=NULL;
  *(void**)(&op)=dlsym(b->library,"mr_tensor_so3_coefficients_v1");
  if(!op||!x||!x->value||x->library_id!=b->library){strcpy(b->error,"SO3 coefficients unavailable or backend mismatch");return wrap(b,NULL);}
  return wrap(b,op(x->value,b->error,sizeof(b->error)));
}

MOONBIT_FFI_EXPORT int32_t mr_tensor_has_coefficient_forward(Backend *b) { return dlsym(b->library,"mr_tensor_so3_coefficient_forward_v1")!=NULL; }
MOONBIT_FFI_EXPORT NativeTensor *mr_tensor_so3_coefficient_forward_call(Backend *b,NativeTensor *x) {
  b->error[0]=0;void *(*op)(void*,char*,int)=NULL;
  *(void**)(&op)=dlsym(b->library,"mr_tensor_so3_coefficient_forward_v1");
  if(!op||!x||!x->value||x->library_id!=b->library){strcpy(b->error,"SO3 coefficients unavailable or backend mismatch");return wrap(b,NULL);}
  return wrap(b,op(x->value,b->error,sizeof(b->error)));
}

MOONBIT_FFI_EXPORT int32_t mr_tensor_has_coefficient_full_forward(Backend *b) { return dlsym(b->library,"mr_tensor_so3_coefficient_full_forward_v1")!=NULL; }
MOONBIT_FFI_EXPORT NativeTensor *mr_tensor_so3_coefficient_full_forward_call(Backend *b,NativeTensor *x) {
  b->error[0]=0;void *(*op)(void*,char*,int)=NULL;
  *(void**)(&op)=dlsym(b->library,"mr_tensor_so3_coefficient_full_forward_v1");
  if(!op||!x||!x->value||x->library_id!=b->library){strcpy(b->error,"SO3 coefficients unavailable or backend mismatch");return wrap(b,NULL);}
  return wrap(b,op(x->value,b->error,sizeof(b->error)));
}
