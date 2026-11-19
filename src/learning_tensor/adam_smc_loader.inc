/* Optional extension; legacy optimizers and libraries remain supported. */
MOONBIT_FFI_EXPORT int32_t mr_adam_step_smc_call(
    Backend* b, NativeAdam* a, double max_norm, double max_value) {
  b->error[0]=0;
  mr_checked_norm_adam_fn operation=NULL;
  *(void**)(&operation)=dlsym(b->library,"mr_adam_step_smc_v1");
  if(!operation) {strcpy(b->error,"plugin lacks optional SMC foreach Adam");return -1;}
  if(!valid_adam(b,a))return -1;
  const int code=operation(a->value,max_norm,max_value,b->error,sizeof(b->error));
  if(code&&!b->error[0])strcpy(b->error,"SMC foreach Adam failed");
  return code;
}
