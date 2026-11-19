MOONBIT_FFI_EXPORT int32_t mr_tensor_has_split_sections(Backend *b) {
  return dlsym(b->library,"mr_tensor_split_sections_v1")!=NULL;
}
MOONBIT_FFI_EXPORT NativeTensor **mr_tensor_split_sections_call(Backend *b,NativeTensor *a,int32_t *sizes,int32_t axis) {
  b->error[0]=0;int n=Moonbit_array_length(sizes);
  int (*op)(void*,const int64_t*,int,int,void**,char*,int)=NULL;
  *(void**)(&op)=dlsym(b->library,"mr_tensor_split_sections_v1");
  if(!op||!a||!a->value||a->library_id!=b->library||n<1||n>64){strcpy(b->error,"split extension/backend/count mismatch");return (NativeTensor**)moonbit_make_ref_array(0,NULL);}
  int64_t wide[64];void *values[64];
  for(int i=0;i<n;++i)wide[i]=sizes[i];
  if(op(a->value,wide,n,axis,values,b->error,sizeof(b->error)))return (NativeTensor**)moonbit_make_ref_array(0,NULL);
  NativeTensor **out=(NativeTensor**)moonbit_make_ref_array(n,NULL);
  for(int i=0;i<n;++i)out[i]=wrap(b,values[i]);
  return out;
}
