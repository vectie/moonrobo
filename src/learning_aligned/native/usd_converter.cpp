// Native compiled-MJCF -> standard USDA. No Python, Kit startup, or simulator stepping.
// Model layout: https://mujoco.readthedocs.io/en/stable/APIreference/APItypes.html
// USD schemas: https://openusd.org/release/api/usd_physics_page_front.html
#include <mujoco/mujoco.h>
#include <algorithm>
#include <array>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <iomanip>
#include <memory>
#include <sstream>
#include <stdexcept>
#include <string>
#include <unordered_set>
#include <vector>

#if defined(_WIN32)
#define MR_EXPORT __declspec(dllexport)
#else
#define MR_EXPORT __attribute__((visibility("default")))
#endif
namespace {
constexpr double kDegrees = 57.2957795130823208768;
using Model = std::unique_ptr<mjModel, decltype(&mj_deleteModel)>;
using Data = std::unique_ptr<mjData, decltype(&mj_deleteData)>;
std::string quoted(const std::string& s) {
  std::string result="\"";
  for(unsigned char c:s) {
    if(c=='\\'||c=='\"') { result+='\\'; result+=char(c); }
    else if(c<32) { throw std::runtime_error("control character in asset identifier"); }
    else result+=char(c);
  }
  return result+'"';
}
std::string identifier(const char* s, const std::string& fallback) {
  std::string result=s?s:fallback;
  if(result.empty()) result=fallback;
  for(size_t i=0;i<result.size();++i) {
    unsigned char c=result[i];
    if(!((c>='a'&&c<='z')||(c>='A'&&c<='Z')||c=='_'||(i>0&&c>='0'&&c<='9')))
      throw std::runtime_error("USD identifier would change the source name: "+result);
  }
  return result;
}
template<class T> void tuple(std::ostream& out,const T* p,int count) {
  out<<'('; for(int i=0;i<count;++i) {if(i)out<<", "; if(!std::isfinite(double(p[i])))throw std::runtime_error("nonfinite model field"); out<<p[i];} out<<')';
}
void attr3(std::ostream& out,const char* type,const char* name,const mjtNum* p) {out<<"        "<<type<<' '<<name<<" = ";tuple(out,p,3);out<<'\n';}
void attr4(std::ostream& out,const char* name,const mjtNum* p) {out<<"        quatf "<<name<<" = ";tuple(out,p,4);out<<'\n';}
void transform(std::ostream& out,const mjtNum* p,const mjtNum* q) {
  attr3(out,"double3","xformOp:translate",p);attr4(out,"xformOp:orient",q);
  out<<"        uniform token[] xformOpOrder = [\"xformOp:translate\", \"xformOp:orient\"]\n";
}
struct Writer {
  const mjModel* m; const mjData* d; bool self_collision; std::ostream& out;
  std::vector<std::string> bodies;
  std::vector<int> owners;
  std::string bodypath(int body) const {return "/G1/Links/"+bodies.at(body);}
  void relative_transform(int body,int owner) {
    mjtNum inverse[4],position[3],delta[3],rotation[4];mju_negQuat(inverse,d->xquat+4*owner);
    for(int k=0;k<3;++k)delta[k]=d->xpos[3*body+k]-d->xpos[3*owner+k];
    mju_rotVecQuat(position,delta,inverse);mju_mulQuat(rotation,inverse,d->xquat+4*body);transform(out,position,rotation);
  }
  void material(int geom) {
    const auto* mu=m->geom_friction+3*geom;
    out<<"        def Material \"Material\" (prepend apiSchemas = [\"PhysicsMaterialAPI\"]) {\n"
       <<"            float physics:staticFriction = "<<mu[0]<<"\n            float physics:dynamicFriction = "<<mu[0]
       <<"\n            float physics:restitution = 0\n        }\n";
  }
  void geom(int g) {
    const int type=m->geom_type[g];
    const char* kind = type==mjGEOM_MESH?"Mesh":type==mjGEOM_BOX?"Cube":type==mjGEOM_SPHERE||type==mjGEOM_ELLIPSOID?"Sphere":type==mjGEOM_CAPSULE?"Capsule":type==mjGEOM_CYLINDER?"Cylinder":type==mjGEOM_PLANE?"Plane":nullptr;
    if(!kind)throw std::runtime_error("unsupported MJCF geom type "+std::to_string(type));
    const bool collision=m->geom_contype[g]||m->geom_conaffinity[g];
    if(collision&&type==mjGEOM_ELLIPSOID)throw std::runtime_error("USD sphere collision uses the largest scale axis; collision ellipsoids require explicit convex triangulation");
    const std::string name=identifier(mj_id2name(m,mjOBJ_GEOM,g),"geom_"+std::to_string(g));
    out<<"        def "<<kind<<' '<<quoted(name)<<" (prepend apiSchemas = [\"MaterialBindingAPI\"";
    if(collision)out<<", \"PhysicsCollisionAPI\"";
    if(collision&&type==mjGEOM_MESH)out<<", \"PhysicsMeshCollisionAPI\"";
    out<<"]) {\n";
    transform(out,m->geom_pos+3*g,m->geom_quat+4*g);
    const float* rgba=m->geom_rgba+4*g;
    if(m->geom_matid[g]>=0) {
      const int mat=m->geom_matid[g];
      // MuJoCo uses the material color only when local rgba remains the
      // compiler default. Explicit geom rgba overrides the material.
      if(rgba[0]==0.5f&&rgba[1]==0.5f&&rgba[2]==0.5f&&rgba[3]==1.0f)rgba=m->mat_rgba+4*mat;
      // A material texture is meaningful data; do not silently discard it.
      if(m->mat_texid[mat*mjNTEXROLE+mjTEXROLE_RGB]>=0)throw std::runtime_error("textured material needs the OpenUSD texture asset path, unsupported by this bounded G1 converter");
    }
    out<<"        color3f[] primvars:displayColor = [";tuple(out,rgba,3);out<<"]\n        float[] primvars:displayOpacity = ["<<rgba[3]<<"]\n";
    const auto* size=m->geom_size+3*g;
    if(type==mjGEOM_MESH) {
      const int id=m->geom_dataid[g];if(id<0||id>=m->nmesh)throw std::runtime_error("invalid compiled mesh index");
      out<<"        point3f[] points = [";
      for(int v=0;v<m->mesh_vertnum[id];++v) {if(v)out<<", ";tuple(out,m->mesh_vert+3*(m->mesh_vertadr[id]+v),3);} out<<"]\n";
      out<<"        int[] faceVertexCounts = [";for(int f=0;f<m->mesh_facenum[id];++f){if(f)out<<", ";out<<3;}out<<"]\n        int[] faceVertexIndices = [";
      for(int f=0;f<3*m->mesh_facenum[id];++f){if(f)out<<", ";const int index=m->mesh_face[3*m->mesh_faceadr[id]+f];if(index<0||index>=m->mesh_vertnum[id])throw std::runtime_error("compiled mesh triangle out of bounds");out<<index;}
      out<<"]\n        uniform token subdivisionScheme = \"none\"\n";
      if(collision)out<<"        uniform token physics:approximation = \"convexHull\"\n";
    } else if(type==mjGEOM_BOX||type==mjGEOM_ELLIPSOID) {
      out<<(type==mjGEOM_BOX?"        double size = 2\n":"        double radius = 1\n");
      attr3(out,"double3","xformOp:scale",size);
      out<<"        uniform token[] xformOpOrder = [\"xformOp:translate\", \"xformOp:orient\", \"xformOp:scale\"]\n";
    } else if(type==mjGEOM_SPHERE) out<<"        double radius = "<<size[0]<<'\n';
    else if(type==mjGEOM_CAPSULE||type==mjGEOM_CYLINDER)out<<"        double radius = "<<size[0]<<"\n        double height = "<<2*size[1]<<"\n        uniform token axis = \"Z\"\n";
    else if(type==mjGEOM_PLANE)out<<"        double width = "<<(size[0]>0?2*size[0]:2)<<"\n        double length = "<<(size[1]>0?2*size[1]:2)<<"\n        uniform token axis = \"Z\"\n        custom bool moonrobo:infiniteCollisionPlane = true\n";
    if(collision) {
      out<<"        bool physics:collisionEnabled = true\n        rel material:binding:physics = <Material>\n";
      material(g);
    }
    out<<"        }\n";
  }
  void body(int b) {
    out<<"    def Xform "<<quoted(bodies[b])<<" (prepend apiSchemas = [\"PhysicsRigidBodyAPI\", \"PhysicsMassAPI\", \"PhysicsFilteredPairsAPI\"]) {\n";
    transform(out,d->xpos+3*b,d->xquat+4*b);
    out<<"        float physics:mass = "<<m->body_mass[b]<<"\n        bool physics:rigidBodyEnabled = true\n";
    attr3(out,"point3f","physics:centerOfMass",m->body_ipos+3*b);
    attr3(out,"float3","physics:diagonalInertia",m->body_inertia+3*b);
    attr4(out,"physics:principalAxes",m->body_iquat+4*b);
    {
      out<<"        rel physics:filteredPairs = [";bool first=true;
      // MuJoCo never collides bodies in the same fixed-joint weld cluster.
      // Exclude the entire cluster, not only each adjacent fixed-joint pair.
      for(int other=1;other<m->nbody;++other)if(other!=b&&owners[other]==other&&(!self_collision||m->body_weldid[b]==m->body_weldid[other])){if(!first)out<<", ";first=false;out<<'<'<<bodypath(other)<<'>';}
      out<<"]\n";
    }
    for(int g=0;g<m->body_geomnum[b];++g)geom(m->body_geomadr[b]+g);
    bool fixed_frames=false;
    for(int child=1;child<m->nbody;++child)if(child!=b&&owners[child]==b) {
      if(!fixed_frames){out<<"        def Scope \"FixedFrames\" {\n";fixed_frames=true;}
      // A massless fixed frame is not a second rigid body. Preserve its rest
      // transform and geometry under the actual massive rigid-body owner.
      // This avoids USD's mass=0 geometry-based mass inference entirely.
      out<<"            def Xform "<<quoted(bodies[child])<<" {\n";relative_transform(child,b);
      for(int g=0;g<m->body_geomnum[child];++g)geom(m->body_geomadr[child]+g);
      out<<"            }\n";
    }
    if(fixed_frames)out<<"        }\n";
    out<<"    }\n";
  }
  void joint(int b) {
    if(owners[b]!=b)return;
    const int parent=owners[m->body_parentid[b]],count=m->body_jntnum[b];
    if(count>1)throw std::runtime_error("multiple joints per G1 body unsupported");
    const int j=count?m->body_jntadr[b]:-1;
    if(j>=0&&m->jnt_type[j]==mjJNT_FREE) {if(parent!=0)throw std::runtime_error("free joint is not a root");return;}
    if(!count&&parent==0)throw std::runtime_error("fixed world body requires an explicit static-body conversion path");
    const bool hinge=j>=0&&m->jnt_type[j]==mjJNT_HINGE;
    if(j>=0&&!hinge)throw std::runtime_error("non-hinge G1 joint unsupported");
    if(hinge&&std::abs(m->qpos0[m->jnt_qposadr[j]])>1e-12)throw std::runtime_error("nonzero joint reference needs additional USD joint coordinate mapping");
    const std::string name=hinge?identifier(mj_id2name(m,mjOBJ_JOINT,j),"joint_"+std::to_string(j)):"fixed_"+bodies[b];
    mjtNum local1[3]={0,0,0},rot1[4]={1,0,0,0};
    if(hinge) {std::copy(m->jnt_pos+3*j,m->jnt_pos+3*j+3,local1);mju_quatZ2Vec(rot1,m->jnt_axis+3*j);
      mjtNum x_to_z[4]={std::sqrt(0.5),0,-std::sqrt(0.5),0},aligned[4];mju_mulQuat(aligned,rot1,x_to_z);std::copy(aligned,aligned+4,rot1);}
    mjtNum world[3],tmp[3],inv_parent[4],local0[3],world_rot[4],rot0[4];
    mju_rotVecQuat(tmp,local1,d->xquat+4*b);for(int k=0;k<3;++k)world[k]=d->xpos[3*b+k]+tmp[k];
    mju_negQuat(inv_parent,d->xquat+4*parent);for(int k=0;k<3;++k)tmp[k]=world[k]-d->xpos[3*parent+k];mju_rotVecQuat(local0,tmp,inv_parent);
    mju_mulQuat(world_rot,d->xquat+4*b,rot1);mju_mulQuat(rot0,inv_parent,world_rot);
    out<<"    def "<<(hinge?"PhysicsRevoluteJoint":"PhysicsFixedJoint")<<' '<<quoted(name)<<" {\n";
    if(parent)out<<"        rel physics:body0 = <"<<bodypath(parent)<<">\n";
    out<<"        rel physics:body1 = <"<<bodypath(b)<<">\n        bool physics:collisionEnabled = false\n";
    attr3(out,"point3f","physics:localPos0",local0);attr3(out,"point3f","physics:localPos1",local1);attr4(out,"physics:localRot0",rot0);attr4(out,"physics:localRot1",rot1);
    if(hinge) {
      out<<"        uniform token physics:axis = \"X\"\n        custom int moonrobo:mujocoJointId = "<<j<<"\n        custom double moonrobo:armature = "<<m->dof_armature[m->jnt_dofadr[j]]<<'\n';
      if(m->jnt_limited[j])out<<"        float physics:lowerLimit = "<<m->jnt_range[2*j]*kDegrees<<"\n        float physics:upperLimit = "<<m->jnt_range[2*j+1]*kDegrees<<'\n';
    }
    out<<"    }\n";
  }
  void run() {
    bodies.resize(m->nbody);owners.resize(m->nbody,0);std::unordered_set<std::string> unique;
    for(int b=1;b<m->nbody;++b){bodies[b]=identifier(mj_id2name(m,mjOBJ_BODY,b),"body_"+std::to_string(b));if(!unique.insert(bodies[b]).second)throw std::runtime_error("duplicate USD body identifier");}
    for(int b=1;b<m->nbody;++b){if(m->body_mass[b]>0)owners[b]=b;else{if(m->body_jntnum[b])throw std::runtime_error("massless moving body cannot be represented as a USD rigid body");owners[b]=owners[m->body_parentid[b]];if(!owners[b])throw std::runtime_error("massless world-fixed frame needs a static scene conversion path");}}
    out<<std::setprecision(17)<<"#usda 1.0\n(\n    defaultPrim = \"G1\"\n    metersPerUnit = 1\n    kilogramsPerUnit = 1\n    upAxis = \"Z\"\n)\n";
    out<<"def Xform \"G1\" (prepend apiSchemas = [\"PhysicsArticulationRootAPI\"]) {\n    custom string moonrobo:conversion = \"compiled-MuJoCo-to-standard-UsdPhysics-v1\"\n    custom string[] moonrobo:jointOrder = [";
    bool first=true;for(int j=0;j<m->njnt;++j)if(m->jnt_type[j]==mjJNT_HINGE){if(!first)out<<", ";first=false;out<<quoted(identifier(mj_id2name(m,mjOBJ_JOINT,j),"joint_"+std::to_string(j)));}out<<"]\n";
    out<<"    def Scope \"Links\" {\n";for(int b=1;b<m->nbody;++b)if(owners[b]==b)body(b);out<<"    }\n    def Scope \"Joints\" {\n";for(int b=1;b<m->nbody;++b)joint(b);out<<"    }\n}\n";
    for(int g=0;g<m->ngeom;++g)if(m->geom_bodyid[g]==0)geom(g);
  }
};
thread_local std::string last_error;
}
extern "C" MR_EXPORT const char* mr_aligned_usd_error(){return last_error.c_str();}
extern "C" MR_EXPORT int mr_aligned_convert_usd(const char* input,const char* output,int self_collision) {
  last_error.clear();
  try {
    if(!input||!output||!*input||!*output)throw std::runtime_error("MJCF source and USDA output paths are required");
    if(mj_version()!=mjVERSION_HEADER)throw std::runtime_error("MuJoCo runtime/header version mismatch");
    const std::filesystem::path destination(output);
    if(destination.extension()!=".usda")throw std::runtime_error("bounded native converter requires explicit .usda output");
    if(std::filesystem::exists(destination))throw std::runtime_error("USD output already exists; explicit separate destination required");
    char error[2048]={};Model model(mj_loadXML(input,nullptr,error,sizeof(error)),mj_deleteModel);if(!model)throw std::runtime_error(error);
    if(model->nq!=36||model->nv!=35)throw std::runtime_error("native conversion requires a 29-DoF free-root G1");
    Data data(mj_makeData(model.get()),mj_deleteData);if(!data)throw std::bad_alloc();mj_forward(model.get(),data.get());
    const auto temporary=destination.string()+".tmp";
    try {
      std::ofstream file(temporary,std::ios::binary|std::ios::trunc);if(!file)throw std::runtime_error("cannot create USDA output");
      Writer{model.get(),data.get(),self_collision!=0,file,{},{}}.run();file.flush();if(!file)throw std::runtime_error("USDA output write failed");file.close();
      std::filesystem::rename(temporary,destination);
    } catch(...) {std::error_code ignored;std::filesystem::remove(temporary,ignored);throw;}
    return 1;
  } catch(const std::exception& e){last_error=e.what();return 0;}
}
