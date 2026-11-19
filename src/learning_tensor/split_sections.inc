// Return all views from ONE SplitWithSizesBackward node, like Tensor.split in
// SMC WorldModel.step. Independent narrow calls instead scatter and add one
// full-size gradient per section. The views themselves have identical values.
extern "C" int mr_tensor_split_sections_v1(void *input,const int64_t *sizes,int n,int axis,
                                           void **outputs,char *err,int cap) {
  if(n<1||n>64||sizes==nullptr||outputs==nullptr)
    return status([&]{throw std::invalid_argument("split sections output bounds");},err,cap);
  for(int i=0;i<n;++i) outputs[i]=nullptr;
  int result=status([&]{
    auto &x=unbox(input);
    if(n<1||n>64||x.dim()<1||x.dim()>8||axis<0||axis>=x.dim()||x.numel()>16777216)
      throw std::invalid_argument("split sections bounds");
    int64_t total=0;
    for(int i=0;i<n;++i){if(sizes[i]<1||sizes[i]>16777216)throw std::invalid_argument("positive bounded split size required");total+=sizes[i];}
    if(total!=x.size(axis))throw std::invalid_argument("split sizes must cover axis exactly");
    auto parts=x.split_with_sizes(at::IntArrayRef(sizes,n),axis);
    for(int i=0;i<n;++i) outputs[i]=new torch::Tensor(parts[i]);
  },err,cap);
  if(result){for(int i=0;i<n;++i){delete static_cast<torch::Tensor*>(outputs[i]);outputs[i]=nullptr;}}
  return result;
}
