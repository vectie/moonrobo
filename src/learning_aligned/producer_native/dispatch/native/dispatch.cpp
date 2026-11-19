#include "dispatch.h"
#include "warp.h"
#include "apic.h"
#include <cstring>
#include <memory>
#include <limits>
#include <string>
#include <stdexcept>
#include <thread>
#include <vector>
#include <algorithm>
#ifdef _WIN32
#include <windows.h>
#else
#include <dlfcn.h>
#endif
static_assert(APIC_FORMAT_VERSION==15,"requires Warp 1.17 APIC format 15");
static_assert(sizeof(void*)==8,"64-bit launch ABI required");
static_assert(sizeof(apic_array_t)==sizeof(wp::array_t<float>),"actual array_t ABI mismatch");
static_assert(alignof(apic_array_t)==alignof(wp::array_t<float>),"actual array_t alignment mismatch");
static_assert(offsetof(apic_array_t,flags)==offsetof(wp::array_t<float>,flags),"actual array_t flags offset mismatch");
static_assert(offsetof(apic_array_t,data)==offsetof(wp::array_t<float>,data),"actual array_t data offset mismatch");
static_assert(offsetof(apic_array_t,grad)==offsetof(wp::array_t<float>,grad),"actual array_t grad offset mismatch");
static_assert(offsetof(apic_array_t,shape)==offsetof(wp::array_t<float>,shape),"actual array_t shape offset mismatch");
static_assert(offsetof(apic_array_t,strides)==offsetof(wp::array_t<float>,strides),"actual array_t stride offset mismatch");
static_assert(offsetof(apic_array_t,ndim)==offsetof(wp::array_t<float>,ndim),"actual array_t rank offset mismatch");
namespace {
thread_local std::string error;
void require(bool p,const char* message){if(!p)throw std::runtime_error(message);}
void* openlib(const char* path){
#ifdef _WIN32
 return (void*)LoadLibraryA(path);
#else
 return dlopen(path,RTLD_NOW|RTLD_LOCAL);
#endif
}
void closelib(void* library){
#ifdef _WIN32
 FreeLibrary((HMODULE)library);
#else
 dlclose(library);
#endif
}
void* symbol(void* library,const char* name){
#ifdef _WIN32
 void* p=(void*)GetProcAddress((HMODULE)library,name);
#else
 void* p=dlsym(library,name);
#endif
 require(p,(std::string("missing actual Warp symbol ")+name).c_str());return p;
}
struct Allocation{void* pointer;uint64_t size;};
struct Device {
 void* library=nullptr;void* context=nullptr;void* stream=nullptr;bool owned=false;bool poisoned=false;int arch=0;
 std::thread::id thread=std::this_thread::get_id();
 std::vector<Allocation> allocations;std::vector<void*> modules;
#define FN(name) decltype(&name) name##_fn=nullptr
 FN(wp_version);FN(wp_init);FN(wp_get_error_string);FN(wp_is_cuda_enabled);
 FN(wp_cuda_context_create);FN(wp_cuda_context_destroy);FN(wp_cuda_context_synchronize);FN(wp_cuda_context_check);
 FN(wp_cuda_context_get_device_ordinal);FN(wp_cuda_device_get_arch);FN(wp_cuda_context_push_current);FN(wp_cuda_context_pop_current);
 FN(wp_cuda_stream_create);FN(wp_cuda_stream_destroy);FN(wp_cuda_stream_is_capturing);
 FN(wp_alloc_device_default);FN(wp_free_device_default);FN(wp_memcpy_h2d);FN(wp_memcpy_d2h);FN(wp_memcpy_d2d);FN(wp_memset_device);
 FN(wp_cuda_load_module);FN(wp_cuda_unload_module);FN(wp_cuda_get_kernel);FN(wp_cuda_launch_kernel);FN(wp_cuda_configure_kernel_shared_memory);
 FN(wp_apic_get_recording_state);FN(wp_apic_get_cuda_recording_state);FN(wp_apic_register_memory_region_by_ptr);
 FN(wp_apic_register_memory_region);
 FN(wp_apic_register_module);FN(wp_apic_register_kernel);
 FN(wp_cuda_context_get_stream);FN(wp_cuda_context_set_stream);
 FN(wp_array_scan_int_device);FN(wp_array_scan_int64_device);FN(wp_array_scan_float_device);FN(wp_array_scan_double_device);
 FN(wp_segmented_sort_pairs_int_device);FN(wp_segmented_sort_pairs_float_device);
 FN(wp_cuda_driver_version);FN(wp_cuda_toolkit_version);
 FN(wp_cuda_graph_insert_if_else);FN(wp_cuda_graph_insert_while);FN(wp_cuda_graph_set_condition);
 FN(wp_cuda_graph_pause_capture);FN(wp_cuda_graph_resume_capture);FN(wp_cuda_graph_check_conditional_body);
 FN(wp_cuda_graph_begin_capture);FN(wp_cuda_graph_end_capture);FN(wp_cuda_graph_create_exec);
 FN(wp_cuda_graph_launch);FN(wp_cuda_graph_destroy);FN(wp_cuda_graph_exec_destroy);
 FN(wp_apic_begin_branch);FN(wp_apic_end_branch);FN(wp_apic_free_branch_body);FN(wp_apic_record_conditional);
#undef FN
 ~Device(){
  if(poisoned)return; // Failed partial graphs may still reference the arena.
  if(context && (owned || !allocations.empty() || !modules.empty())){
   // Never invalidate live capture-owned resources from a foreign finalizer.
   // The explicit owning Context must outlive all graphs using this arena.
   if(wp_cuda_stream_is_capturing_fn && wp_cuda_stream_is_capturing_fn(stream)>0)return;
   if(wp_cuda_context_synchronize_fn)wp_cuda_context_synchronize_fn(context);
   for(auto a:allocations)wp_free_device_default_fn(context,a.pointer);
   for(auto m:modules)wp_cuda_unload_module_fn(context,m);
   if(owned){if(stream)wp_cuda_stream_destroy_fn(context,stream);wp_cuda_context_destroy_fn(context);}
  }
  if(library)closelib(library);
 }
 void check_thread(){require(thread==std::this_thread::get_id(),"dispatch handle used from a different OS thread");require(!poisoned,"dispatch context has a failed partial capture; discard the parent graph and context");}
 void outside_capture(){check_thread();require(!wp_apic_get_recording_state_fn()&&!wp_apic_get_cuda_recording_state_fn()&&wp_cuda_stream_is_capturing_fn(stream)==0,"operation is forbidden during active capture");}
 std::string vendor(const char* what){const char* message=wp_get_error_string_fn();return std::string(what)+(message&&*message?std::string(": ")+message:"");}
 void synchronize(){outside_capture();wp_cuda_context_synchronize_fn(context);require(wp_cuda_context_check_fn(context)==0,vendor("CUDA synchronization failed").c_str());}
};
struct Reader {
 const uint8_t* bytes;size_t size,cursor=0;
 uint32_t u32(){require(cursor<=size&&size-cursor>=4,"truncated launch transport");auto p=bytes+cursor;cursor+=4;return uint32_t(p[0])|(uint32_t(p[1])<<8)|(uint32_t(p[2])<<16)|(uint32_t(p[3])<<24);}
 uint64_t u64(){uint64_t a=u32(),b=u32();return a|(b<<32);}
 std::vector<uint8_t> blob(uint32_t n){require(n<=16777216&&cursor<=size&&n<=size-cursor,"invalid launch value blob size");std::vector<uint8_t> b(bytes+cursor,bytes+cursor+n);cursor+=n;return b;}
};
}
struct mrd_context{std::shared_ptr<Device> device;};
struct mrd_buffer{std::shared_ptr<Device> device;void* pointer;uint64_t size;};
struct mrd_kernel{std::shared_ptr<Device> device;void* forward;void* backward;std::string hash,key,module_name,binary,forward_name,backward_name;int fsmem,bsmem,block,dim;};
namespace {
template<class F> int checked(F f){error.clear();try{f();return 0;}catch(const std::exception& e){error=e.what();return -1;}catch(...){error="unknown native dispatch error";return -1;}}
void buffer_range(mrd_buffer* b,uint64_t offset,uint64_t size){require(b&&b->device,"null buffer");b->device->check_thread();require(offset<=b->size&&size<=b->size-offset,"buffer access is out of bounds");}
struct Packed {
 std::vector<uint8_t> value;uint32_t alignment=1;std::vector<APICLaunchPtrLocation> relocs;
};
void relocate(Packed& a,Device& d,APICState* state,mrd_buffer*const* buffers,size_t count,uint32_t slot,uint32_t kind,uint32_t index,uint64_t offset){
 require(slot<=a.value.size()&&sizeof(uint64_t)<=a.value.size()-slot,"relocation lies outside value blob");
 for(const auto& old:a.relocs)require(slot+8<=old.value_byte_offset||old.value_byte_offset+8<=slot,"overlapping value relocations");
 APICLaunchPtrLocation r{};r.value_byte_offset=slot;r.region_id=-1;r.region_offset=offset;r.kind=uint8_t(kind);uint64_t pointer=0;
 if(kind==APIC_RELOC_DATA_PTR){
  require(index<count,"buffer relocation index is invalid");auto b=buffers[index];buffer_range(b,offset,0);require(b->device.get()==&d,"buffer belongs to another dispatch context");
  pointer=reinterpret_cast<uint64_t>(b->pointer)+offset;
  if(state){uint32_t id=d.wp_apic_register_memory_region_by_ptr_fn(state,reinterpret_cast<uint64_t>(b->pointer),b->size,1);require(id>0&&id<=INT32_MAX,"APIC buffer registration failed");r.region_id=int32_t(id);}
 }else if(kind==APIC_RELOC_HANDLE){require(offset!=0,"handle relocation cannot be zero");pointer=offset;}
 else require(kind==APIC_RELOC_NULL&&offset==0,"unknown or nonzero null relocation");
 std::memcpy(a.value.data()+slot,&pointer,sizeof(pointer));a.relocs.push_back(r);
}
Packed argument(Reader& r,Device& d,APICState* state,mrd_buffer*const* buffers,size_t count){
 Packed a;uint32_t kind=r.u32();
 if(kind==0){
  a.alignment=r.u32();require(a.alignment&&a.alignment<=256&&(a.alignment&(a.alignment-1))==0,"value alignment must be a power of two up to 256");
  a.value=r.blob(r.u32());require(!a.value.empty(),"empty kernel parameter is unsupported");uint32_t n=r.u32();require(n<=65535,"too many parameter relocations");
  for(uint32_t i=0;i<n;++i){uint32_t slot=r.u32(),type=r.u32(),index=r.u32();uint64_t off=r.u64();relocate(a,d,state,buffers,count,slot,type,index,off);}
 }else{
  require(kind==1,"unknown kernel argument transport kind");uint32_t ndim=r.u32();require(ndim>=1&&ndim<=4,"array rank must be 1 to 4");
  apic_array_t desc{};desc.ndim=uint16_t(ndim);uint64_t extent=0;bool empty=false;
  for(uint32_t i=0;i<ndim;++i){uint32_t shape=r.u32();require(shape<=INT32_MAX,"array dimension exceeds int32");desc.shape[i]=int(shape);empty=empty||shape==0;}
  for(uint32_t i=0;i<ndim;++i){uint32_t stride=r.u32();require(stride<=INT32_MAX,"negative or oversized array strides are unsupported");desc.strides[i]=int(stride);uint64_t add=desc.shape[i]?uint64_t(desc.shape[i]-1)*stride:0;require(add<=UINT64_MAX-extent,"array span overflows");extent+=add;}
  uint32_t element=r.u32();require(element>0&&element<=1048576,"invalid array element byte width");if(!empty){require(element<=UINT64_MAX-extent,"array extent overflows");extent+=element;}else extent=0;
  uint32_t data=r.u32();uint64_t off=r.u64();uint32_t grad=r.u32();uint64_t goff=r.u64();
  a.alignment=alignof(apic_array_t);a.value.resize(sizeof(desc));std::memcpy(a.value.data(),&desc,sizeof(desc));
  require(data<count,"array data buffer is absent");buffer_range(buffers[data],off,extent);relocate(a,d,state,buffers,count,offsetof(apic_array_t,data),APIC_RELOC_DATA_PTR,data,off);
  if(grad==UINT32_MAX)relocate(a,d,state,buffers,count,offsetof(apic_array_t,grad),APIC_RELOC_NULL,0,0);
  else{require(grad<count,"array gradient buffer is absent");buffer_range(buffers[grad],goff,extent);relocate(a,d,state,buffers,count,offsetof(apic_array_t,grad),APIC_RELOC_DATA_PTR,grad,goff);}
 }
 return a;
}
template<int N> std::vector<uint8_t> bounds(const int* shape,uint64_t size){wp::launch_bounds_t<N> b{};for(int i=0;i<N;++i)b.shape[i]=shape[i];b.size=size;b.coord_mult=1;std::vector<uint8_t> result(sizeof(b));std::memcpy(result.data(),&b,sizeof(b));return result;}
}
extern "C" MRD_API int mrd_abi(){return 3;}
extern "C" MRD_API const char* mrd_error(){return error.c_str();}
extern "C" MRD_API mrd_context* mrd_open(const char* path,uint64_t context,uint64_t stream,int arch,int ordinal){mrd_context* result=nullptr;checked([&]{
 require(path&&*path,"explicit Warp library path required");auto d=std::make_shared<Device>();d->library=openlib(path);require(d->library,"cannot load explicit Warp library");
#define LOAD(name) d->name##_fn=reinterpret_cast<decltype(&name)>(symbol(d->library,#name))
 LOAD(wp_version);LOAD(wp_init);LOAD(wp_get_error_string);LOAD(wp_is_cuda_enabled);
 LOAD(wp_cuda_context_create);LOAD(wp_cuda_context_destroy);LOAD(wp_cuda_context_synchronize);LOAD(wp_cuda_context_check);
 LOAD(wp_cuda_context_get_device_ordinal);LOAD(wp_cuda_device_get_arch);LOAD(wp_cuda_context_push_current);LOAD(wp_cuda_context_pop_current);
 LOAD(wp_cuda_stream_create);LOAD(wp_cuda_stream_destroy);LOAD(wp_cuda_stream_is_capturing);
 LOAD(wp_alloc_device_default);LOAD(wp_free_device_default);LOAD(wp_memcpy_h2d);LOAD(wp_memcpy_d2h);LOAD(wp_memcpy_d2d);LOAD(wp_memset_device);
 LOAD(wp_cuda_load_module);LOAD(wp_cuda_unload_module);LOAD(wp_cuda_get_kernel);LOAD(wp_cuda_launch_kernel);LOAD(wp_cuda_configure_kernel_shared_memory);
 LOAD(wp_apic_get_recording_state);LOAD(wp_apic_get_cuda_recording_state);LOAD(wp_apic_register_memory_region_by_ptr);LOAD(wp_apic_register_module);LOAD(wp_apic_register_kernel);
 LOAD(wp_apic_register_memory_region);
 LOAD(wp_cuda_context_get_stream);LOAD(wp_cuda_context_set_stream);
 LOAD(wp_array_scan_int_device);LOAD(wp_array_scan_int64_device);LOAD(wp_array_scan_float_device);LOAD(wp_array_scan_double_device);
 LOAD(wp_segmented_sort_pairs_int_device);LOAD(wp_segmented_sort_pairs_float_device);
 LOAD(wp_cuda_driver_version);LOAD(wp_cuda_toolkit_version);
 LOAD(wp_cuda_graph_insert_if_else);LOAD(wp_cuda_graph_insert_while);LOAD(wp_cuda_graph_set_condition);
 LOAD(wp_cuda_graph_pause_capture);LOAD(wp_cuda_graph_resume_capture);LOAD(wp_cuda_graph_check_conditional_body);
 LOAD(wp_cuda_graph_begin_capture);LOAD(wp_cuda_graph_end_capture);LOAD(wp_cuda_graph_create_exec);
 LOAD(wp_cuda_graph_launch);LOAD(wp_cuda_graph_destroy);LOAD(wp_cuda_graph_exec_destroy);
 LOAD(wp_apic_begin_branch);LOAD(wp_apic_end_branch);LOAD(wp_apic_free_branch_body);LOAD(wp_apic_record_conditional);
#undef LOAD
 require(std::strcmp(d->wp_version_fn(),"1.17.0")==0,"Warp version must be exactly 1.17.0");require(d->wp_is_cuda_enabled_fn(),"Warp library has no CUDA backend");
 if(ordinal>=0){require(!context&&!stream,"owned creation does not accept borrowed context/stream");require(d->wp_init_fn("1.17.0")==0,"Warp initialization failed");d->context=d->wp_cuda_context_create_fn(ordinal);require(d->context,"CUDA context creation failed");d->owned=true;d->stream=d->wp_cuda_stream_create_fn(d->context,0);require(d->stream,"CUDA stream creation failed");d->arch=d->wp_cuda_device_get_arch_fn(ordinal);}
 else{require(context&&arch>=0,"borrow requires live context and nonnegative architecture");d->context=reinterpret_cast<void*>(context);d->stream=reinterpret_cast<void*>(stream);d->arch=arch?arch:d->wp_cuda_device_get_arch_fn(d->wp_cuda_context_get_device_ordinal_fn(d->context));require(d->arch>0,"borrowed context has no valid CUDA architecture");}
 result=new mrd_context{d};
 });return result;}
extern "C" MRD_API void mrd_context_release(mrd_context* c){delete c;}
extern "C" MRD_API mrd_context* mrd_context_retain(mrd_context* c){mrd_context* result=nullptr;checked([&]{require(c&&c->device,"null context");c->device->check_thread();result=new mrd_context{c->device};});return result;}
extern "C" MRD_API uint64_t mrd_context_pointer(mrd_context* c){return c?reinterpret_cast<uint64_t>(c->device->context):0;}
extern "C" MRD_API uint64_t mrd_stream_pointer(mrd_context* c){return c?reinterpret_cast<uint64_t>(c->device->stream):0;}
extern "C" MRD_API int mrd_architecture(mrd_context* c){return c?c->device->arch:0;}
extern "C" MRD_API int mrd_synchronize(mrd_context* c){return checked([&]{require(c,"null context");c->device->synchronize();});}
namespace {
void expected_capture(Device& d,uint64_t expected){d.check_thread();require(!d.wp_apic_get_recording_state_fn(),"device operation cannot run under CPU APIC capture");require(reinterpret_cast<uint64_t>(d.wp_apic_get_cuda_recording_state_fn())==expected,"active APIC recording differs from explicit operation state");if(!expected)require(d.wp_cuda_stream_is_capturing_fn(d.stream)==0,"untracked CUDA capture requires an explicit APIC recording state");}
void pointer_span(uint64_t pointer,uint64_t size){require(pointer&&size<=SIZE_MAX&&pointer<=UINT64_MAX-size,"invalid external device pointer span");}
}
extern "C" MRD_API int mrd_copy_external(mrd_context* c,uint64_t destination,uint64_t source,uint64_t size,uint64_t state){return checked([&]{require(c,"null context");auto d=c->device;expected_capture(*d,state);pointer_span(destination,size);pointer_span(source,size);require(size==0||destination==source||destination+size<=source||source+size<=destination,"overlapping external device copy");require(d->wp_memcpy_d2d_fn(d->context,reinterpret_cast<void*>(destination),reinterpret_cast<void*>(source),size,d->stream),d->vendor("external device copy failed").c_str());});}
extern "C" MRD_API int mrd_zero_external(mrd_context* c,uint64_t pointer,uint64_t size,uint64_t state){return checked([&]{require(c,"null context");auto d=c->device;expected_capture(*d,state);pointer_span(pointer,size);require(d->wp_memset_device_fn(d->context,reinterpret_cast<void*>(pointer),0,size,d->stream),d->vendor("external device zero failed").c_str());});}
extern "C" MRD_API mrd_buffer* mrd_allocate(mrd_context* c,uint64_t size){mrd_buffer* result=nullptr;checked([&]{require(c&&size>0&&size<=SIZE_MAX,"invalid allocation size");auto d=c->device;d->outside_capture();void* p=d->wp_alloc_device_default_fn(d->context,size,"moonrobo-native-dispatch");require(p,d->vendor("CUDA allocation failed").c_str());d->allocations.push_back({p,size});result=new mrd_buffer{d,p,size};});return result;}
extern "C" MRD_API void mrd_buffer_release(mrd_buffer* b){delete b;}
extern "C" MRD_API uint64_t mrd_buffer_pointer(mrd_buffer* b){return b?reinterpret_cast<uint64_t>(b->pointer):0;}
extern "C" MRD_API uint64_t mrd_buffer_size(mrd_buffer* b){return b?b->size:0;}
extern "C" MRD_API int mrd_write(mrd_buffer* b,uint64_t offset,const uint8_t* bytes,size_t size){return checked([&]{buffer_range(b,offset,size);b->device->outside_capture();require(bytes||!size,"null upload bytes");bool ok=b->device->wp_memcpy_h2d_fn(b->device->context,static_cast<uint8_t*>(b->pointer)+offset,const_cast<uint8_t*>(bytes),size,b->device->stream);b->device->synchronize();require(ok,b->device->vendor("upload failed").c_str());});}
extern "C" MRD_API int mrd_read(mrd_buffer* b,uint64_t offset,uint8_t* bytes,size_t size){return checked([&]{buffer_range(b,offset,size);b->device->outside_capture();require(bytes||!size,"null download bytes");bool ok=b->device->wp_memcpy_d2h_fn(b->device->context,bytes,static_cast<uint8_t*>(b->pointer)+offset,size,b->device->stream);b->device->synchronize();require(ok,b->device->vendor("download failed").c_str());});}
extern "C" MRD_API mrd_kernel* mrd_load(mrd_context* c,const char* path,const char* name,const char* hash,const char* key,const char* forward,const char* backward,int fsmem,int bsmem,int block,int dim){mrd_kernel* result=nullptr;checked([&]{
 require(c&&path&&*path&&name&&*name&&hash&&*hash&&key&&*key&&forward&&*forward&&backward,"kernel identity fields missing");require(fsmem>=0&&bsmem>=0&&block>0&&block<=1024&&dim>=1&&dim<=4,"invalid kernel launch metadata or compiled dimension");auto d=c->device;d->outside_capture();
 void* module=d->wp_cuda_load_module_fn(d->context,path);require(module,d->vendor("module load failed").c_str());d->modules.push_back(module);
 void* f=d->wp_cuda_get_kernel_fn(d->context,module,forward);require(f,d->vendor("forward kernel lookup failed").c_str());void* b=*backward?d->wp_cuda_get_kernel_fn(d->context,module,backward):nullptr;require(!*backward||b,d->vendor("backward kernel lookup failed").c_str());
 d->wp_cuda_context_push_current_fn(d->context);bool ok=true;if(fsmem)ok=d->wp_cuda_configure_kernel_shared_memory_fn(f,fsmem);if(ok&&b&&bsmem)ok=d->wp_cuda_configure_kernel_shared_memory_fn(b,bsmem);d->wp_cuda_context_pop_current_fn();require(ok,d->vendor("dynamic shared memory configuration failed").c_str());
 std::string filename(path);auto slash=filename.find_last_of("/\\");if(slash!=std::string::npos)filename=filename.substr(slash+1);require(!filename.empty(),"module filename is empty");result=new mrd_kernel{d,f,b,hash,key,name,filename,forward,backward,fsmem,bsmem,block,dim};
 });return result;}
extern "C" MRD_API void mrd_kernel_release(mrd_kernel* k){delete k;}
extern "C" MRD_API int mrd_launch(mrd_kernel* kernel,const uint8_t* wire,size_t size,mrd_buffer*const* buffers,size_t count,uint64_t expected_state){return checked([&]{
 require(kernel&&wire&&size<=67108864,"invalid kernel or launch transport");auto d=kernel->device;expected_capture(*d,expected_state);APICState* state=d->wp_apic_get_cuda_recording_state_fn();
 Reader r{wire,size};require(r.u32()==0x314c524d,"bad launch transport magic");uint32_t ndim=r.u32();require(ndim>=1&&ndim<=4&&int(ndim)==kernel->dim,"launch rank differs from compiled kernel dimension");int shape[4]={};uint64_t total=1;for(uint32_t i=0;i<ndim;++i){uint32_t n=r.u32();require(n<=INT32_MAX,"launch shape exceeds int32");shape[i]=int(n);require(n==0||total<=UINT64_MAX/n,"launch size overflows");total*=n;}
 uint32_t forward=r.u32(),max_blocks=r.u32(),grid_stride=r.u32(),cluster=r.u32(),n=r.u32(),adj=r.u32();require(forward<=1&&grid_stride<=1&&max_blocks<=INT32_MAX&&cluster>=1&&cluster<=255,"invalid launch options");require(n<=65535&&((forward&&adj==0)||(!forward&&adj==n)),"adjoint arguments must match forward parameter count");require(total<=SIZE_MAX-uint64_t(kernel->block),"launch size exceeds native bounds");
 std::vector<Packed> values;values.reserve(size_t(n)+adj);for(uint32_t i=0;i<n+adj;++i)values.push_back(argument(r,*d,state,buffers,count));require(r.cursor==size,"trailing launch transport bytes");
 std::vector<uint8_t> bound;switch(ndim){case 1:bound=bounds<1>(shape,total);break;case 2:bound=bounds<2>(shape,total);break;case 3:bound=bounds<3>(shape,total);break;default:bound=bounds<4>(shape,total);}
 std::vector<APICLaunchParamRecord> records(n+adj);std::vector<APICLaunchPtrLocation> relocs;std::vector<uint8_t> data;std::vector<void*> args;args.push_back(bound.data());
 for(uint32_t i=0;i<n+adj;++i){auto& a=values[i];require(data.size()<=UINT32_MAX-a.alignment,"launch value data overflow");size_t pad=(-data.size())&(a.alignment-1);data.insert(data.end(),pad,0);require(a.value.size()<=UINT32_MAX-data.size(),"launch value data exceeds APIC u32");auto& rec=records[i];rec.param_index=uint16_t(i+1);require(i<65535,"combined forward/adjoint parameter index exceeds u16");rec.num_relocs=uint16_t(a.relocs.size());rec.value_offset=uint32_t(data.size());rec.value_size=uint32_t(a.value.size());rec.value_align=a.alignment;data.insert(data.end(),a.value.begin(),a.value.end());relocs.insert(relocs.end(),a.relocs.begin(),a.relocs.end());args.push_back(a.value.data());}
 require(relocs.size()<=UINT32_MAX,"too many launch relocations");APICLaunchInfo info{};info.kernel_key=kernel->key.c_str();info.module_hash=kernel->hash.c_str();info.is_forward=uint8_t(forward);info.params=records.data();info.num_params=int32_t(n);info.kernel_dim=kernel->dim;info.value_data_size=uint32_t(data.size());info.value_data=data.data();info.adj_params=adj?records.data()+n:nullptr;info.num_relocs=uint32_t(relocs.size());info.relocs=relocs.data();
 void* entry=forward?kernel->forward:kernel->backward;require(entry,"requested backward kernel is absent");
 if(state){d->wp_apic_register_module_fn(state,kernel->hash.c_str(),kernel->module_name.c_str(),kernel->binary.c_str(),d->arch);d->wp_apic_register_kernel_fn(state,kernel->key.c_str(),kernel->hash.c_str(),kernel->forward_name.c_str(),kernel->backward_name.c_str(),kernel->fsmem,kernel->bsmem,kernel->block);}
 size_t status=d->wp_cuda_launch_kernel_fn(d->context,entry,total,int(max_blocks),kernel->block,int(grid_stride),int(cluster),forward?kernel->fsmem:kernel->bsmem,args.data(),d->stream,state?&info:nullptr);require(status==0,d->vendor("CUDA kernel launch failed").c_str());
 });}

#include "primitives.inc"

extern "C" MRD_API int mrd_suggested_block_size(mrd_kernel* kernel,int shared_memory_bytes,int* block_size,int* min_grid_size){
 return checked([&]{
  require(kernel&&kernel->device&&kernel->forward,"null forward kernel for occupancy query");
  require(shared_memory_bytes>=0&&block_size&&min_grid_size,"invalid occupancy shared memory or output pointers");
  auto d=kernel->device;d->outside_capture();
  auto query=reinterpret_cast<decltype(&wp_cuda_get_suggested_block_size)>(symbol(d->library,"wp_cuda_get_suggested_block_size"));
  *block_size=0;*min_grid_size=0;
  require(query(d->context,kernel->forward,shared_memory_bytes,block_size,min_grid_size),d->vendor("Warp occupancy query failed").c_str());
  require(*block_size>0&&*block_size<=1024&&*min_grid_size>0,"native occupancy query returned invalid launch dimensions");
 });
}
