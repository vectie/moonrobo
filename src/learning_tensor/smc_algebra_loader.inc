MOONBIT_FFI_EXPORT int32_t mr_tensor_has_smc_algebra(Backend *b) {
  return dlsym(b->library,"mr_tensor_smc_rotvec_v1") &&
    dlsym(b->library,"mr_tensor_smc_xi_v1") && dlsym(b->library,"mr_tensor_smc_return_v1");
}
MOONBIT_FFI_EXPORT NativeTensor *mr_tensor_smc_unary_call(Backend *b, NativeTensor *x, int32_t kind) {
  b->error[0]=0;
  void *(*op)(void*,char*,int)=NULL;
  if (kind!=0 && kind!=1) {strcpy(b->error,"invalid SMC unary operation");return wrap(b,NULL);}
  *(void**)(&op)=dlsym(b->library,kind==0?"mr_tensor_smc_rotvec_v1":"mr_tensor_smc_xi_v1");
  if (!op) {strcpy(b->error,"plugin lacks SMC algebra");return wrap(b,NULL);}
  if (!x || !x->value || x->library_id!=b->library) {strcpy(b->error,"SMC algebra backend mismatch");return wrap(b,NULL);}
  return wrap(b,op(x->value,b->error,sizeof(b->error)));
}
MOONBIT_FFI_EXPORT NativeTensor *mr_tensor_smc_return_call(Backend *b, NativeTensor *r, NativeTensor *d, NativeTensor *v, double gamma) {
  b->error[0]=0;
  void *(*op)(void*,void*,void*,double,char*,int)=NULL;
  *(void**)(&op)=dlsym(b->library,"mr_tensor_smc_return_v1");
  if (!op) {strcpy(b->error,"plugin lacks SMC return");return wrap(b,NULL);}
  if (!r || !d || !v || !r->value || !d->value || !v->value ||
      r->library_id!=b->library || d->library_id!=b->library || v->library_id!=b->library) {
    strcpy(b->error,"SMC return backend mismatch");return wrap(b,NULL);
  }
  return wrap(b,op(r->value,d->value,v->value,gamma,b->error,sizeof(b->error)));
}
