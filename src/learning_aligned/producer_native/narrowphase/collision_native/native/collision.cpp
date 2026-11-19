// Independent MuJoCo 3.3.7 C collision adapter, not a Newton/Warp timestep.
#include <mujoco/mujoco.h>
#include "json_writer.hpp"
#include <algorithm>
#include <cstdint>
#include <limits>
#if defined(_WIN32)
#include <windows.h>
#define MR_EXPORT extern "C" __declspec(dllexport)
#else
#include <dlfcn.h>
#define MR_EXPORT extern "C" __attribute__((visibility("default")))
#endif
static_assert(mjVERSION_HEADER==337,"This audited adapter requires genuine MuJoCo 3.3.7 headers");
static_assert(sizeof(mjtNum)==sizeof(double),"CPU/Double MuJoCo required");
namespace {
struct Session {
  void* lib=nullptr; mjModel* m=nullptr; mjData* d=nullptr; int capacity=0;
  std::string error, json;
  decltype(&mj_version) version=nullptr;
  decltype(&mj_loadModel) load=nullptr;
  decltype(&mj_makeData) make=nullptr;
  decltype(&mj_deleteModel) delete_model=nullptr;
  decltype(&mj_deleteData) delete_data=nullptr;
  decltype(&mj_resetData) reset=nullptr;
  decltype(&mj_kinematics) kinematics=nullptr;
  decltype(&mj_comPos) compos=nullptr;
  decltype(&mj_collision) collision=nullptr;
  ~Session(){if(d&&delete_data)delete_data(d);if(m&&delete_model)delete_model(m);if(lib){
#if defined(_WIN32)
    FreeLibrary((HMODULE)lib);
#else
    dlclose(lib);
#endif
  }}
  template<class T> T symbol(const char* name){
#if defined(_WIN32)
    auto result=reinterpret_cast<T>(GetProcAddress((HMODULE)lib,name));
#else
    auto result=reinterpret_cast<T>(dlsym(lib,name));
#endif
    if(!result)throw std::runtime_error(std::string("MuJoCo C symbol missing: ")+name);return result;
  }
  void open(const char* library,const char* mjb,int cap){
    if(!library||!*library||!mjb||!*mjb||cap<0)throw std::runtime_error("explicit native library, MJB and nonnegative capacity required");
    capacity=cap;
#if defined(_WIN32)
    lib=LoadLibraryA(library);
#else
    lib=dlopen(library,RTLD_NOW|RTLD_LOCAL);
#endif
    if(!lib)throw std::runtime_error("cannot load explicit MuJoCo library");
    version=symbol<decltype(version)>("mj_version");
    if(version()!=mjVERSION_HEADER)throw std::runtime_error("MuJoCo runtime/header mismatch: exact 337 required");
    load=symbol<decltype(load)>("mj_loadModel");make=symbol<decltype(make)>("mj_makeData");
    delete_model=symbol<decltype(delete_model)>("mj_deleteModel");delete_data=symbol<decltype(delete_data)>("mj_deleteData");
    reset=symbol<decltype(reset)>("mj_resetData");kinematics=symbol<decltype(kinematics)>("mj_kinematics");
    compos=symbol<decltype(compos)>("mj_comPos");collision=symbol<decltype(collision)>("mj_collision");
    // Binary deserialization only: no XML compiler, builder, asset lookup or Python.
    m=load(mjb,nullptr);if(!m)throw std::runtime_error("mj_loadModel rejected MJB");
    if(m->nplugin||m->nflex)throw std::runtime_error("plugins/flex unsupported by independent rigid collision route");
    if(m->nbody<1||m->nbody>46340||m->nq<0||m->ngeom<0)throw std::runtime_error("unsafe model dimensions for audited collision driver");
    for(int g=0;g<m->ngeom;++g)if(m->geom_type[g]==mjGEOM_SDF)throw std::runtime_error("SDF/plugin geometry unsupported");
    d=make(m);if(!d)throw std::runtime_error("mj_makeData allocation failed");
  }
  void collide(const double* qpos,size_t count){
    if(!m||!d)throw std::runtime_error("collision session not initialized");
    if(count!=static_cast<size_t>(m->nq)||(count&&!qpos))throw std::runtime_error("qpos length must equal actual MJB nq");
    for(size_t i=0;i<count;++i)if(!std::isfinite(qpos[i]))throw std::runtime_error("qpos must be finite");
    // No silent quaternion normalization: input receipt remains the evaluated state.
    for(int j=0;j<m->njnt;++j){int t=m->jnt_type[j];if(t==mjJNT_FREE||t==mjJNT_BALL){
      int adr=m->jnt_qposadr[j]+(t==mjJNT_FREE?3:0);
      if(adr<0||static_cast<size_t>(adr)+4>count)throw std::runtime_error("invalid MJB quaternion address");
      double norm=0;for(int k=0;k<4;++k)norm+=qpos[adr+k]*qpos[adr+k];
      if(!std::isfinite(norm)||std::abs(norm-1.0)>1e-8)throw std::runtime_error("unit wxyz free/ball quaternion required");
    }}
    reset(m,d);if(count)std::copy(qpos,qpos+count,d->qpos);
    // Rigid geometry prerequisites from mj_fwdPosition: xpose and inertial frames.
    // No flex => mj_flex dynamic BVH stage is unnecessary; tendon/camera/inertia do not feed rigid collision.
    kinematics(m,d);compos(m,d);collision(m,d);
    if(d->warning[mjWARN_CONTACTFULL].number)throw std::runtime_error("MuJoCo CONTACTFULL: native contacts incomplete");
    if(d->ncon<0||d->ncon>capacity)throw std::runtime_error("native contact count exceeds requested output capacity");
    using namespace mr_json;std::vector<std::string> contacts,warnings;
    contacts.reserve(static_cast<size_t>(d->ncon));
    for(int i=0;i<d->ncon;++i){const mjContact& c=d->contact[i];contacts.push_back(object({
      {"dist",number(c.dist)},{"pos",array(c.pos,3)},{"frame",array(c.frame,9)},
      {"includemargin",number(c.includemargin)},{"friction",array(c.friction,5)},
      {"solref",array(c.solref,mjNREF)},{"solreffriction",array(c.solreffriction,mjNREF)},
      {"solimp",array(c.solimp,mjNIMP)},{"dim",number(c.dim)},{"geom",array(c.geom,2)},
      {"flex",array(c.flex,2)},{"elem",array(c.elem,2)},{"vert",array(c.vert,2)},
      {"exclude",number(c.exclude)},{"efc_address",number(c.efc_address)}
    }));}
    for(int i=0;i<mjNWARNING;++i)if(d->warning[i].number)warnings.push_back(object({
      {"warning_id",number(i)},{"number",number(d->warning[i].number)},{"lastinfo",number(d->warning[i].lastinfo)}
    }));
    json=object({{"format",text("moonrobo-mujoco-native-collision-v1")},
      {"backend",text("mujoco-3.3.7-native-cpu-collision")},{"scalar_type",text("float64")},
      {"header_version",number(mjVERSION_HEADER)},{"runtime_version",number(version())},
      {"nq",number(m->nq)},{"nv",number(m->nv)},{"ngeom",number(m->ngeom)},
      {"nmesh",number(m->nmesh)},{"nhfield",number(m->nhfield)},{"ncon",number(d->ncon)},
      {"contact_capacity",number(capacity)},{"contacts",list(contacts)},{"warnings",list(warnings)},
      {"collision_executed","true"},{"dynamics_step_executed","false"},
      {"newton_model_constructed","false"},{"warp_capture_generated","false"},
      {"cross_solver_equivalence_verified","false"},{"constraint_solver_executed","false"},
      {"solver_only_mu_H_fields_exported","false"},{"disableflags",number(m->opt.disableflags)},
      {"enableflags",number(m->opt.enableflags)}
    });
  }
};
}
MR_EXPORT int mr_collision_abi(){return 1;}
MR_EXPORT void* mr_collision_open(const char* library,const char* mjb,int capacity){
  Session* s=nullptr;try{s=new Session;s->open(library,mjb,capacity);}catch(const std::exception& e){if(s)s->error=e.what();}catch(...){if(s)s->error="unknown native collision initialization error";}return s;
}
MR_EXPORT const char* mr_collision_error(void* p){return p?static_cast<Session*>(p)->error.c_str():"collision allocation failed";}
MR_EXPORT const char* mr_collision_json(void* p){return p?static_cast<Session*>(p)->json.c_str():"";}
MR_EXPORT int mr_collision_run(void* p,const double* qpos,size_t size){
  auto* s=static_cast<Session*>(p);if(!s||!s->error.empty())return -1;
  s->json.clear();try{s->collide(qpos,size);return 0;}catch(const std::exception& e){s->error=e.what();}catch(...){s->error="unknown native collision error";}return -1;
}
MR_EXPORT void mr_collision_close(void* p){delete static_cast<Session*>(p);}
