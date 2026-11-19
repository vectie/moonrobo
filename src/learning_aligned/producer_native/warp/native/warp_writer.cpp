// Python-free, dynamically loaded Warp 1.17 authoring. Compile against the
// actual pinned Warp native headers; no fabricated vendor declarations.
#include "warp_writer.h"
#include "warp.h"
#include "apic.h"
#include <climits>
#include <cstring>
#include <cstdlib>
#include <limits>
#include <memory>
#include <stdexcept>
#include <string>
#include <thread>
#include <unordered_map>
#include <vector>
#ifdef _WIN32
# include <windows.h>
#else
# include <dlfcn.h>
# include <limits.h>
#endif
static_assert(APIC_FORMAT_VERSION == 15, "Warp 1.17 APIC format 15 is required");
static_assert(sizeof(void*) == 8, "authoring requires a 64-bit host");
namespace {
thread_local std::string opening_error;
void* open_library(const char* path) {
#ifdef _WIN32
 return reinterpret_cast<void*>(LoadLibraryA(path));
#else
 return dlopen(path, RTLD_NOW | RTLD_LOCAL);
#endif
}
void close_library(void* handle) {
#ifdef _WIN32
 FreeLibrary(reinterpret_cast<HMODULE>(handle));
#else
 dlclose(handle);
#endif
}
void* symbol(void* library,const char* name) {
#ifdef _WIN32
 auto p = reinterpret_cast<void*>(GetProcAddress(reinterpret_cast<HMODULE>(library),name));
#else
 auto p = dlsym(library,name);
#endif
 if(!p) throw std::runtime_error(std::string("missing pinned Warp symbol: ")+name);
 return p;
}
void require(bool condition,const char* text) {if(!condition) throw std::runtime_error(text);}
void valid_region(uint32_t id) {require(id>0 && id<=INT32_MAX,"invalid APIC region id");}
void size_ok(uint64_t n) {require(n<=SIZE_MAX,"byte capacity exceeds host size_t");}
struct HostRegion {std::vector<uint8_t> bytes;};
}
struct mrw_writer {
 void* library=nullptr;
 APICState* state=nullptr;
 void* context=nullptr;
 void* stream=nullptr;
 int arch=0;
 bool owned=false;
 bool cpu=true;
 int phase=2; // 0 created, 1 recording, 2 finished / borrowed finished state
 std::thread::id thread=std::this_thread::get_id();
 std::string error,version,path;
 std::unordered_map<uint32_t,std::unique_ptr<HostRegion>> hosts;
 std::unordered_map<uint32_t,uint64_t> capacities;
#define MRW_FN(name) decltype(&name) name##_fn=nullptr
 MRW_FN(wp_version); MRW_FN(wp_init); MRW_FN(wp_get_error_string);
 MRW_FN(wp_is_cuda_enabled); MRW_FN(wp_memcpy_d2h); MRW_FN(wp_cuda_context_synchronize); MRW_FN(wp_cuda_context_check);
 MRW_FN(wp_memset_host); MRW_FN(wp_memcpy_h2h);
 MRW_FN(wp_apic_create_state); MRW_FN(wp_apic_destroy_state);
 MRW_FN(wp_apic_begin_recording); MRW_FN(wp_apic_end_recording);
 MRW_FN(wp_apic_get_recording_state); MRW_FN(wp_apic_get_cuda_recording_state);
 MRW_FN(wp_apic_get_operation_count); MRW_FN(wp_apic_register_memory_region_by_ptr);
 MRW_FN(wp_apic_register_memory_region); MRW_FN(wp_apic_register_module);
 MRW_FN(wp_apic_register_kernel); MRW_FN(wp_apic_register_binding);
 MRW_FN(wp_apic_register_ptr_location); MRW_FN(wp_apic_register_mesh); MRW_FN(wp_apic_state_save);
#undef MRW_FN
 ~mrw_writer(){
  if(owned && state) wp_apic_destroy_state_fn(state);
  if(library)close_library(library);
 }
 void owner_thread(){require(thread==std::this_thread::get_id(),"APIC writer used from a different OS thread");}
 void idle(){owner_thread();require(state && phase!=1,"metadata/save requires finished or not-yet-started recording");}
 void active(){owner_thread();require(owned && phase==1,"operation requires this writer's active owned recording");
  require((cpu?wp_apic_get_recording_state_fn():wp_apic_get_cuda_recording_state_fn())==state,"active Warp capture differs from owned state");}
 std::string vendor_error(const char* what){const char* p=wp_get_error_string_fn();return std::string(what)+(p&&*p?std::string(": ")+p:"");}
};
namespace {
template<class F> int checked(mrw_writer* w,F f){if(!w){opening_error="null Warp writer";return -1;}w->error.clear();try{f();return 0;}catch(const std::exception& e){w->error=e.what();return -1;}catch(...){w->error="unknown native Warp authoring failure";return -1;}}
std::unique_ptr<mrw_writer> load(const char* path,uint64_t context,uint64_t stream,int arch){
 require(path && *path,"Warp library path is empty");
 require(arch>=0 && ((arch==0)==(context==0)),"CPU requires arch/context zero; CUDA requires a positive arch and live context");
 auto w=std::make_unique<mrw_writer>();
 w->library=open_library(path);require(w->library,"cannot open supplied Warp library");
#define MRW_LOAD(name) w->name##_fn=reinterpret_cast<decltype(&name)>(symbol(w->library,#name))
 MRW_LOAD(wp_version);MRW_LOAD(wp_init);MRW_LOAD(wp_get_error_string);
 MRW_LOAD(wp_is_cuda_enabled);MRW_LOAD(wp_memcpy_d2h);MRW_LOAD(wp_cuda_context_synchronize);MRW_LOAD(wp_cuda_context_check);
 MRW_LOAD(wp_memset_host);MRW_LOAD(wp_memcpy_h2h);
 MRW_LOAD(wp_apic_create_state);MRW_LOAD(wp_apic_destroy_state);MRW_LOAD(wp_apic_begin_recording);MRW_LOAD(wp_apic_end_recording);
 MRW_LOAD(wp_apic_get_recording_state);MRW_LOAD(wp_apic_get_cuda_recording_state);MRW_LOAD(wp_apic_get_operation_count);
 MRW_LOAD(wp_apic_register_memory_region_by_ptr);MRW_LOAD(wp_apic_register_memory_region);
 MRW_LOAD(wp_apic_register_module);MRW_LOAD(wp_apic_register_kernel);MRW_LOAD(wp_apic_register_binding);
 MRW_LOAD(wp_apic_register_ptr_location);MRW_LOAD(wp_apic_register_mesh);MRW_LOAD(wp_apic_state_save);
#undef MRW_LOAD
 const char* version=w->wp_version_fn();require(version && std::strcmp(version,"1.17.0")==0,"native Warp version must be exactly 1.17.0");
 w->version=version;w->path=path;w->arch=arch;w->context=reinterpret_cast<void*>(context);w->stream=reinterpret_cast<void*>(stream);w->cpu=arch==0;
 if(!w->cpu)require(w->wp_is_cuda_enabled_fn()!=0,"supplied Warp library has no CUDA support");
 return w;
}
void range(const std::vector<uint8_t>& bytes,uint64_t offset,uint64_t count){require(offset<=bytes.size() && count<=bytes.size()-offset,"host region range is out of bounds");}
HostRegion& host(mrw_writer* w,uint32_t id){auto i=w->hosts.find(id);require(i!=w->hosts.end(),"region is not owned host storage");return *i->second;}
}
extern "C" MRW_API int mrw_api_version(){return 2;}
extern "C" MRW_API const char* mrw_error(mrw_writer* w){return w?w->error.c_str():opening_error.c_str();}
extern "C" MRW_API mrw_writer* mrw_borrow(const char* path,uint64_t state,uint64_t context,uint64_t stream,int arch){
 opening_error.clear();try{require(state!=0,"borrowed APIC state is null");auto w=load(path,context,stream,arch);
  require(!w->wp_apic_get_recording_state_fn() && !w->wp_apic_get_cuda_recording_state_fn(),"cannot borrow while recording is active on this thread");
  w->state=reinterpret_cast<APICState*>(state);return w.release();
 }catch(const std::exception& e){opening_error=e.what();return nullptr;}catch(...){opening_error="cannot borrow Warp state";return nullptr;}
}
extern "C" MRW_API mrw_writer* mrw_create(const char* path,int cpu,uint64_t context,uint64_t stream,int arch){
 opening_error.clear();try{require(cpu==0 || cpu==1,"cpu flag must be boolean");require((cpu!=0)==(arch==0),"device class differs from target architecture");auto w=load(path,context,stream,arch);
  require(w->wp_init_fn("1.17.0")==0,"Warp initialization/version check failed");
  w->state=w->wp_apic_create_state_fn();require(w->state,"Warp state allocation failed");w->owned=true;w->phase=0;return w.release();
 }catch(const std::exception& e){opening_error=e.what();return nullptr;}catch(...){opening_error="cannot create Warp state";return nullptr;}
}
extern "C" MRW_API int mrw_release(mrw_writer* w){if(!w)return 0;
 if(w->phase==1){if(checked(w,[&]{w->active();w->wp_apic_end_recording_fn(w->state);w->phase=2;})!=0)return -1;}
 delete w;return 0;
}
extern "C" MRW_API const char* mrw_version(mrw_writer* w){return w?w->version.c_str():"";}
extern "C" MRW_API const char* mrw_library(mrw_writer* w){return w?w->path.c_str():"";}
extern "C" MRW_API uint64_t mrw_state_pointer(mrw_writer* w){uint64_t result=0;checked(w,[&]{w->owner_thread();require(w->state,"APIC state is null");result=reinterpret_cast<uint64_t>(w->state);});return result;}
extern "C" MRW_API int mrw_begin(mrw_writer* w){return checked(w,[&]{w->owner_thread();require(w->owned && w->phase==0,"owned capture can begin exactly once");require(!w->wp_apic_get_recording_state_fn()&&!w->wp_apic_get_cuda_recording_state_fn(),"nested Warp capture is not supported");w->wp_apic_begin_recording_fn(w->state,w->cpu?1:0);w->phase=1;w->active();});}
extern "C" MRW_API int mrw_end(mrw_writer* w){return checked(w,[&]{w->active();w->wp_apic_end_recording_fn(w->state);w->phase=2;});}
extern "C" MRW_API uint32_t mrw_operation_count(mrw_writer* w){uint32_t result=0;checked(w,[&]{w->owner_thread();result=w->wp_apic_get_operation_count_fn(w->state);});return result;}
extern "C" MRW_API uint32_t mrw_register_region(mrw_writer* w,uint64_t pointer,uint64_t capacity,uint32_t element){uint32_t result=0;checked(w,[&]{w->idle();size_ok(capacity);require(pointer && capacity && element && capacity%element==0,"invalid live region pointer, size or element width");require(pointer<=UINT64_MAX-capacity,"region pointer span overflows");result=w->wp_apic_register_memory_region_by_ptr_fn(w->state,pointer,capacity,element);valid_region(result);w->capacities[result]=capacity;});return result;}
extern "C" MRW_API int mrw_snapshot_region(mrw_writer* w,uint32_t region,uint64_t pointer,uint64_t capacity,uint32_t element,int transient){return checked(w,[&]{w->idle();valid_region(region);size_ok(capacity);require(element && capacity%element==0,"invalid snapshot element width");require(transient==0 || transient==1,"transient flag must be boolean");
 if(transient){require(!w->cpu,"only CUDA graph-scoped regions may be transient");w->wp_apic_register_memory_region_fn(w->state,region,capacity,element,nullptr);}
 else{require(pointer || capacity==0,"non-transient snapshot pointer is null");require(pointer<=UINT64_MAX-capacity,"snapshot pointer span overflows");
  if(w->cpu){w->wp_apic_register_memory_region_fn(w->state,region,capacity,element,reinterpret_cast<const void*>(pointer));}
  else{std::vector<uint8_t> bytes(static_cast<size_t>(capacity));bool ok=capacity==0 || w->wp_memcpy_d2h_fn(w->context,bytes.data(),reinterpret_cast<void*>(pointer),capacity,w->stream);
   w->wp_cuda_context_synchronize_fn(w->context);uint64_t error=w->wp_cuda_context_check_fn(w->context);
   require(ok && error==0,w->vendor_error("CUDA region snapshot failed").c_str());w->wp_apic_register_memory_region_fn(w->state,region,capacity,element,bytes.data());}}
 w->capacities[region]=capacity;
});}
extern "C" MRW_API int mrw_register_module(mrw_writer* w,const char* hash,const char* name,const char* binary){return checked(w,[&]{w->idle();require(hash&&*hash&&name&&*name&&binary&&*binary,"module fields cannot be empty");require(!std::strchr(binary,'/')&&!std::strchr(binary,'\\')&&std::strcmp(binary,".")&&std::strcmp(binary,".."),"module binary must be a basename");w->wp_apic_register_module_fn(w->state,hash,name,binary,w->arch);});}
extern "C" MRW_API int mrw_register_kernel(mrw_writer* w,const char* key,const char* hash,const char* forward,const char* backward,int fsmem,int bsmem,int block){return checked(w,[&]{w->idle();require(key&&*key&&hash&&*hash&&forward&&backward,"invalid kernel identity");require(fsmem>=0&&bsmem>=0&&block>0,"invalid kernel launch metadata");w->wp_apic_register_kernel_fn(w->state,key,hash,forward,backward,fsmem,bsmem,block);});}
extern "C" MRW_API int mrw_register_binding(mrw_writer* w,const char* name,uint32_t id){return checked(w,[&]{w->idle();valid_region(id);require(name&&*name,"binding name is empty");w->wp_apic_register_binding_fn(w->state,name,id);});}
extern "C" MRW_API int mrw_register_pointer_location(mrw_writer* w,uint32_t id,uint64_t offset,uint64_t stride){return checked(w,[&]{
 w->idle();valid_region(id);
 require(stride==0 || stride>=sizeof(void*),"pointer relocation stride must be zero or hold one pointer");
 auto i=w->capacities.find(id);
 require(i!=w->capacities.end(),"register or snapshot the region before adding pointer relocation");
 const uint64_t capacity=i->second;
 require(offset<=capacity && sizeof(void*)<=capacity-offset,"pointer relocation is outside its region");
 // Upstream replay loops while off + sizeof(uint64_t) <= capacity, then adds
 // stride. Every live offset is <= capacity - sizeof(uint64_t). This bound
 // keeps both that increment and the following loop condition from wrapping.
 require(stride==0 || stride<=UINT64_MAX-capacity,"pointer relocation stride can overflow replay iteration");
 w->wp_apic_register_ptr_location_fn(w->state,id,offset,stride);
});}
extern "C" MRW_API int mrw_register_mesh(mrw_writer* w,uint64_t id){return checked(w,[&]{w->idle();require(id,"mesh handle is null");require(w->wp_apic_register_mesh_fn(w->state,id),w->vendor_error("mesh snapshot registration failed").c_str());});}
extern "C" MRW_API int mrw_save(mrw_writer* w,const char* path){return checked(w,[&]{w->idle();require(w->phase==2,"end owned recording before saving");require(path&&std::strlen(path)>4&&std::strcmp(path+std::strlen(path)-4,".wrp")==0,"save path must end .wrp");require(w->wp_apic_get_operation_count_fn(w->state)>0,"refusing to save an empty capture");require(w->wp_apic_state_save_fn(w->state,path,w->arch,w->context),w->vendor_error("APIC state save failed").c_str());});}
extern "C" MRW_API uint32_t mrw_host_region(mrw_writer* w,const uint8_t* bytes,uint64_t count,uint32_t element){uint32_t id=0;checked(w,[&]{w->idle();require(w->owned&&w->cpu&&w->phase==0,"host storage must be allocated before owned CPU recording");require(count&&bytes&&element&&count%element==0,"invalid host storage");size_ok(count);auto h=std::make_unique<HostRegion>();h->bytes.assign(bytes,bytes+count);auto pointer=reinterpret_cast<uint64_t>(h->bytes.data());id=w->wp_apic_register_memory_region_by_ptr_fn(w->state,pointer,count,element);valid_region(id);w->wp_apic_register_memory_region_fn(w->state,id,count,element,h->bytes.data());w->capacities[id]=count;w->hosts[id]=std::move(h);});return id;}
extern "C" MRW_API uint64_t mrw_host_pointer(mrw_writer* w,uint32_t id){uint64_t result=0;checked(w,[&]{w->owner_thread();result=reinterpret_cast<uint64_t>(host(w,id).bytes.data());});return result;}
extern "C" MRW_API int mrw_host_memset(mrw_writer* w,uint32_t id,uint64_t offset,int value,uint64_t count){return checked(w,[&]{w->active();require(w->cpu,"host operation cannot record in a CUDA capture");auto& bytes=host(w,id).bytes;range(bytes,offset,count);require(w->wp_memset_host_fn(bytes.data()+offset,value,count),w->vendor_error("host memset failed").c_str());});}
extern "C" MRW_API int mrw_host_copy(mrw_writer* w,uint32_t dst,uint64_t doffset,uint32_t src,uint64_t soffset,uint64_t count){return checked(w,[&]{w->active();require(w->cpu,"host operation cannot record in a CUDA capture");auto& d=host(w,dst).bytes;auto& s=host(w,src).bytes;range(d,doffset,count);range(s,soffset,count);if(dst==src && count)require(doffset+count<=soffset || soffset+count<=doffset,"overlapping memcpy is not supported");require(w->wp_memcpy_h2h_fn(d.data()+doffset,s.data()+soffset,count),w->vendor_error("host memcpy failed").c_str());});}
