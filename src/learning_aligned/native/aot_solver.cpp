// Genuine Python-free Warp 1.17 APIC replay. Four branch-free graphs avoid
// wrapping SAP sort/scan scratch allocation in a CUDA conditional body.
// https://github.com/NVIDIA/warp/blob/v1.17.0/warp/native/apic.h
#if defined(MOONROBO_APIC_DYNAMIC_CUDA)
#include "apic_runtime/cuda_driver_dynamic.h"
#else
#include <cuda.h>
#endif
#include <apic.h>
#include <array>
#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <cstdlib>
#include <cstdio>
#include <limits>
#include <map>
#include <memory>
#include <mutex>
#include <stdexcept>
#include <string>
#include <vector>
#if APIC_FORMAT_VERSION != 15
#error "This physics artifact contract pins Warp 1.17 APIC format 15"
#endif
#if defined(_WIN32)
#define MR_EXPORT __declspec(dllexport)
#else
#define MR_EXPORT __attribute__((visibility("default")))
#endif
extern "C" int wp_init(const char* expected_version);
extern "C" const char* wp_get_error_string();
namespace {
void cuda_check(CUresult value){if(value!=CUDA_SUCCESS){const char* message=nullptr;cuGetErrorString(value,&message);throw std::runtime_error(message?message:"CUDA driver failure");}}
void warp_check(bool ok){if(!ok)throw std::runtime_error(wp_get_error_string());}
size_t checked_add(size_t a,size_t b){if(b>std::numeric_limits<size_t>::max()-a)throw std::runtime_error("APIC byte span overflow");return a+b;}
size_t checked_mul(size_t a,size_t b){if(a && b>std::numeric_limits<size_t>::max()/a)throw std::runtime_error("APIC byte span overflow");return a*b;}
struct View {std::string binding;size_t offset=0,row=0,component=0,width=0,scalar=4;};
struct Shared {std::string name;size_t bytes;};
struct Runtime {
  int n=0,device_id=0,last=0,audit_world_limit=128;CUdevice device=0;CUcontext context=nullptr;CUstream stream=nullptr;
  std::array<APICGraph*,4> graphs{};std::vector<Shared> shared;std::map<std::string,View> views;
  std::vector<double> origins;std::mutex mutex;std::string error;bool sealed=false;
  // Execution-only opt-in. The original scalar implementation stays available.
  int io_mode=0; // 0 scalar, 1 bulk, 2 bulk with exact read/write audit
  size_t verified_reads=0,verified_writes=0,bulk_transfers=0,scalar_fallbacks=0;
  ~Runtime(){if(context){cuCtxSetCurrent(context);if(stream)cuStreamSynchronize(stream);for(auto* graph:graphs)if(graph)wp_apic_destroy_graph(graph);if(stream)cuStreamDestroy(stream);cuDevicePrimaryCtxRelease(device);}}
  void current(){cuda_check(cuCtxSetCurrent(context));}
  CUdeviceptr pointer(int role,const std::string& name){void* result=wp_apic_get_param_ptr(graphs.at(role),name.c_str());if(!result)throw std::runtime_error("missing APIC binding: "+name);return reinterpret_cast<CUdeviceptr>(result);}
  void bytes(int role,const std::string& name,size_t offset,size_t count){const size_t capacity=wp_apic_get_param_size(graphs.at(role),name.c_str());if(offset>capacity||count>capacity-offset)throw std::runtime_error("APIC binding capacity mismatch: "+name);}
  const View& view(const std::string& name,size_t width,size_t scalar=4){auto it=views.find(name);if(it==views.end()||it->second.width!=width||it->second.scalar!=scalar)throw std::runtime_error("missing or malformed APIC view: "+name);return it->second;}
  void switch_to(int role){
    if(role<0||role>3||!sealed)throw std::runtime_error("APIC factory is not sealed");
    if(role==last)return;
    // Only primitive numeric base allocations occur here. Pointer/handle-bearing
    // structs and transient CUB workspaces must never appear in shared_regions.
    for(const auto& region:shared)cuda_check(cuMemcpyDtoDAsync(pointer(role,region.name),pointer(last,region.name),region.bytes,stream));
    // All later writes/launches use this same stream. Change ownership now so
    // several property writes do not recopy stale state over one another.
    last=role;
  }
  void launch(int role){warp_check(wp_apic_launch(graphs.at(role),stream));cuda_check(cuStreamSynchronize(stream));last=role;}
  void write_scalar(const View& v,const double* values,int role){
    void* host=nullptr;cuda_check(cuMemHostAlloc(&host,size_t(n)*v.width*v.scalar,CU_MEMHOSTALLOC_PORTABLE));
    try {
      for(size_t i=0;i<size_t(n)*v.width;++i){if(!std::isfinite(values[i]))throw std::runtime_error("nonfinite APIC input");if(v.scalar==4){if(std::abs(values[i])>std::numeric_limits<float>::max())throw std::runtime_error("APIC float32 input overflow");static_cast<float*>(host)[i]=float(values[i]);}else{if(values[i]!=0&&values[i]!=1)throw std::runtime_error("APIC reset mask must be Boolean");static_cast<uint8_t*>(host)[i]=uint8_t(values[i]);}}
      for(int env=0;env<n;++env)for(size_t j=0;j<v.width;++j){const size_t off=(v.offset+size_t(env)*v.row+j*v.component)*v.scalar;bytes(role,v.binding,off,v.scalar);cuda_check(cuMemcpyHtoDAsync(pointer(role,v.binding)+off,static_cast<char*>(host)+(size_t(env)*v.width+j)*v.scalar,v.scalar,stream));}
      cuda_check(cuStreamSynchronize(stream));
    } catch(...){cuMemFreeHost(host);throw;}
    cuda_check(cuMemFreeHost(host));
  }
  std::vector<double> read_scalar(const View& v,int role){
    void* host=nullptr;cuda_check(cuMemHostAlloc(&host,size_t(n)*v.width*v.scalar,CU_MEMHOSTALLOC_PORTABLE));std::vector<double> result(size_t(n)*v.width);
    try {
      for(int env=0;env<n;++env)for(size_t j=0;j<v.width;++j){const size_t off=(v.offset+size_t(env)*v.row+j*v.component)*v.scalar;bytes(role,v.binding,off,v.scalar);cuda_check(cuMemcpyDtoHAsync(static_cast<char*>(host)+(size_t(env)*v.width+j)*v.scalar,pointer(role,v.binding)+off,v.scalar,stream));}
      cuda_check(cuStreamSynchronize(stream));
      for(size_t i=0;i<result.size();++i)result[i]=v.scalar==4?double(static_cast<float*>(host)[i]):double(static_cast<uint8_t*>(host)[i]);
    }catch(...){cuMemFreeHost(host);throw;}cuda_check(cuMemFreeHost(host));return result;
  }
  // Each descriptor copies only registered scalar cells, never stride gaps or
  // neighbouring fields. Non-overlapping rows are required so write ordering
  // agrees with the legacy env-major loop. Aliased/broadcast rows fall back.
  bool bulk_layout(const View& v) const {
    return v.row>=checked_add(checked_mul(v.width-1,v.component),1);
  }
  void transfer(const View& v,void* host,int role,bool upload){
    ++bulk_transfers;
    const size_t row_bytes=checked_mul(v.width,v.scalar);
    const size_t offset=checked_mul(v.offset,v.scalar);
    const size_t end=checked_mul(checked_add(checked_add(v.offset,checked_mul(size_t(n-1),v.row)),checked_mul(v.width-1,v.component)),v.scalar);
    bytes(role,v.binding,end,v.scalar);
    const auto device_base=pointer(role,v.binding);
    for(size_t j=0;j<(v.component==1?1:v.width);++j){
      CUDA_MEMCPY2D copy{};
      copy.WidthInBytes=v.component==1?row_bytes:v.scalar;
      copy.Height=size_t(n);
      if(upload){
        copy.srcMemoryType=CU_MEMORYTYPE_HOST;copy.srcHost=static_cast<char*>(host)+j*v.scalar;copy.srcPitch=row_bytes;
        copy.dstMemoryType=CU_MEMORYTYPE_DEVICE;copy.dstDevice=device_base+offset+j*v.component*v.scalar;copy.dstPitch=checked_mul(v.row,v.scalar);
      }else{
        copy.srcMemoryType=CU_MEMORYTYPE_DEVICE;copy.srcDevice=device_base+offset+j*v.component*v.scalar;copy.srcPitch=checked_mul(v.row,v.scalar);
        copy.dstMemoryType=CU_MEMORYTYPE_HOST;copy.dstHost=static_cast<char*>(host)+j*v.scalar;copy.dstPitch=row_bytes;
      }
      cuda_check(cuMemcpy2DAsync(&copy,stream));
    }
  }
  void write_bulk(const View& v,const double* values,int role){
    if(!bulk_layout(v)){++scalar_fallbacks;write_scalar(v,values,role);return;}
    void* host=nullptr;cuda_check(cuMemHostAlloc(&host,checked_mul(checked_mul(size_t(n),v.width),v.scalar),CU_MEMHOSTALLOC_PORTABLE));
    try{
      for(size_t i=0;i<size_t(n)*v.width;++i){if(!std::isfinite(values[i]))throw std::runtime_error("nonfinite APIC input");if(v.scalar==4){if(std::abs(values[i])>std::numeric_limits<float>::max())throw std::runtime_error("APIC float32 input overflow");static_cast<float*>(host)[i]=float(values[i]);}else{if(values[i]!=0&&values[i]!=1)throw std::runtime_error("APIC reset mask must be Boolean");static_cast<uint8_t*>(host)[i]=uint8_t(values[i]);}}
      transfer(v,host,role,true);cuda_check(cuStreamSynchronize(stream));
    }catch(...){cuStreamSynchronize(stream);cuMemFreeHost(host);throw;}
    cuda_check(cuMemFreeHost(host));
  }
  std::vector<double> read_bulk(const View& v,int role){
    if(!bulk_layout(v)){++scalar_fallbacks;return read_scalar(v,role);}
    void* host=nullptr;cuda_check(cuMemHostAlloc(&host,checked_mul(checked_mul(size_t(n),v.width),v.scalar),CU_MEMHOSTALLOC_PORTABLE));
    std::vector<double> result(size_t(n)*v.width);
    try{
      transfer(v,host,role,false);cuda_check(cuStreamSynchronize(stream));
      for(size_t i=0;i<result.size();++i)result[i]=v.scalar==4?double(static_cast<float*>(host)[i]):double(static_cast<uint8_t*>(host)[i]);
    }catch(...){cuStreamSynchronize(stream);cuMemFreeHost(host);throw;}
    cuda_check(cuMemFreeHost(host));return result;
  }
  std::vector<double> read(const View& v,int role){
    if(io_mode==0)return read_scalar(v,role);
    auto result=read_bulk(v,role);
    if(io_mode==2){auto baseline=read_scalar(v,role);if(result.size()!=baseline.size()||std::memcmp(result.data(),baseline.data(),result.size()*sizeof(double)))throw std::runtime_error("APIC bulk read exact gate failed: "+v.binding);++verified_reads;}
    return result;
  }
  void write(const View& v,const double* values,int role){
    if(io_mode==0){write_scalar(v,values,role);return;}
    if(io_mode==1){write_bulk(v,values,role);return;}
    // Gate only: compare the COMPLETE registered allocation, including stride
    // gaps, after scalar and bulk writes from the same starting bytes. Bounded
    // pinned audit storage is freed before another view or graph is processed.
    size_t capacity=wp_apic_get_param_size(graphs.at(role),v.binding.c_str());
    if(capacity==0||capacity>16*1024*1024)throw std::runtime_error("APIC exact write audit exceeds 16MiB base bound");
    void* host=nullptr;cuda_check(cuMemHostAlloc(&host,checked_mul(capacity,3),CU_MEMHOSTALLOC_PORTABLE));
    auto* original=static_cast<char*>(host);auto* expected=original+capacity;auto* actual=expected+capacity;
    try{
      cuda_check(cuMemcpyDtoHAsync(original,pointer(role,v.binding),capacity,stream));cuda_check(cuStreamSynchronize(stream));
      write_scalar(v,values,role);
      cuda_check(cuMemcpyDtoHAsync(expected,pointer(role,v.binding),capacity,stream));cuda_check(cuStreamSynchronize(stream));
      cuda_check(cuMemcpyHtoDAsync(pointer(role,v.binding),original,capacity,stream));cuda_check(cuStreamSynchronize(stream));
      write_bulk(v,values,role);
      cuda_check(cuMemcpyDtoHAsync(actual,pointer(role,v.binding),capacity,stream));cuda_check(cuStreamSynchronize(stream));
      if(std::memcmp(expected,actual,capacity))throw std::runtime_error("APIC bulk write exact gate failed (including gaps): "+v.binding);
      ++verified_writes;
    }catch(...){cuStreamSynchronize(stream);cuMemFreeHost(host);throw;}
    cuda_check(cuMemFreeHost(host));
  }
};
thread_local std::string open_error;
template<class F> int operation(Runtime* rt,F&& action){if(!rt){open_error="null APIC runtime";return 0;}std::lock_guard<std::mutex> lock(rt->mutex);rt->error.clear();try{rt->current();action(*rt);return 1;}catch(const std::exception& e){rt->error=e.what();return 0;}}
std::array<double,3> rotate(const double* xyzw,const double* vec){
  double x=xyzw[0],y=xyzw[1],z=xyzw[2],w=xyzw[3],norm=std::sqrt(x*x+y*y+z*z+w*w);if(!(norm>1e-12))throw std::runtime_error("invalid APIC root quaternion");x/=norm;y/=norm;z/=norm;w/=norm;
  return {(1-2*(y*y+z*z))*vec[0]+2*(x*y-w*z)*vec[1]+2*(x*z+w*y)*vec[2],2*(x*y+w*z)*vec[0]+(1-2*(x*x+z*z))*vec[1]+2*(y*z-w*x)*vec[2],2*(x*z-w*y)*vec[0]+2*(y*z+w*x)*vec[1]+(1-2*(x*x+y*y))*vec[2]};
}
}
extern "C" MR_EXPORT const char* mr_apic_error(Runtime* rt){return rt?rt->error.c_str():open_error.c_str();}
extern "C" MR_EXPORT Runtime* mr_apic_open(int device_id,int worlds){
  open_error.clear();std::unique_ptr<Runtime> rt(new Runtime);
  if(const char* mode=std::getenv("MOONROBO_APIC_IO")){if(std::strcmp(mode,"bulk")==0)rt->io_mode=1;else if(std::strcmp(mode,"verify")==0)rt->io_mode=2;else if(std::strcmp(mode,"scalar")!=0){open_error="MOONROBO_APIC_IO must be scalar, bulk or verify";return nullptr;}}
  try{if(worlds<=0||worlds>std::numeric_limits<int>::max()/71)throw std::runtime_error("invalid APIC world count");cuda_check(cuInit(0));cuda_check(cuDeviceGet(&rt->device,device_id));cuda_check(cuDevicePrimaryCtxRetain(&rt->context,rt->device));rt->current();cuda_check(cuStreamCreate(&rt->stream,CU_STREAM_NON_BLOCKING));if(wp_init("1.17.0")!=0)throw std::runtime_error(wp_get_error_string());rt->device_id=device_id;rt->n=worlds;rt->origins.resize(size_t(worlds)*3,0);return rt.release();}catch(const std::exception& e){open_error=e.what();return nullptr;}
}
extern "C" MR_EXPORT void mr_apic_close(Runtime* rt){if(rt&&rt->io_mode==2)std::fprintf(stderr,"APIC_EXACT_IO_GATE {\"worlds\":%d,\"verified_reads\":%zu,\"verified_writes\":%zu,\"bulk_transfers\":%zu,\"scalar_fallbacks\":%zu}\n",rt->n,rt->verified_reads,rt->verified_writes,rt->bulk_transfers,rt->scalar_fallbacks);delete rt;}
extern "C" MR_EXPORT int mr_apic_graph(Runtime* rt,int role,const char* path){return operation(rt,[&](Runtime& r){if(r.sealed||role<0||role>3||r.graphs[role])throw std::runtime_error("duplicate/late APIC graph");r.graphs[role]=wp_apic_load_graph(r.context,path,APIC_DEVICE_CUDA);warp_check(r.graphs[role]!=nullptr);});}
extern "C" MR_EXPORT int mr_apic_share(Runtime* rt,const char* name,int64_t size,int scalar){return operation(rt,[&](Runtime& r){if(r.sealed||size<=0||(scalar!=1&&scalar!=4&&scalar!=8)||size%scalar)throw std::runtime_error("invalid shared numeric base capacity");for(int role=0;role<4;++role){if(!r.graphs[role]||wp_apic_get_param_size(r.graphs[role],name)!=size_t(size))throw std::runtime_error("shared allocation missing or capacity differs");r.pointer(role,name);}for(auto& existing:r.shared)if(existing.name==name)throw std::runtime_error("duplicate shared base allocation name");r.shared.push_back({name,size_t(size)});});}
extern "C" MR_EXPORT int mr_apic_view(Runtime* rt,const char* name,const char* binding,int64_t offset,int64_t row,int64_t component,int width,int scalar){return operation(rt,[&](Runtime& r){if(r.sealed||offset<0||row<0||component<=0||width<=0||(scalar!=1&&scalar!=4))throw std::runtime_error("invalid primitive APIC view");if(r.views.count(name))throw std::runtime_error("duplicate APIC view");View v{binding,size_t(offset),size_t(row),size_t(component),size_t(width),size_t(scalar)};const size_t end=checked_mul(checked_add(checked_add(v.offset,checked_mul(size_t(r.n-1),v.row)),checked_mul(size_t(width-1),v.component)),v.scalar);for(int role=0;role<4;++role)r.bytes(role,v.binding,end,v.scalar);r.views.emplace(name,std::move(v));});}
extern "C" MR_EXPORT int mr_apic_origin(Runtime* rt,int world,double x,double y,double z){return operation(rt,[&](Runtime& r){if(r.sealed||world<0||world>=r.n||!std::isfinite(x)||!std::isfinite(y)||!std::isfinite(z))throw std::runtime_error("invalid APIC environment origin");r.origins[3*world]=x;r.origins[3*world+1]=y;r.origins[3*world+2]=z;});}
extern "C" MR_EXPORT int mr_apic_seal(Runtime* rt){return operation(rt,[&](Runtime& r){if(r.shared.empty())throw std::runtime_error("APIC persistent numeric union is empty");for(auto* g:r.graphs)if(!g)throw std::runtime_error("all four physics graphs required");for(const auto& name:{"root_pose","root_com_velocity","root_com_local","joint_position","joint_velocity","targets","reset_pose","reset_velocity","reset_joint_position","reset_joint_velocity","reset_mask"})if(!r.views.count(name))throw std::runtime_error(std::string("missing view: ")+name);r.view("root_pose",7);r.view("root_com_velocity",6);r.view("root_com_local",3);r.view("joint_position",29);r.view("joint_velocity",29);r.view("targets",29);r.view("reset_pose",7);r.view("reset_velocity",6);r.view("reset_joint_position",29);r.view("reset_joint_velocity",29);r.view("reset_mask",1,1);r.sealed=true;r.switch_to(3);r.launch(3);});}
extern "C" MR_EXPORT int mr_apic_read(Runtime* rt,double* flat){return operation(rt,[&](Runtime& r){if(!r.sealed||!flat)throw std::runtime_error("APIC runtime not ready");auto pose=r.read(r.view("root_pose",7),r.last),velocity=r.read(r.view("root_com_velocity",6),r.last),com=r.read(r.view("root_com_local",3),r.last),q=r.read(r.view("joint_position",29),r.last),qd=r.read(r.view("joint_velocity",29),r.last);for(int i=0;i<r.n;++i){double* s=flat+71*i;auto offset=rotate(pose.data()+7*i+3,com.data()+3*i);const double* w=velocity.data()+6*i+3;double cross[3]={w[1]*offset[2]-w[2]*offset[1],w[2]*offset[0]-w[0]*offset[2],w[0]*offset[1]-w[1]*offset[0]};for(int j=0;j<3;++j){s[j]=pose[7*i+j]-r.origins[3*i+j];s[7+j]=velocity[6*i+j]-cross[j];s[10+j]=w[j];}s[3]=pose[7*i+6];s[4]=pose[7*i+3];s[5]=pose[7*i+4];s[6]=pose[7*i+5];for(int j=0;j<29;++j){s[13+j]=q[29*i+j];s[42+j]=qd[29*i+j];}}});}
extern "C" MR_EXPORT int mr_apic_step(Runtime* rt,const double* targets){return operation(rt,[&](Runtime& r){if(!targets)throw std::runtime_error("null APIC target input");r.switch_to(0);r.write(r.view("targets",29),targets,0);r.launch(0);});}
extern "C" MR_EXPORT int mr_apic_refresh(Runtime* rt){return operation(rt,[&](Runtime& r){r.switch_to(3);r.launch(3);});}
extern "C" MR_EXPORT int mr_apic_reset(Runtime* rt,const double* mask,const double* flat){return operation(rt,[&](Runtime& r){
  if(!mask||!flat)throw std::runtime_error("null APIC reset input");
  r.switch_to(1);
  auto com=r.read(r.view("root_com_local",3),1);
  std::vector<double> pose(size_t(r.n)*7),velocity(size_t(r.n)*6),q(size_t(r.n)*29),qd(size_t(r.n)*29);
  for(int i=0;i<r.n;++i){
    const double* s=flat+71*i;
    pose[7*i+3]=s[4];pose[7*i+4]=s[5];pose[7*i+5]=s[6];pose[7*i+6]=s[3];
    auto offset=rotate(pose.data()+7*i+3,com.data()+3*i);
    const double* w=s+10;
    const double cross[3]={w[1]*offset[2]-w[2]*offset[1],w[2]*offset[0]-w[0]*offset[2],w[0]*offset[1]-w[1]*offset[0]};
    for(int j=0;j<3;++j){pose[7*i+j]=s[j]+r.origins[3*i+j];velocity[6*i+j]=s[7+j]+cross[j];velocity[6*i+3+j]=w[j];}
    for(int j=0;j<29;++j){q[29*i+j]=s[13+j];qd[29*i+j]=s[42+j];}
  }
  // The capture-safe vendor COM setter avoids a Tier-2 lazy link-velocity read.
  r.write(r.view("reset_mask",1,1),mask,1);r.write(r.view("reset_pose",7),pose.data(),1);r.write(r.view("reset_velocity",6),velocity.data(),1);r.write(r.view("reset_joint_position",29),q.data(),1);r.write(r.view("reset_joint_velocity",29),qd.data(),1);r.launch(1);
});}
// Context values are primitive numeric model arrays, addressed by the manifest.
// All writes are ordered on the same stream. The subsequent context graph must
// contain SolverMuJoCo.notify_model_changed including derived inertia/contact
// caches; merely changing body_com/shape_mu is not a valid artifact.
extern "C" MR_EXPORT int mr_apic_context_write(Runtime* rt,const char* binding,int64_t index,double value){return operation(rt,[&](Runtime& r){r.switch_to(2);if(index<0||!std::isfinite(value)||std::abs(value)>std::numeric_limits<float>::max())throw std::runtime_error("invalid APIC model property");float host=float(value);const size_t offset=checked_mul(size_t(index),sizeof(float));r.bytes(2,binding,offset,sizeof(float));cuda_check(cuStreamSynchronize(r.stream));cuda_check(cuMemcpyHtoD(r.pointer(2,binding)+offset,&host,sizeof(float)));});}
extern "C" MR_EXPORT int mr_apic_context_commit(Runtime* rt){return operation(rt,[&](Runtime& r){r.switch_to(2);r.launch(2);});}

extern "C" MR_EXPORT int64_t mr_apic_audit_free_bytes(Runtime* rt){
  int64_t result=0;int ok=operation(rt,[&](Runtime&){size_t free=0,total=0;cuda_check(cuMemGetInfo(&free,&total));if(free>size_t(std::numeric_limits<int64_t>::max()))throw std::runtime_error("CUDA free memory exceeds Int64");result=int64_t(free);});return ok?result:0;
}

// Narrow, optional audit ABI: read only registered primitive views/indices of
// the last active graph. Never launch a graph or copy an entire scene buffer.
// Explicit caller registration is required to extend selected-world audits to
// the paper profile. Ordinary replay and old adapters never require this ABI.
// This changes only the admissible scene N, not the three-row/staging bounds.
extern "C" MR_EXPORT int mr_apic_audit_capacity_v1(Runtime* rt,int maximum_worlds){return operation(rt,[&](Runtime& r){
  if((maximum_worlds!=128&&maximum_worlds!=4096)||r.n<1||r.n>maximum_worlds)throw std::runtime_error("invalid explicit APIC audit capacity profile");
  r.audit_world_limit=maximum_worlds;
});}
extern "C" MR_EXPORT int mr_apic_audit_view(Runtime* rt,const char* name,double* out,int capacity){return operation(rt,[&](Runtime& r){
  if(!r.sealed||r.n!=2||!name||!out)throw std::runtime_error("audit requires a sealed two-world runtime");
  const std::map<std::string,int> allowed{{"root_pose",7},{"root_com_velocity",6},{"root_com_local",3},{"joint_position",29},{"joint_velocity",29},{"targets",29},{"reset_pose",7},{"reset_velocity",6},{"reset_joint_position",29},{"reset_joint_velocity",29},{"reset_mask",1}};
  auto found=allowed.find(name);if(found==allowed.end()||capacity!=r.n*found->second)throw std::runtime_error("invalid bounded audit view");
  auto values=r.read(r.view(name,found->second,std::string(name)=="reset_mask"?1:4),r.last);std::copy(values.begin(),values.end(),out);
});}
extern "C" MR_EXPORT int mr_apic_audit_values(Runtime* rt,const char* binding,const int64_t* indices,int count,double* out){return operation(rt,[&](Runtime& r){
  if(!r.sealed||r.n<1||r.n>r.audit_world_limit||!binding||!indices||!out||count<=0||count>4096)throw std::runtime_error("invalid bounded audit indices");
  bool registered=false;for(const auto& region:r.shared)if(region.name==binding)registered=true;
  if(!registered)throw std::runtime_error("audit binding is not registered persistent numeric memory");
  for(int i=0;i<count;++i){if(indices[i]<0)throw std::runtime_error("negative audit index");r.bytes(r.last,binding,checked_mul(size_t(indices[i]),sizeof(float)),sizeof(float));}
  void* host=nullptr;cuda_check(cuMemHostAlloc(&host,size_t(count)*sizeof(float),CU_MEMHOSTALLOC_PORTABLE));
  try{for(int i=0;i<count;++i)cuda_check(cuMemcpyDtoHAsync(static_cast<float*>(host)+i,r.pointer(r.last,binding)+size_t(indices[i])*sizeof(float),sizeof(float),r.stream));cuda_check(cuStreamSynchronize(r.stream));for(int i=0;i<count;++i)out[i]=double(static_cast<float*>(host)[i]);}
  catch(...){cuMemFreeHost(host);throw;}cuda_check(cuMemFreeHost(host));
});}

// Additive v2 audit ABI. The legacy two-world exports above remain available.
// Read at most three explicitly selected worlds, never the full scene. Each
// staging allocation is below 16 KiB and every strided address is checked.
namespace {
void audit_selection(Runtime& r,const int32_t* worlds,int count){
  if(!r.sealed||r.n<1||r.n>r.audit_world_limit||!worlds||count<1||count>3)throw std::runtime_error("invalid bounded audit world selection");
  for(int i=0;i<count;++i){if(worlds[i]<0||worlds[i]>=r.n)throw std::runtime_error("audit world outside runtime");for(int j=0;j<i;++j)if(worlds[i]==worlds[j])throw std::runtime_error("duplicate audit world");}
}
std::vector<double> audit_selected_view(Runtime& r,const View& v,const int32_t* worlds,int count){
  const size_t values=checked_mul(size_t(count),v.width);
  if(values>4096||(v.scalar!=1&&v.scalar!=4))throw std::runtime_error("audit view staging bound exceeded");
  std::vector<size_t> offsets(values);
  for(int i=0;i<count;++i)for(size_t j=0;j<v.width;++j){
    const size_t index=checked_add(checked_add(v.offset,checked_mul(size_t(worlds[i]),v.row)),checked_mul(j,v.component));
    const size_t off=checked_mul(index,v.scalar);r.bytes(r.last,v.binding,off,v.scalar);offsets[size_t(i)*v.width+j]=off;
  }
  void* host=nullptr;cuda_check(cuMemHostAlloc(&host,checked_mul(values,v.scalar),CU_MEMHOSTALLOC_PORTABLE));
  std::vector<double> result(values);
  try{
    const auto source=r.pointer(r.last,v.binding);
    for(size_t i=0;i<values;++i)cuda_check(cuMemcpyDtoHAsync(static_cast<char*>(host)+i*v.scalar,source+offsets[i],v.scalar,r.stream));
    cuda_check(cuStreamSynchronize(r.stream));
    for(size_t i=0;i<values;++i)result[i]=v.scalar==4?double(static_cast<float*>(host)[i]):double(static_cast<uint8_t*>(host)[i]);
  }catch(...){cuStreamSynchronize(r.stream);cuMemFreeHost(host);throw;}
  cuda_check(cuMemFreeHost(host));return result;
}
}
extern "C" MR_EXPORT int mr_apic_audit_view_selected(Runtime* rt,const char* name,const int32_t* worlds,int count,double* out,int capacity){return operation(rt,[&](Runtime& r){
  audit_selection(r,worlds,count);if(!name||!out)throw std::runtime_error("missing audit view output");
  const std::map<std::string,int> allowed{{"root_pose",7},{"root_com_velocity",6},{"root_com_local",3},{"joint_position",29},{"joint_velocity",29},{"targets",29},{"reset_pose",7},{"reset_velocity",6},{"reset_joint_position",29},{"reset_joint_velocity",29},{"reset_mask",1}};
  auto found=allowed.find(name);if(found==allowed.end()||capacity!=count*found->second)throw std::runtime_error("invalid selected audit view capacity");
  const auto values=audit_selected_view(r,r.view(name,found->second,std::string(name)=="reset_mask"?1:4),worlds,count);std::copy(values.begin(),values.end(),out);
});}
extern "C" MR_EXPORT int mr_apic_audit_read_selected(Runtime* rt,const int32_t* worlds,int count,double* out,int capacity){return operation(rt,[&](Runtime& r){
  audit_selection(r,worlds,count);if(!out||capacity!=count*71)throw std::runtime_error("invalid selected state71 capacity");
  const auto pose=audit_selected_view(r,r.view("root_pose",7),worlds,count);
  const auto vel=audit_selected_view(r,r.view("root_com_velocity",6),worlds,count);
  const auto com=audit_selected_view(r,r.view("root_com_local",3),worlds,count);
  const auto q=audit_selected_view(r,r.view("joint_position",29),worlds,count);
  const auto qd=audit_selected_view(r,r.view("joint_velocity",29),worlds,count);
  // Keep the same Double operation order as mr_apic_read: XYZW/COM ->
  // WXYZ/root-link velocity. Only row selection changes, never physics.
  for(int i=0;i<count;++i){
    double* s=out+71*i;const double* p=pose.data()+7*i;const double* v=vel.data()+6*i;
    const auto offset=rotate(p+3,com.data()+3*i);const int world=worlds[i];
    for(int j=0;j<3;++j)s[j]=p[j]-r.origins[3*world+j];
    s[3]=p[6];s[4]=p[3];s[5]=p[4];s[6]=p[5];
    s[7]=v[0]-(v[4]*offset[2]-v[5]*offset[1]);s[8]=v[1]-(v[5]*offset[0]-v[3]*offset[2]);s[9]=v[2]-(v[3]*offset[1]-v[4]*offset[0]);
    for(int j=0;j<3;++j)s[10+j]=v[3+j];
    for(int j=0;j<29;++j){s[13+j]=q[29*i+j];s[42+j]=qd[29*i+j];}
  }
});}
