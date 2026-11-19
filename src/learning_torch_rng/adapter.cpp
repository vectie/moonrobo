// Optional plugin only. No Python headers or Python runtime are used.
#include <ATen/CPUGeneratorImpl.h>
#include <ATen/ops/randn.h>
#include <ATen/ops/randint.h>
#include <ATen/ops/empty.h>
#include <torch/version.h>
#include <cstdint>
#include <cstring>
#include <cstdio>
#include <exception>
#include <mutex>
#include <stdexcept>
#include <limits>
struct Rng {
 at::Generator generator;
 at::Tensor saved_state;
 std::mutex mutex;
 explicit Rng(uint64_t seed):generator(at::detail::createCPUGenerator(seed)){}
};
static void failure(char *error,int capacity,const char *message){if(error && capacity>0)std::snprintf(error,capacity,"%s",message);}
#define GUARDED(body) try {body;return 0;} catch(const std::exception &e){failure(error,capacity,e.what());return -1;} catch(...){failure(error,capacity,"unknown ATen RNG exception");return -1;}
extern "C" int moonrobo_aten_rng_api_version(){return 1;}
extern "C" const char *moonrobo_aten_rng_version(){return TORCH_VERSION;}
extern "C" void *moonrobo_aten_rng_create(uint64_t seed,char *error,int capacity){
 try{return new Rng(seed);}catch(const std::exception &e){failure(error,capacity,e.what());return nullptr;}catch(...){failure(error,capacity,"ATen generator construction failed");return nullptr;}
}
extern "C" void moonrobo_aten_rng_destroy(void *handle){try{delete static_cast<Rng *>(handle);}catch(...){/* no exception crosses C finalizer */}}
extern "C" int moonrobo_aten_rng_normal(void *handle,int64_t count,double *output,char *error,int capacity){
 GUARDED(
  if(count<0 || (count && !output))throw std::invalid_argument("invalid normal buffer");
  auto &rng=*static_cast<Rng *>(handle);std::lock_guard<std::mutex> lock(rng.mutex);
  auto sample=at::randn({count},rng.generator,at::TensorOptions().dtype(at::kFloat).device(at::kCPU)).contiguous();
  const float *data=sample.const_data_ptr<float>();for(int64_t i=0;i<count;i++)output[i]=static_cast<double>(data[i]);
 )
}
extern "C" int moonrobo_aten_rng_indices(void *handle,int64_t high,int64_t count,int64_t *output,char *error,int capacity){
 GUARDED(
  if(high<=0 || count<0 || (count && !output))throw std::invalid_argument("invalid randint arguments");
  auto &rng=*static_cast<Rng *>(handle);std::lock_guard<std::mutex> lock(rng.mutex);
  auto sample=at::randint(high,{count},rng.generator,at::TensorOptions().dtype(at::kLong).device(at::kCPU)).contiguous();
  if(count)std::memcpy(output,sample.const_data_ptr<int64_t>(),static_cast<size_t>(count)*sizeof(int64_t));
 )
}
extern "C" int64_t moonrobo_aten_rng_state_size(void *handle,char *error,int capacity){
 try{auto &rng=*static_cast<Rng *>(handle);std::lock_guard<std::mutex> lock(rng.mutex);rng.saved_state=rng.generator.get_state().contiguous();return rng.saved_state.numel();}
 catch(const std::exception &e){failure(error,capacity,e.what());return -1;}catch(...){failure(error,capacity,"ATen get_state failed");return -1;}
}
extern "C" int moonrobo_aten_rng_state_copy(void *handle,uint8_t *output,int64_t size,char *error,int capacity){
 GUARDED(
  auto &rng=*static_cast<Rng *>(handle);std::lock_guard<std::mutex> lock(rng.mutex);
  if(!rng.saved_state.defined() || size!=rng.saved_state.numel() || (size && !output))throw std::invalid_argument("state size differs");
  if(size)std::memcpy(output,rng.saved_state.const_data_ptr<uint8_t>(),static_cast<size_t>(size));
 )
}
extern "C" int moonrobo_aten_rng_restore(void *handle,const uint8_t *input,int64_t size,char *error,int capacity){
 GUARDED(
  if(size<=0 || !input)throw std::invalid_argument("empty generator state");
  auto &rng=*static_cast<Rng *>(handle);std::lock_guard<std::mutex> lock(rng.mutex);
  auto state=at::empty({size},at::TensorOptions().dtype(at::kByte).device(at::kCPU));
  std::memcpy(state.mutable_data_ptr<uint8_t>(),input,static_cast<size_t>(size));rng.generator.set_state(state);
 )
}
