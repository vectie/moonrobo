// Native ABI is obtained from the genuine fixed Warp headers, never recreated.
#include "mesh_api.h"
#include <warp.h>
#include <bvh.h>
#include <mesh.h>
#include <algorithm>
#include <cmath>
#include <cstring>
#include <new>
#include <stdexcept>
#include <string>
#include <vector>
#include <limits>
#if defined(_WIN32)
#include <windows.h>
#else
#include <dlfcn.h>
#endif

namespace {
struct MeshOwner {
  void* library=nullptr;
  decltype(&wp_mesh_create_host) create=nullptr;
  decltype(&wp_mesh_destroy_host) destroy=nullptr;
  decltype(&wp_mesh_refit_host) refit=nullptr;
  decltype(&wp_get_error_string) warp_error=nullptr;
  std::vector<wp::vec3> points,velocities;
  std::vector<wp::vec3> points_grad,velocities_grad;
  std::vector<int> indices,groups;
  uint64_t id=0;
  uint64_t device_id=0;void* context=nullptr;void* stream=nullptr;
  void* device_points=nullptr;void* device_velocities=nullptr;void* device_indices=nullptr;void* device_groups=nullptr;
  void* device_points_grad=nullptr;void* device_velocities_grad=nullptr;
  decltype(&wp_mesh_create_device) create_device=nullptr;
  decltype(&wp_mesh_destroy_device) destroy_device=nullptr;
  decltype(&wp_mesh_refit_device) refit_device=nullptr;
  decltype(&wp_alloc_device_default) allocate_device=nullptr;
  decltype(&wp_free_device_default) free_device=nullptr;
  decltype(&wp_memcpy_h2d) copy_device=nullptr;
  decltype(&wp_cuda_context_synchronize) synchronize=nullptr;
  decltype(&wp_cuda_context_check) context_check=nullptr;
  bool winding=false;
  std::string error;
  ~MeshOwner() noexcept {
    if(context&&synchronize){try{synchronize(context);}catch(...){}}
    if(device_id&&destroy_device){try{destroy_device(device_id);}catch(...){}device_id=0;}
    if(free_device){for(void* p:{device_points,device_velocities,device_indices,device_groups,device_points_grad,device_velocities_grad})if(p){try{free_device(context,p);}catch(...){}}}
    // Warp's Mesh descriptors borrow our vectors. Destroy BVH/Mesh first.
    if(id&&destroy) {try{destroy(id);}catch(...){} id=0;}
    if(library) {
#if defined(_WIN32)
      FreeLibrary(static_cast<HMODULE>(library));
#else
      dlclose(library);
#endif
    }
  }
};
template<typename T> T symbol(MeshOwner& m,const char* name) {
#if defined(_WIN32)
  void* p=reinterpret_cast<void*>(GetProcAddress(static_cast<HMODULE>(m.library),name));
#else
  void* p=dlsym(m.library,name);
#endif
  if(!p)throw std::runtime_error(std::string("missing genuine Warp symbol: ")+name);
  return reinterpret_cast<T>(p);
}
uint32_t u32(const uint8_t* p) {
  return uint32_t(p[0])|(uint32_t(p[1])<<8)|(uint32_t(p[2])<<16)|(uint32_t(p[3])<<24);
}
float f32(const uint8_t* p) {
  uint32_t bits=u32(p);float f;std::memcpy(&f,&bits,4);
  if(!std::isfinite(f))throw std::runtime_error("nonfinite native mesh coordinate/velocity");
  return f;
}
std::vector<wp::vec3> vectors(const uint8_t* data,size_t bytes) {
  if(!data||bytes<36||bytes%12||bytes>48000000)throw std::runtime_error("invalid vec3f mesh span");
  std::vector<wp::vec3> out;out.reserve(bytes/12);
  for(size_t i=0;i<bytes;i+=12)out.emplace_back(f32(data+i),f32(data+i+4),f32(data+i+8));
  return out;
}
std::vector<int> integers(const uint8_t* data,size_t bytes) {
  if(bytes%4||bytes>48000000||(!data&&bytes))throw std::runtime_error("invalid int32 mesh span");
  std::vector<int> out;out.reserve(bytes/4);
  for(size_t i=0;i<bytes;i+=4){uint32_t bits=u32(data+i);int32_t value;std::memcpy(&value,&bits,4);out.push_back(value);}
  return out;
}
void validate_triangles(const std::vector<wp::vec3>& p,const std::vector<int>& idx) {
  if(idx.empty()||idx.size()%3)throw std::runtime_error("explicit nonempty triangulated indices required");
  for(int i:idx)if(i<0||size_t(i)>=p.size())throw std::runtime_error("native triangle index outside vertex buffer");
  for(size_t i=0;i<idx.size();i+=3) {
    const auto& a=p[idx[i]];const auto& b=p[idx[i+1]];const auto& c=p[idx[i+2]];
    const double ux=double(b[0])-a[0],uy=double(b[1])-a[1],uz=double(b[2])-a[2];
    const double vx=double(c[0])-a[0],vy=double(c[1])-a[1],vz=double(c[2])-a[2];
    if((ux*vy-uy*vx)==0&&(uy*vz-uz*vy)==0&&(uz*vx-ux*vz)==0)
      throw std::runtime_error("degenerate float32 triangle rejected");
  }
}
}

int mr_host_mesh_abi(void){return 1;}
void* mr_host_mesh_open(const char* path,const uint8_t* p,size_t pn,const uint8_t* v,size_t vn,
 const uint8_t* t,size_t tn,const uint8_t* g,size_t gn,int constructor,int leaf,int winding) {
  auto* m=new(std::nothrow) MeshOwner;
  if(!m)return nullptr;
  try {
    static_assert(sizeof(float)==4&&sizeof(int)==4,"Warp mesh ABI requires 32-bit float/int");
    if(!path||!*path||(constructor!=BVH_CONSTRUCTOR_SAH&&constructor!=BVH_CONSTRUCTOR_MEDIAN)||leaf<1||leaf>64||(winding!=0&&winding!=1))
      throw std::runtime_error("explicit Warp path/host constructor/leaf/winding required");
    m->points=vectors(p,pn);m->velocities=vectors(v,vn);
    if(m->points.size()!=m->velocities.size())throw std::runtime_error("mesh velocity cardinality mismatch");
    m->indices=integers(t,tn);m->groups=integers(g,gn);
    validate_triangles(m->points,m->indices);
    if(!m->groups.empty()&&m->groups.size()!=m->indices.size()/3)throw std::runtime_error("mesh group cardinality mismatch");
#if defined(_WIN32)
    m->library=static_cast<void*>(LoadLibraryA(path));
#else
    m->library=dlopen(path,RTLD_NOW|RTLD_LOCAL);
#endif
    if(!m->library)throw std::runtime_error("cannot load explicit Warp native library");
    auto version=symbol<decltype(&wp_version)>(*m,"wp_version");
    if(!version()||std::strcmp(version(),"1.17.0")!=0)throw std::runtime_error("Warp 1.17.0 runtime required");
    m->create=symbol<decltype(m->create)>(*m,"wp_mesh_create_host");
    m->destroy=symbol<decltype(m->destroy)>(*m,"wp_mesh_destroy_host");
    m->refit=symbol<decltype(m->refit)>(*m,"wp_mesh_refit_host");
    m->warp_error=symbol<decltype(m->warp_error)>(*m,"wp_get_error_string");
    // wp_init initializes CUDA in CUDA-enabled builds. Host allocation/BVH
    // needs no such initialization, so it is deliberately never called here.
    m->winding=winding!=0;
    m->id=m->create(wp::array_t<wp::vec3>(m->points.data(),int(m->points.size())),
      wp::array_t<wp::vec3>(m->velocities.data(),int(m->velocities.size())),
      wp::array_t<int>(m->indices.data(),int(m->indices.size())),int(m->points.size()),
      int(m->indices.size()/3),winding,constructor,m->groups.empty()?nullptr:m->groups.data(),leaf);
    if(!m->id)throw std::runtime_error(m->warp_error()?m->warp_error():"Warp host Mesh/BVH construction returned zero");
  }catch(const std::exception& e){m->error=e.what();}catch(...){m->error="unknown native host mesh failure";}
  return m;
}
const char* mr_host_mesh_error(void* ptr){return ptr?static_cast<MeshOwner*>(ptr)->error.c_str():"null mesh owner";}
uint64_t mr_host_mesh_id(void* ptr){auto* m=static_cast<MeshOwner*>(ptr);return m&&m->error.empty()?m->id:0;}
void mr_host_mesh_refit_points(void* ptr,const uint8_t* bytes,size_t size){
  auto* m=static_cast<MeshOwner*>(ptr);if(!m)return;
  try {
    if(!m->error.empty()||!m->id)throw std::runtime_error("mesh is failed or closed");
    auto points=vectors(bytes,size);
    if(points.size()!=m->points.size())throw std::runtime_error("refit cannot change vertex count or topology");
    validate_triangles(points,m->indices);
    // Keep the original pointer borrowed by Warp; never move/resize vectors.
    std::copy(points.begin(),points.end(),m->points.begin());m->refit(m->id);
    if(m->device_id){
      if(!m->copy_device(m->context,m->device_points,m->points.data(),m->points.size()*sizeof(wp::vec3),m->stream))throw std::runtime_error("device mesh point upload failed");
      m->synchronize(m->context);
      if(!m->refit_device(m->device_id))throw std::runtime_error("Warp device mesh refit failed");
      m->synchronize(m->context);if(m->context_check(m->context))throw std::runtime_error("device refit synchronization failed");
    }
  }catch(const std::exception& e){m->error=e.what();}catch(...){m->error="unknown native host mesh refit failure";}
}
void mr_host_mesh_close(void* ptr){delete static_cast<MeshOwner*>(ptr);}

void mr_host_mesh_make_device(void* ptr,uint64_t context,uint64_t stream,int constructor,int leaf){
 auto* m=static_cast<MeshOwner*>(ptr);if(!m)return;
 try {
  if(!m->error.empty()||!m->id||m->context||!context||constructor < -1||constructor>2||leaf<0||leaf>64||(constructor!=-1&&leaf<1))throw std::runtime_error("valid uncached mesh, borrowed CUDA context and explicit constructor/leaf required");
  auto enabled=symbol<decltype(&wp_is_cuda_enabled)>(*m,"wp_is_cuda_enabled");if(!enabled())throw std::runtime_error("Warp library was built without CUDA mesh support");
  if(constructor==BVH_CONSTRUCTOR_CUBQL){auto cubql=symbol<decltype(&wp_is_cubql_enabled)>(*m,"wp_is_cubql_enabled");if(!cubql()||m->winding||!m->groups.empty())throw std::runtime_error("cuBQL requires enabled runtime, no groups and no winding support");}
  m->create_device=symbol<decltype(m->create_device)>(*m,"wp_mesh_create_device");m->destroy_device=symbol<decltype(m->destroy_device)>(*m,"wp_mesh_destroy_device");
  m->refit_device=symbol<decltype(m->refit_device)>(*m,"wp_mesh_refit_device");m->allocate_device=symbol<decltype(m->allocate_device)>(*m,"wp_alloc_device_default");
  m->free_device=symbol<decltype(m->free_device)>(*m,"wp_free_device_default");m->copy_device=symbol<decltype(m->copy_device)>(*m,"wp_memcpy_h2d");
  m->synchronize=symbol<decltype(m->synchronize)>(*m,"wp_cuda_context_synchronize");m->context_check=symbol<decltype(m->context_check)>(*m,"wp_cuda_context_check");
  m->context=reinterpret_cast<void*>(context);m->stream=reinterpret_cast<void*>(stream);
  auto upload=[&](void*& target,void* source,size_t bytes){if(!bytes)return;target=m->allocate_device(m->context,bytes,"moonrobo-cooked-mesh");if(!target||!m->copy_device(m->context,target,source,bytes,m->stream))throw std::runtime_error("native device mesh allocation/upload failed");};
  upload(m->device_points,m->points.data(),m->points.size()*sizeof(wp::vec3));upload(m->device_velocities,m->velocities.data(),m->velocities.size()*sizeof(wp::vec3));
  upload(m->device_indices,m->indices.data(),m->indices.size()*sizeof(int));upload(m->device_groups,m->groups.data(),m->groups.size()*sizeof(int));
  m->synchronize(m->context);
  m->device_id=m->create_device(m->context,wp::array_t<wp::vec3>(static_cast<wp::vec3*>(m->device_points),int(m->points.size())),
   wp::array_t<wp::vec3>(static_cast<wp::vec3*>(m->device_velocities),int(m->velocities.size())),
   wp::array_t<int>(static_cast<int*>(m->device_indices),int(m->indices.size())),int(m->points.size()),int(m->indices.size()/3),m->winding?1:0,constructor,static_cast<int*>(m->device_groups),leaf);
  m->synchronize(m->context);if(!m->device_id||m->context_check(m->context))throw std::runtime_error("genuine Warp device Mesh/BVH construction failed");
 }catch(const std::exception& e){m->error=e.what();}catch(...){m->error="unknown device mesh failure";}
}
uint64_t mr_host_mesh_device_id(void* ptr){auto* m=static_cast<MeshOwner*>(ptr);return m&&m->error.empty()?m->device_id:0;}
void mr_host_mesh_sample(void* ptr,const uint8_t* bytes,size_t size,int mode,float max_distance,float threshold,uint8_t* output,size_t output_size){
 auto* m=static_cast<MeshOwner*>(ptr);if(!m)return;
 try {
  if(!m->error.empty()||!m->id||!bytes||!output||size%12||output_size!=size/3||size>48000000||mode<0||mode>2||!std::isfinite(max_distance)||max_distance<=0||!std::isfinite(threshold))throw std::runtime_error("invalid explicit host SDF sample request");
  if(mode==0&&!m->winding)throw std::runtime_error("winding queries require winding-number BVH data");
  for(size_t i=0;i<size/12;++i){
   wp::vec3 p(f32(bytes+i*12),f32(bytes+i*12+4),f32(bytes+i*12+8));
   wp::mesh_query_point_t query=mode==0?wp::mesh_query_point_sign_winding_number(m->id,p,max_distance,2.0f,threshold):mode==1?wp::mesh_query_point_sign_parity(m->id,p,max_distance):wp::mesh_query_point_sign_normal(m->id,p,max_distance);
   float distance=max_distance;
   if(query.result){auto closest=wp::mesh_eval_position(m->id,query.face,query.u,query.v);float sign=query.sign;if(mode==0&&threshold<0)sign=-sign;distance=sign*wp::length(closest-p);}
   if(!std::isfinite(distance))throw std::runtime_error("nonfinite native SDF query result");
   uint32_t bits;std::memcpy(&bits,&distance,4);for(int k=0;k<4;++k)output[i*4+k]=uint8_t(bits>>(8*k));
  }
 }catch(const std::exception& e){m->error=e.what();}catch(...){m->error="unknown host SDF query failure";}
}
void mr_host_mesh_refit_velocities(void* ptr,const uint8_t* bytes,size_t size){
 auto* m=static_cast<MeshOwner*>(ptr);if(!m)return;
 try {
  if(!m->error.empty()||!m->id||!bytes||size!=m->velocities.size()*sizeof(wp::vec3))throw std::runtime_error("unchanged finite velocity span required");
  // Validate the complete incoming vector before changing the borrowed array.
  for(size_t i=0;i<size;i+=4)f32(bytes+i);
  if(m->context)m->synchronize(m->context);
  for(size_t i=0;i<m->velocities.size();++i)m->velocities[i]=wp::vec3(f32(bytes+i*12),f32(bytes+i*12+4),f32(bytes+i*12+8));
  if(m->device_id){if(!m->copy_device(m->context,m->device_velocities,m->velocities.data(),size,m->stream))throw std::runtime_error("device velocity upload failed");m->synchronize(m->context);if(m->context_check(m->context))throw std::runtime_error("device velocity update failed");}
 }catch(const std::exception& e){m->error=e.what();}catch(...){m->error="unknown velocity update failure";}
}
void mr_host_mesh_enable_gradients(void* ptr){
 auto* m=static_cast<MeshOwner*>(ptr);if(!m)return;
 try {
  if(!m->error.empty()||!m->id||!m->points_grad.empty())throw std::runtime_error("fresh live mesh gradient storage required");
  auto setp=symbol<decltype(&wp_mesh_set_points_host)>(*m,"wp_mesh_set_points_host");auto setv=symbol<decltype(&wp_mesh_set_velocities_host)>(*m,"wp_mesh_set_velocities_host");
  m->points_grad.assign(m->points.size(),wp::vec3(0.0f));m->velocities_grad.assign(m->velocities.size(),wp::vec3(0.0f));
  setp(m->id,wp::array_t<wp::vec3>(m->points.data(),int(m->points.size()),m->points_grad.data()));setv(m->id,wp::array_t<wp::vec3>(m->velocities.data(),int(m->velocities.size()),m->velocities_grad.data()));
  if(m->device_id){
   auto devicep=symbol<decltype(&wp_mesh_set_points_device)>(*m,"wp_mesh_set_points_device");auto devicev=symbol<decltype(&wp_mesh_set_velocities_device)>(*m,"wp_mesh_set_velocities_device");
   auto push=symbol<decltype(&wp_cuda_context_push_current)>(*m,"wp_cuda_context_push_current");auto pop=symbol<decltype(&wp_cuda_context_pop_current)>(*m,"wp_cuda_context_pop_current");
   const size_t size=m->points.size()*sizeof(wp::vec3);m->synchronize(m->context);
   m->device_points_grad=m->allocate_device(m->context,size,"moonrobo-mesh-points-grad");m->device_velocities_grad=m->allocate_device(m->context,size,"moonrobo-mesh-velocity-grad");
   if(!m->device_points_grad||!m->device_velocities_grad||!m->copy_device(m->context,m->device_points_grad,m->points_grad.data(),size,m->stream)||!m->copy_device(m->context,m->device_velocities_grad,m->velocities_grad.data(),size,m->stream))throw std::runtime_error("mesh gradient allocation/upload failed");
   m->synchronize(m->context);int okay=0;
   {push(m->context);struct Restore{decltype(pop) call;~Restore(){call();}} restore{pop};
    okay=devicep(m->device_id,wp::array_t<wp::vec3>(static_cast<wp::vec3*>(m->device_points),int(m->points.size()),static_cast<wp::vec3*>(m->device_points_grad)));
    devicev(m->device_id,wp::array_t<wp::vec3>(static_cast<wp::vec3*>(m->device_velocities),int(m->velocities.size()),static_cast<wp::vec3*>(m->device_velocities_grad)));}
   m->synchronize(m->context);if(!okay||m->context_check(m->context))throw std::runtime_error("mesh gradient descriptor update failed");
  }
 }catch(const std::exception& e){m->error=e.what();}catch(...){m->error="unknown gradient storage failure";}
}
void mr_host_mesh_zero_gradients(void* ptr){
 auto* m=static_cast<MeshOwner*>(ptr);if(!m)return;
 try {
  if(!m->error.empty()||m->points_grad.empty())throw std::runtime_error("live mesh gradient storage required");
  if(m->context)m->synchronize(m->context);
  for(size_t i=0;i<m->points_grad.size();++i){m->points_grad[i]=wp::vec3(0.0f);m->velocities_grad[i]=wp::vec3(0.0f);}
  if(m->device_id){size_t size=m->points.size()*sizeof(wp::vec3);if(!m->copy_device(m->context,m->device_points_grad,m->points_grad.data(),size,m->stream)||!m->copy_device(m->context,m->device_velocities_grad,m->velocities_grad.data(),size,m->stream))throw std::runtime_error("mesh gradient clear failed");m->synchronize(m->context);if(m->context_check(m->context))throw std::runtime_error("gradient clear synchronization failed");}
 }catch(const std::exception& e){m->error=e.what();}catch(...){m->error="unknown gradient clear failure";}
}
void mr_host_mesh_gradient_snapshot(void* ptr,int device,int velocity,uint8_t* output,size_t size){
 auto* m=static_cast<MeshOwner*>(ptr);if(!m)return;
 try {
  if(!m->error.empty()||m->points_grad.empty()||size!=m->points.size()*sizeof(wp::vec3)||!output)throw std::runtime_error("live gradient storage and exact output span required");
  if(device){if(!m->device_id)throw std::runtime_error("GPU gradient snapshot requires a device mesh");auto copy=symbol<decltype(&wp_memcpy_d2h)>(*m,"wp_memcpy_d2h");m->synchronize(m->context);if(!copy(m->context,output,velocity?m->device_velocities_grad:m->device_points_grad,size,m->stream))throw std::runtime_error("mesh gradient download failed");m->synchronize(m->context);if(m->context_check(m->context))throw std::runtime_error("mesh gradient download synchronization failed");}
  else std::memcpy(output,velocity?m->velocities_grad.data():m->points_grad.data(),size);
 }catch(const std::exception& e){m->error=e.what();}catch(...){m->error="unknown gradient snapshot failure";}
}
