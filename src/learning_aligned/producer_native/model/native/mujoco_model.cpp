#include "model_api.h"
#include "json_writer.hpp"
#include <mujoco/mujoco.h>
#include <limits>
#include <memory>
#include <new>
#if defined(_WIN32)
#include <windows.h>
#else
#include <dlfcn.h>
#endif
namespace {
using namespace mr_json;
struct Model {
  void* library=nullptr;
  mjModel* model=nullptr;
  void (*delete_model)(mjModel*)=nullptr;
  const char* (*id2name)(const mjModel*,int,int)=nullptr;
  std::string error,json;
  std::vector<uint8_t> binary;
  ~Model(){
    if(model&&delete_model)delete_model(model);
    if(library){
#if defined(_WIN32)
      FreeLibrary(static_cast<HMODULE>(library));
#else
      dlclose(library);
#endif
    }
  }
  std::string name(int type,int id) const {
    const char* value=id2name(model,type,id);return text(value?value:"");
  }
  template<class T> T symbol(const char* name) {
#if defined(_WIN32)
    void* value=reinterpret_cast<void*>(GetProcAddress(static_cast<HMODULE>(library),name));
#else
    void* value=dlsym(library,name);
#endif
    if(!value)throw std::runtime_error(std::string("missing MuJoCo symbol: ")+name);
    return reinterpret_cast<T>(value);
  }
  void describe() {
    const auto* m=model;
    std::vector<std::string> bodies,joints,actuators,geoms,meshes,keys,excludes;
    for(int i=0;i<m->nbody;++i){
      std::vector<std::string> ids;
      for(int j=0;j<m->body_jntnum[i];++j)ids.push_back(number(m->body_jntadr[i]+j));
      bodies.push_back(object({{"id",number(i)},{"name",name(mjOBJ_BODY,i)},
        {"parent",number(m->body_parentid[i])},{"weld",number(m->body_weldid[i])},
        {"position",array(m->body_pos+3*i,3)},{"quaternion_wxyz",array(m->body_quat+4*i,4)},
        {"com_position",array(m->body_ipos+3*i,3)},{"inertial_quaternion_wxyz",array(m->body_iquat+4*i,4)},
        {"mass",number(m->body_mass[i])},{"principal_inertia",array(m->body_inertia+3*i,3)},
        {"joints",list(ids)}}));
    }
    for(int i=0;i<m->njnt;++i){
      int width=m->jnt_type[i]==mjJNT_FREE?7:m->jnt_type[i]==mjJNT_BALL?4:1;
      joints.push_back(object({{"id",number(i)},{"name",name(mjOBJ_JOINT,i)},
        {"type",number(m->jnt_type[i])},{"body",number(m->jnt_bodyid[i])},
        {"qpos_address",number(m->jnt_qposadr[i])},{"velocity_address",number(m->jnt_dofadr[i])},
        {"pivot",array(m->jnt_pos+3*i,3)},{"axis",array(m->jnt_axis+3*i,3)},
        {"limited",boolean(m->jnt_limited[i])},{"range",array(m->jnt_range+2*i,2)},
        {"qpos_reference",array(m->qpos0+m->jnt_qposadr[i],width)}}));
    }
    for(int i=0;i<m->nu;++i){
      actuators.push_back(object({{"id",number(i)},{"name",name(mjOBJ_ACTUATOR,i)},
        {"transmission_type",number(m->actuator_trntype[i])},{"transmission_ids",array(m->actuator_trnid+2*i,2)},
        {"dynamics_type",number(m->actuator_dyntype[i])},{"gain_type",number(m->actuator_gaintype[i])},
        {"bias_type",number(m->actuator_biastype[i])},{"activation_address",number(m->actuator_actadr[i])},
        {"control_limited",boolean(m->actuator_ctrllimited[i])},{"force_limited",boolean(m->actuator_forcelimited[i])},
        {"control_range",array(m->actuator_ctrlrange+2*i,2)},{"force_range",array(m->actuator_forcerange+2*i,2)},
        {"gear",array(m->actuator_gear+6*i,6)},{"gain",array(m->actuator_gainprm+mjNGAIN*i,mjNGAIN)},
        {"bias",array(m->actuator_biasprm+mjNBIAS*i,mjNBIAS)},{"dynamics",array(m->actuator_dynprm+mjNDYN*i,mjNDYN)}}));
    }
    for(int i=0;i<m->ngeom;++i){
      geoms.push_back(object({{"id",number(i)},{"name",name(mjOBJ_GEOM,i)},
        {"body",number(m->geom_bodyid[i])},{"type",number(m->geom_type[i])},{"asset_id",number(m->geom_dataid[i])},
        {"position",array(m->geom_pos+3*i,3)},{"quaternion_wxyz",array(m->geom_quat+4*i,4)},
        {"size",array(m->geom_size+3*i,3)},{"friction",array(m->geom_friction+3*i,3)},
        {"contact_type",number(m->geom_contype[i])},{"contact_affinity",number(m->geom_conaffinity[i])},
        {"contact_dimension",number(m->geom_condim[i])},{"solver_reference",array(m->geom_solref+mjNREF*i,mjNREF)},
        {"solver_impedance",array(m->geom_solimp+mjNIMP*i,mjNIMP)}}));
    }
    for(int i=0;i<m->nmesh;++i){
      int path=m->mesh_pathadr[i];
      if(path>=m->npaths)throw std::runtime_error("mesh asset path outside compiled string table");
      meshes.push_back(object({{"id",number(i)},{"name",name(mjOBJ_MESH,i)},
        {"source_path",text(path>=0?m->paths+path:"")},
        {"scale",array(m->mesh_scale+3*i,3)},{"position",array(m->mesh_pos+3*i,3)},
        {"quaternion_wxyz",array(m->mesh_quat+4*i,4)},
        {"vertices",array(m->mesh_vert+3*m->mesh_vertadr[i],size_t(m->mesh_vertnum[i])*3)},
        {"faces",array(m->mesh_face+3*m->mesh_faceadr[i],size_t(m->mesh_facenum[i])*3)}}));
    }
    for(int i=0;i<m->nkey;++i){
      keys.push_back(object({{"name",name(mjOBJ_KEY,i)},{"time",number(m->key_time[i])},
        {"qpos",array(m->key_qpos+size_t(m->nq)*i,m->nq)},
        {"qvel",array(m->key_qvel+size_t(m->nv)*i,m->nv)},
        {"activation",array(m->key_act+size_t(m->na)*i,m->na)},
        {"control",array(m->key_ctrl+size_t(m->nu)*i,m->nu)}}));
    }
    for(int i=0;i<m->nexclude;++i){
      const uint32_t sig=static_cast<uint32_t>(m->exclude_signature[i]);
      excludes.push_back(list({number(sig>>16),number(sig&65535)}));
    }
    const auto& o=m->opt;
    json=object({{"format",text("moonrobo.aligned-compiled-mujoco-model.v1")},
      {"mujoco_header_version",number(mjVERSION_HEADER)},
      {"mujoco_runtime_version",text(symbol<const char*(*)(void)>("mj_versionString")())},
      {"dimensions",object({{"nq",number(m->nq)},{"nv",number(m->nv)},{"na",number(m->na)},
        {"nu",number(m->nu)},{"nbody",number(m->nbody)},{"njnt",number(m->njnt)},{"ngeom",number(m->ngeom)}})},
      {"options",object({{"timestep",number(o.timestep)},{"gravity",array(o.gravity,3)},
        {"integrator",number(o.integrator)},{"solver",number(o.solver)},{"cone",number(o.cone)},
        {"iterations",number(o.iterations)},{"tolerance",number(o.tolerance)},
        {"disable_flags",number(o.disableflags)},{"enable_flags",number(o.enableflags)}})},
      {"qpos0",array(m->qpos0,m->nq)},{"dof_armature",array(m->dof_armature,m->nv)},
      {"dof_damping",array(m->dof_damping,m->nv)},{"bodies",list(bodies)},{"joints",list(joints)},
      {"actuators",list(actuators)},{"geoms",list(geoms)},{"meshes",list(meshes)},
      {"keyframes",list(keys)},{"excluded_body_pairs",list(excludes)},
      {"simulation_executed","false"},{"newton_model_constructed","false"},
      {"descriptor_scope",text("rigid model metadata plus complete version-specific compiled MJB bytes; no cross-solver equivalence")}});
    if(json.size()>64u*1024u*1024u)throw std::runtime_error("model descriptor exceeds 64 MiB limit");
  }
};
}
extern "C" MR_MODEL_EXPORT int mr_prepared_model_abi(){return 1;}
extern "C" MR_MODEL_EXPORT void* mr_prepared_model_open(const char* library,const char* path){
  Model* result=new(std::nothrow) Model;if(!result)return nullptr;
  try {
    if(!library||!*library||!path||!*path)throw std::runtime_error("explicit MuJoCo library and MJCF required");
#if defined(_WIN32)
    result->library=LoadLibraryA(library);
#else
    result->library=dlopen(library,RTLD_NOW|RTLD_LOCAL);
#endif
    if(!result->library)throw std::runtime_error("cannot load explicit MuJoCo library");
    if(result->symbol<int(*)(void)>("mj_version")()!=mjVERSION_HEADER)throw std::runtime_error("MuJoCo headers/library version mismatch");
    result->delete_model=result->symbol<void(*)(mjModel*)>("mj_deleteModel");
    result->id2name=result->symbol<const char*(*)(const mjModel*,int,int)>("mj_id2name");
    char error[4096]={};
    result->model=result->symbol<mjModel*(*)(const char*,const mjVFS*,char*,int)>("mj_loadXML")(path,nullptr,error,sizeof(error));
    if(!result->model)throw std::runtime_error(error[0]?error:"MuJoCo rejected source model");
    // This check is post-compilation. It does not promise that mj_loadXML never
    // entered registered compiler/plugin hooks while reading the model.
    if(result->model->nplugin)throw std::runtime_error("plugin-bearing models require an explicit separate ownership adapter");
    int size=result->symbol<int(*)(const mjModel*)>("mj_sizeModel")(result->model);
    if(size<=0||size>256*1024*1024)throw std::runtime_error("compiled MJB must fit explicit 256 MiB limit");
    result->binary.resize(size);
    result->symbol<void(*)(const mjModel*,const char*,void*,int)>("mj_saveModel")(result->model,nullptr,result->binary.data(),size);
    result->describe();
  }catch(const std::exception& error){result->error=error.what();}
   catch(...){result->error="unknown native model preparation failure";}
  return result;
}
extern "C" MR_MODEL_EXPORT const char* mr_prepared_model_error(void* p){return p?static_cast<Model*>(p)->error.c_str():"model preparation allocation failed";}
extern "C" MR_MODEL_EXPORT const char* mr_prepared_model_json(void* p){return p?static_cast<Model*>(p)->json.c_str():"";}
extern "C" MR_MODEL_EXPORT const uint8_t* mr_prepared_model_mjb(void* p,size_t* n){
  if(!p||!n)return nullptr;const auto& b=static_cast<Model*>(p)->binary;*n=b.size();return b.data();
}
extern "C" MR_MODEL_EXPORT void mr_prepared_model_close(void* p){delete static_cast<Model*>(p);}
