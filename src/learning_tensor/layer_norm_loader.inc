/* Optional ABI-2 operation. Include after Backend and wrap are defined.
 * Resolve against this Backend rather than a process-global plugin pointer;
 * old ABI-2 plugins continue opening and using the expanded network path. */
typedef void *(*mr_layer_norm_fn)(void *, void *, void *, double, char *, int);
MOONBIT_FFI_EXPORT int32_t mr_tensor_has_ln_silu_tail(Backend *b) {
  return b && b->library && dlsym(b->library, "mr_tensor_ln_silu_tail_v1") != NULL;
}
MOONBIT_FFI_EXPORT NativeTensor *mr_tensor_ln_silu_tail_call(Backend *b,
    NativeTensor *c, NativeTensor *v, NativeTensor *w, NativeTensor *bias, double eps) {
  b->error[0] = 0;
  void *(*op)(void*, void*, void*, void*, double, char*, int) = NULL;
  *(void**)(&op) = dlsym(b->library, "mr_tensor_ln_silu_tail_v1");
  if (!op) { strcpy(b->error, "plugin lacks fused LN SiLU tail"); return wrap(b, NULL); }
  if (!c || !v || !w || !bias || !c->value || !v->value || !w->value || !bias->value ||
      c->library_id != b->library || v->library_id != b->library ||
      w->library_id != b->library || bias->library_id != b->library) {
    strcpy(b->error, "fused LN tail backend mismatch"); return wrap(b, NULL);
  }
  return wrap(b, op(c->value, v->value, w->value, bias->value, eps, b->error, sizeof(b->error)));
}
static mr_layer_norm_fn mr_layer_norm_symbol(Backend *b) {
  if (!b || !b->library) return NULL;
  mr_layer_norm_fn result = NULL;
  *(void **)(&result) = dlsym(b->library, "mr_tensor_layer_norm_v1");
  return result;
}

MOONBIT_FFI_EXPORT int32_t mr_tensor_has_layer_norm_submitted(Backend *b) {
  return b && b->library && dlsym(b->library,"mr_tensor_layer_norm_submitted_v1") != NULL;
}

MOONBIT_FFI_EXPORT NativeTensor *mr_tensor_cross_submitted_call(Backend *b, NativeTensor *a, NativeTensor *c) {
  b->error[0]=0;
  void *(*op)(void *,void *,char *,int)=NULL;
  *(void **)(&op)=dlsym(b->library,"mr_tensor_cross_submitted_v1");
  if(!op){strcpy(b->error,"plugin lacks submitted cross extension");return wrap(b,NULL);}
  if(!a||!c||!a->value||!c->value||a->library_id!=b->library||c->library_id!=b->library){strcpy(b->error,"submitted cross backend mismatch");return wrap(b,NULL);}
  return wrap(b,op(a->value,c->value,b->error,sizeof(b->error)));
}
MOONBIT_FFI_EXPORT NativeTensor *mr_tensor_layer_norm_submitted_call(
    Backend *b, NativeTensor *input, NativeTensor *weight, NativeTensor *bias, double eps) {
  b->error[0]=0;
  mr_layer_norm_fn op=NULL;
  *(void **)(&op)=dlsym(b->library,"mr_tensor_layer_norm_submitted_v1");
  if(!op){strcpy(b->error,"plugin lacks optional submitted LayerNorm extension");return wrap(b,NULL);}
  if(!input||!weight||!bias||!input->value||!weight->value||!bias->value||
      input->library_id!=b->library||weight->library_id!=b->library||bias->library_id!=b->library){
    strcpy(b->error,"submitted LayerNorm backend mismatch");return wrap(b,NULL);
  }
  void *value=op(input->value,weight->value,bias->value,eps,b->error,sizeof(b->error));
  if(!value&&!b->error[0])strcpy(b->error,"submitted LayerNorm failed");
  return wrap(b,value);
}
MOONBIT_FFI_EXPORT int32_t mr_tensor_has_layer_norm(Backend *b) {
  return mr_layer_norm_symbol(b) != NULL;
}
MOONBIT_FFI_EXPORT NativeTensor *mr_tensor_layer_norm_call(
    Backend *b, NativeTensor *input, NativeTensor *weight, NativeTensor *bias,
    double eps) {
  b->error[0] = 0;
  mr_layer_norm_fn op = mr_layer_norm_symbol(b);
  if (!op) {
    strcpy(b->error, "plugin lacks optional native LayerNorm extension; rebuild plugin");
    return wrap(b, NULL);
  }
  if (!input || !weight || !bias || !input->value || !weight->value || !bias->value ||
      input->library_id != b->library || weight->library_id != b->library ||
      bias->library_id != b->library) {
    strcpy(b->error, "LayerNorm tensor backend mismatch or empty tensor");
    return wrap(b, NULL);
  }
  void *value = op(input->value, weight->value, bias->value, eps, b->error, sizeof(b->error));
  if (!value && !b->error[0]) strcpy(b->error, "LibTorch LayerNorm failed");
  return wrap(b, value);
}
