#include "hull_api.h"
#include <libqhull_r/qhull_ra.h>
#include <algorithm>
#include <array>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <new>
#include <stdexcept>
#include <string>
#include <vector>
#include <dlfcn.h>
namespace {
struct Hull {void* lib=nullptr;std::string error;std::vector<uint8_t> points,indices;bool joggled=false;~Hull(){if(lib)dlclose(lib);}};
template<typename T>T sym(Hull& h,const char* name){auto p=dlsym(h.lib,name);if(!p)throw std::runtime_error(std::string("missing reentrant Qhull symbol: ")+name);return reinterpret_cast<T>(p);}
uint64_t u64(const uint8_t* p){uint64_t value=0;for(int i=0;i<8;++i)value|=uint64_t(p[i])<<(8*i);return value;}
void word(std::vector<uint8_t>& out,uint32_t value){for(int i=0;i<4;++i)out.push_back(uint8_t(value>>(i*8)));}
}
int mr_convex_hull_abi(){return 1;}
void* mr_convex_hull_open(const char* library,const uint8_t* data,size_t bytes,int maximum){
 auto* h=new(std::nothrow) Hull;if(!h)return nullptr;
 try {
  if(!library||!*library||!data||bytes<96||bytes%24||bytes>48000000||(maximum!=0&&maximum<4))throw std::runtime_error("full-rank hull needs explicit Qhull library, 4..2000000 points and max_vertices=0 or >=4");
  std::vector<double> original(bytes/8);for(size_t i=0;i<original.size();++i){uint64_t bits=u64(data+i*8);std::memcpy(&original[i],&bits,8);if(!std::isfinite(original[i]))throw std::runtime_error("nonfinite hull point");}
  h->lib=dlopen(library,RTLD_NOW|RTLD_LOCAL);if(!h->lib)throw std::runtime_error("cannot load explicit reentrant Qhull library");
  const char* version=reinterpret_cast<const char*>(dlsym(h->lib,"qh_version"));
  if(!version||std::strcmp(version,"2020.2.r 2020/08/31")!=0)throw std::runtime_error("reentrant Qhull 2020.2 runtime required");
  auto zero=sym<decltype(&qh_zero)>(*h,"qh_zero");auto build=sym<decltype(&qh_new_qhull)>(*h,"qh_new_qhull");
  auto freeqh=sym<decltype(&qh_freeqhull)>(*h,"qh_freeqhull");auto freemem=sym<decltype(&qh_memfreeshort)>(*h,"qh_memfreeshort");
  auto pointid=sym<decltype(&qh_pointid)>(*h,"qh_pointid");auto setsize=sym<decltype(&qh_setsize)>(*h,"qh_setsize");
  // Struct layouts are version-specific; verify them against the loaded C ABI.
  auto libcheck=sym<decltype(&qh_lib_check)>(*h,"qh_lib_check");
  libcheck(QHULL_LIB_TYPE,sizeof(qhT),sizeof(vertexT),sizeof(ridgeT),sizeof(facetT),sizeof(setT),sizeof(qhmemT));
  std::vector<std::array<int,3>> faces;
  for(int attempt=0;attempt<2;++attempt){
   qhT object;qhT* qh=&object;FILE* log=tmpfile();if(!log)throw std::runtime_error("cannot create private Qhull diagnostics stream");
   zero(qh,log);auto points=original;
   std::string options="qhull Qt";if(maximum>0)options+=" TA"+std::to_string(maximum-4);if(attempt)options+=" QJ";
   std::vector<char> command(options.begin(),options.end());command.push_back(0);
   int code=build(qh,3,int(points.size()/3),points.data(),False,command.data(),log,log);
   if(code==0){
    try {
     facetT* facet;vertexT* vertex;vertexT** vertexp;
     FORALLfacets {
      if(setsize(qh,facet->vertices)!=3)throw std::runtime_error("Qhull Qt returned non-triangle facet");
      std::array<int,3> f{};int j=0;FOREACHvertex_(facet->vertices){int i=pointid(qh,vertex->point);if(i<0||size_t(i)>=original.size()/3)throw std::runtime_error("Qhull vertex index outside original points");f[j++]=i;}faces.push_back(f);
     }
    }catch(...){freeqh(qh,!qh_ALL);int a,b;freemem(qh,&a,&b);fclose(log);throw;}
   }
   freeqh(qh,!qh_ALL);int a,b;freemem(qh,&a,&b);fclose(log);
   if(code==0){h->joggled=attempt!=0;break;}if(attempt)throw std::runtime_error("Qhull Qt and explicit QJ retry both failed");
  }
  if(faces.empty())throw std::runtime_error("Qhull produced no faces");
  std::array<double,3> center{};for(size_t i=0;i<original.size();++i)center[i%3]+=original[i]/double(original.size()/3);
  std::vector<int> used;
  for(auto& f:faces){
   std::array<double,3> a{},u{},v{};for(int k=0;k<3;++k){a[k]=float(original[f[0]*3+k]);u[k]=double(float(original[f[1]*3+k]))-a[k];v[k]=double(float(original[f[2]*3+k]))-a[k];}
   double dot=(u[1]*v[2]-u[2]*v[1])*(a[0]-center[0])+(u[2]*v[0]-u[0]*v[2])*(a[1]-center[1])+(u[0]*v[1]-u[1]*v[0])*(a[2]-center[2]);if(dot<0)std::swap(f[1],f[2]);
   used.insert(used.end(),f.begin(),f.end());
  }
  std::sort(used.begin(),used.end());used.erase(std::unique(used.begin(),used.end()),used.end());
  std::vector<int> remap(original.size()/3,-1);for(size_t i=0;i<used.size();++i){remap[used[i]]=int(i);for(int k=0;k<3;++k){float value=float(original[used[i]*3+k]);if(!std::isfinite(value))throw std::runtime_error("hull float32 overflow");uint32_t bits;std::memcpy(&bits,&value,4);word(h->points,bits);}}
  for(auto f:faces)for(int i:f)word(h->indices,uint32_t(remap[i]));
 }catch(const std::exception& e){h->error=e.what();}catch(...){h->error="unknown Qhull C API failure";}
 return h;
}
const char* mr_convex_hull_error(void* p){return p?static_cast<Hull*>(p)->error.c_str():"null hull owner";}
const uint8_t* mr_convex_hull_points(void* p,size_t* size){auto& v=static_cast<Hull*>(p)->points;*size=v.size();return v.data();}
const uint8_t* mr_convex_hull_indices(void* p,size_t* size){auto& v=static_cast<Hull*>(p)->indices;*size=v.size();return v.data();}
int mr_convex_hull_joggled(void* p){return static_cast<Hull*>(p)->joggled?1:0;}
void mr_convex_hull_close(void* p){delete static_cast<Hull*>(p);}
