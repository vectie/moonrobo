#include "field_api.h"
#include <warp.h>
#include <volume.h>
#include <texture.h>
#include <cmath>
#include <cstring>
#include <new>
#include <stdexcept>
#include <string>
#include <vector>
#include <dlfcn.h>
namespace {
struct Field {
 void* library=nullptr;std::string error;int kind=0;int shape[3]{};int channels=1;int dtype=2;
 uint64_t host=0,device=0,array=0;void* context=nullptr;void* stream=nullptr;void* device_buffer=nullptr;
 std::vector<uint8_t> data;
 decltype(&wp_texture_destroy_host) texture_destroy_host=nullptr;
 decltype(&wp_texture_destroy_device) texture_destroy_device=nullptr;
 decltype(&wp_texture_object_destroy_device) object_destroy=nullptr;
 decltype(&wp_volume_destroy_host) volume_destroy_host=nullptr;
 decltype(&wp_volume_destroy_device) volume_destroy_device=nullptr;
 decltype(&wp_cuda_context_synchronize) synchronize=nullptr;
 decltype(&wp_free_device_default) free_device=nullptr;
 decltype(&wp_volume_get_buffer_info) buffer_info=nullptr;
 ~Field(){
  if(context&&synchronize)synchronize(context);
  if(kind==0){if(device&&object_destroy)object_destroy(context,device);if(array&&texture_destroy_device)texture_destroy_device(context,array,false);if(host&&texture_destroy_host)texture_destroy_host(host);}
  else {if(device&&volume_destroy_device)volume_destroy_device(device);if(host&&volume_destroy_host)volume_destroy_host(host);if(device_buffer&&free_device)free_device(context,device_buffer);}
  if(library)dlclose(library);
 }
};
template<typename T>T sym(Field& f,const char* name){void* p=dlsym(f.library,name);if(!p)throw std::runtime_error(std::string("missing genuine Warp field symbol: ")+name);return reinterpret_cast<T>(p);}
float scalar(const uint8_t* p){uint32_t bits=uint32_t(p[0])|(uint32_t(p[1])<<8)|(uint32_t(p[2])<<16)|(uint32_t(p[3])<<24);float value;std::memcpy(&value,&bits,4);if(!std::isfinite(value))throw std::runtime_error("nonfinite cooked field value");return value;}
}
int mr_cooked_field_abi(){return 1;}
void* mr_cooked_field_open(const char* library,int kind,const uint8_t* bytes,size_t size,int nx,int ny,int nz,int channels,int dtype,const uint8_t* placement,size_t placement_size,float background){
 auto* f=new(std::nothrow) Field;if(!f)return nullptr;
 try {
  uint32_t endian=1;if(*reinterpret_cast<uint8_t*>(&endian)!=1)throw std::runtime_error("cooked texture byte ABI currently requires little-endian host");
  if(!library||!*library||!bytes||kind<0||kind>1||nx<1||ny<1||nz<1||nx>256||ny>256||nz>256||(channels!=1&&channels!=2&&channels!=4)||dtype<0||dtype>2)throw std::runtime_error("invalid bounded native field dimensions/type/path");
  const size_t width=dtype==WP_TEXTURE_DTYPE_FLOAT32?4:dtype==WP_TEXTURE_DTYPE_UINT16?2:1;
  if(size!=size_t(nx)*ny*nz*channels*width||size>268435456)throw std::runtime_error("native field data span mismatch");
  if(dtype==WP_TEXTURE_DTYPE_FLOAT32)for(size_t i=0;i<size;i+=4)scalar(bytes+i);
  f->kind=kind;f->shape[0]=nx;f->shape[1]=ny;f->shape[2]=nz;f->channels=channels;f->dtype=dtype;f->data.assign(bytes,bytes+size);
  f->library=dlopen(library,RTLD_NOW|RTLD_LOCAL);if(!f->library)throw std::runtime_error("cannot load explicit Warp field library");
  auto version=sym<decltype(&wp_version)>(*f,"wp_version");if(!version()||std::strcmp(version(),"1.17.0"))throw std::runtime_error("Warp 1.17.0 field runtime required");
  if(kind==0){
   auto create=sym<decltype(&wp_texture_create_host)>(*f,"wp_texture_create_host");f->texture_destroy_host=sym<decltype(f->texture_destroy_host)>(*f,"wp_texture_destroy_host");
   int widths[1]={nx},heights[1]={ny},depths[1]={nz},address[3]={WP_TEXTURE_ADDRESS_CLAMP,WP_TEXTURE_ADDRESS_CLAMP,WP_TEXTURE_ADDRESS_CLAMP};void* pointer=nullptr;
   f->host=create(3,1,widths,heights,depths,channels,dtype,WP_TEXTURE_FILTER_LINEAR,WP_TEXTURE_FILTER_CLOSEST,address,false,&pointer);
   if(!f->host||!pointer)throw std::runtime_error("genuine Warp host texture allocation failed");std::memcpy(pointer,bytes,size);
  }else {
   if(dtype!=WP_TEXTURE_DTYPE_FLOAT32||channels!=1||placement_size!=24||!placement||!std::isfinite(background))throw std::runtime_error("NanoVDB input requires scalar f32 data and explicit dx/origin");
   float transform[9]={},translation[3];for(int k=0;k<3;++k){transform[k*3+k]=scalar(placement+k*4);translation[k]=scalar(placement+12+k*4);if(transform[k*3+k]<=0)throw std::runtime_error("positive voxel size required");}
   std::vector<int32_t> tiles;for(int z=0;z<nz;z+=8)for(int y=0;y<ny;y+=8)for(int x=0;x<nx;x+=8){tiles.push_back(x);tiles.push_back(y);tiles.push_back(z);}
   auto create=sym<decltype(&wp_volume_from_tiles_host)>(*f,"wp_volume_from_tiles_host");f->volume_destroy_host=sym<decltype(f->volume_destroy_host)>(*f,"wp_volume_destroy_host");f->buffer_info=sym<decltype(f->buffer_info)>(*f,"wp_volume_get_buffer_info");
   uint32_t status=0;f->host=create(tiles.data(),int(tiles.size()/3),nullptr,transform,translation,false,&background,sizeof(float),"float",false,0,0,0,&status);
   if(!f->host||status)throw std::runtime_error("genuine Warp host NanoVDB tile allocation failed");
   for(int z=0;z<nz;++z)for(int y=0;y<ny;++y)for(int x=0;x<nx;++x)wp::volume_store_f(f->host,x,y,z,scalar(bytes+((size_t(z)*ny+y)*nx+x)*4));
  }
 }catch(const std::exception& e){f->error=e.what();}catch(...){f->error="unknown native field failure";}return f;
}
const char* mr_cooked_field_error(void* p){return p?static_cast<Field*>(p)->error.c_str():"null field owner";}
uint64_t mr_cooked_field_host_id(void* p){auto* f=static_cast<Field*>(p);return f&&f->error.empty()?f->host:0;}
uint64_t mr_cooked_field_device_id(void* p){auto* f=static_cast<Field*>(p);return f&&f->error.empty()?f->device:0;}
uint64_t mr_cooked_field_array_id(void* p){auto* f=static_cast<Field*>(p);return f&&f->error.empty()?f->array:0;}
void mr_cooked_field_make_device(void* ptr,uint64_t context,uint64_t stream){
 auto* f=static_cast<Field*>(ptr);if(!f)return;
 try {
  if(!f->error.empty()||!f->host||f->context||!context)throw std::runtime_error("live host field and fresh explicit context required");
  auto enabled=sym<decltype(&wp_is_cuda_enabled)>(*f,"wp_is_cuda_enabled");if(!enabled())throw std::runtime_error("Warp runtime has no CUDA support");
  f->synchronize=sym<decltype(f->synchronize)>(*f,"wp_cuda_context_synchronize");auto check=sym<decltype(&wp_cuda_context_check)>(*f,"wp_cuda_context_check");
  f->context=reinterpret_cast<void*>(context);f->stream=reinterpret_cast<void*>(stream);
  if(f->kind==0){
   auto create=sym<decltype(&wp_texture_create_device)>(*f,"wp_texture_create_device");auto copy=sym<decltype(&wp_texture_copy_device)>(*f,"wp_texture_copy_device");auto object=sym<decltype(&wp_texture_object_create_device)>(*f,"wp_texture_object_create_device");
   f->texture_destroy_device=sym<decltype(f->texture_destroy_device)>(*f,"wp_texture_destroy_device");f->object_destroy=sym<decltype(f->object_destroy)>(*f,"wp_texture_object_destroy_device");
   f->array=create(f->context,3,f->shape,f->channels,f->dtype,false,1);if(!f->array)throw std::runtime_error("genuine CUDA texture array allocation failed");
   unsigned width=unsigned(f->shape[0]*f->channels*(f->dtype==2?4:f->dtype==1?2:1));
   // CUDA driver CUmemorytype values used by Warp's public int-valued C ABI:
   // HOST=1, ARRAY=3. No CUDA array/descriptor layout is recreated here.
   if(!copy(f->context,width,unsigned(f->shape[1]),unsigned(f->shape[2]),3,f->array,0,0,1,reinterpret_cast<uint64_t>(f->data.data()),width,unsigned(f->shape[1]),f->stream))throw std::runtime_error("native texture upload failed");
   f->synchronize(f->context);int modes[3]={WP_TEXTURE_ADDRESS_CLAMP,WP_TEXTURE_ADDRESS_CLAMP,WP_TEXTURE_ADDRESS_CLAMP};
   f->device=object(f->context,f->array,3,WP_TEXTURE_FILTER_LINEAR,WP_TEXTURE_FILTER_CLOSEST,modes,false,1);
  }else {
   void* data=nullptr;uint64_t size=0;f->buffer_info(f->host,&data,&size);if(!data||!size||size>1073741824ULL)throw std::runtime_error("invalid genuine NanoVDB buffer");
   auto allocate=sym<decltype(&wp_alloc_device_default)>(*f,"wp_alloc_device_default");auto copy=sym<decltype(&wp_memcpy_h2d)>(*f,"wp_memcpy_h2d");auto create=sym<decltype(&wp_volume_create_device)>(*f,"wp_volume_create_device");
   f->free_device=sym<decltype(f->free_device)>(*f,"wp_free_device_default");f->volume_destroy_device=sym<decltype(f->volume_destroy_device)>(*f,"wp_volume_destroy_device");
   f->device_buffer=allocate(f->context,size,"moonrobo-cooked-NanoVDB");if(!f->device_buffer||!copy(f->context,f->device_buffer,data,size,f->stream))throw std::runtime_error("NanoVDB device upload failed");f->synchronize(f->context);
   f->device=create(f->context,f->device_buffer,size,false,false);
  }
  f->synchronize(f->context);if(!f->device||check(f->context))throw std::runtime_error("native field device creation/synchronization failed");
 }catch(const std::exception& e){f->error=e.what();}catch(...){f->error="unknown native device field failure";}
}
const uint8_t* mr_cooked_field_snapshot(void* ptr,size_t* size){auto* f=static_cast<Field*>(ptr);if(!f||!f->error.empty()){*size=0;return nullptr;}if(f->kind==0){*size=f->data.size();return f->data.data();}void* data=nullptr;uint64_t bytes=0;f->buffer_info(f->host,&data,&bytes);*size=size_t(bytes);return static_cast<const uint8_t*>(data);}
void mr_cooked_field_close(void* ptr){delete static_cast<Field*>(ptr);}
void* mr_cooked_volume_open_tiles(const char* library,const uint8_t* tile_bytes,size_t tile_size,const uint8_t* values,size_t value_size,const uint8_t* placement,size_t placement_size,float background){
 auto* f=new(std::nothrow) Field;if(!f)return nullptr;f->kind=1;
 try {
  uint32_t endian=1;if(*reinterpret_cast<uint8_t*>(&endian)!=1)throw std::runtime_error("NanoVDB tiles require little-endian host");
  if(!library||!*library||!tile_bytes||!values||tile_size%12||tile_size>32768*12ULL||value_size!=tile_size/12*512*4||!placement||placement_size!=24||!std::isfinite(background))throw std::runtime_error("invalid sparse NanoVDB tiles/value/transform span");
  float transform[9]={},translation[3];for(int k=0;k<3;++k){transform[k*3+k]=scalar(placement+k*4);translation[k]=scalar(placement+12+k*4);if(transform[k*3+k]<=0)throw std::runtime_error("positive voxel size required");}
  std::vector<int32_t> tiles(tile_size/4);if(tile_size)std::memcpy(tiles.data(),tile_bytes,tile_size);
  for(size_t i=0;i<tiles.size();++i)if(tiles[i]<0||tiles[i]>248||tiles[i]%8)throw std::runtime_error("sparse tile origins require 8-aligned bounded coordinates");
  for(size_t i=0;i<value_size;i+=4)scalar(values+i);
  f->library=dlopen(library,RTLD_NOW|RTLD_LOCAL);if(!f->library)throw std::runtime_error("cannot load explicit Warp volume library");
  auto version=sym<decltype(&wp_version)>(*f,"wp_version");if(!version()||std::strcmp(version(),"1.17.0"))throw std::runtime_error("Warp 1.17.0 volume runtime required");
  auto create=sym<decltype(&wp_volume_from_tiles_host)>(*f,"wp_volume_from_tiles_host");f->volume_destroy_host=sym<decltype(f->volume_destroy_host)>(*f,"wp_volume_destroy_host");f->buffer_info=sym<decltype(f->buffer_info)>(*f,"wp_volume_get_buffer_info");
  uint32_t status=0;f->host=create(tiles.data(),int(tiles.size()/3),nullptr,transform,translation,false,&background,sizeof(float),"float",false,0,0,0,&status);
  if(!f->host||status)throw std::runtime_error("genuine sparse NanoVDB tile allocation failed");
  for(size_t t=0;t<tiles.size()/3;++t)for(int z=0;z<8;++z)for(int y=0;y<8;++y)for(int x=0;x<8;++x)wp::volume_store_f(f->host,tiles[t*3]+x,tiles[t*3+1]+y,tiles[t*3+2]+z,scalar(values+(t*512+(z*8+y)*8+x)*4));
 }catch(const std::exception& e){f->error=e.what();}catch(...){f->error="unknown sparse volume failure";}return f;
}
void mr_cooked_volume_sample(void* ptr,const uint8_t* xyz,size_t size,uint8_t* output,size_t output_size){
 auto* f=static_cast<Field*>(ptr);if(!f)return;
 try {
  if(!f->error.empty()||f->kind!=1||!f->host||size%12||output_size!=size/3||size>48000000||!xyz||!output)throw std::runtime_error("invalid host NanoVDB sample span");
  for(size_t i=0;i<size/12;++i){wp::vec3 point(scalar(xyz+i*12),scalar(xyz+i*12+4),scalar(xyz+i*12+8));
   float value=wp::volume_sample_f(f->host,wp::volume_world_to_index(f->host,point),wp::volume::LINEAR);
   if(!std::isfinite(value))throw std::runtime_error("nonfinite NanoVDB sample");std::memcpy(output+i*4,&value,4);}
 }catch(const std::exception& e){f->error=e.what();}catch(...){f->error="unknown volume sample failure";}
}
