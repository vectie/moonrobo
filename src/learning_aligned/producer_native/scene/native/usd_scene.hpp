#ifndef MOONROBO_APIC_USD_SCENE_HPP
#define MOONROBO_APIC_USD_SCENE_HPP
// Native schema reading only. This is not Newton's USD importer or ModelBuilder.
#include "../../model/native/json_writer.hpp"
#include <pxr/base/tf/stringUtils.h>
#include <pxr/base/gf/matrix4d.h>
#include <pxr/base/gf/quatf.h>
#include <pxr/base/vt/array.h>
#include <pxr/usd/usd/primRange.h>
#include <pxr/usd/usdGeom/capsule.h>
#include <pxr/usd/usdGeom/cone.h>
#include <pxr/usd/usdGeom/cube.h>
#include <pxr/usd/usdGeom/cylinder.h>
#include <pxr/usd/usdGeom/mesh.h>
#include <pxr/usd/usdGeom/metrics.h>
#include <pxr/usd/usdGeom/sphere.h>
#include <pxr/usd/usdGeom/xformCache.h>
#include <pxr/usd/usdPhysics/articulationRootAPI.h>
#include <pxr/usd/usdPhysics/collisionAPI.h>
#include <pxr/usd/usdPhysics/driveAPI.h>
#include <pxr/usd/usdPhysics/filteredPairsAPI.h>
#include <pxr/usd/usdPhysics/fixedJoint.h>
#include <pxr/usd/usdPhysics/joint.h>
#include <pxr/usd/usdPhysics/massAPI.h>
#include <pxr/usd/usdPhysics/materialAPI.h>
#include <pxr/usd/usdPhysics/meshCollisionAPI.h>
#include <pxr/usd/usdPhysics/metrics.h>
#include <pxr/usd/usdPhysics/prismaticJoint.h>
#include <pxr/usd/usdPhysics/revoluteJoint.h>
#include <pxr/usd/usdPhysics/rigidBodyAPI.h>
#include <pxr/usd/usdShade/materialBindingAPI.h>
#include <pxr/usd/usdShade/material.h>
#include <set>

PXR_NAMESPACE_OPEN_SCOPE
namespace moonrobo_scene {
using namespace mr_json;
template<class T> T read(const UsdAttribute& attr) {
  T value{};
  if(!attr||!attr.Get(&value,UsdTimeCode::Default()))
    throw std::runtime_error("cannot read USD schema attribute: "+attr.GetPath().GetString());
  return value;
}
inline std::string token(const UsdAttribute& attr){return text(read<TfToken>(attr).GetString());}
template<class T> std::string numeric(T value) {
  if(std::isfinite(static_cast<double>(value)))return number(value);
  if(std::isnan(static_cast<double>(value)))throw std::runtime_error("NaN in USD physics attribute");
  return text(value>0?"+infinity":"-infinity");
}
inline std::string scalar(const UsdAttribute& attr) {return numeric(read<float>(attr));}
inline std::string vector3(const GfVec3f& value) {
  return list({number(value[0]),number(value[1]),number(value[2])});
}
inline std::string mass_vector3(const GfVec3f& value) {
  // USD permits infinite center-of-mass sentinels for automatic inference.
  return list({numeric(value[0]),numeric(value[1]),numeric(value[2])});
}
inline std::string quaternion(const GfQuatf& q) {
  const auto v=q.GetImaginary();return list({number(q.GetReal()),number(v[0]),number(v[1]),number(v[2])});
}
inline std::string matrix(const GfMatrix4d& m) {
  std::vector<std::string> values;
  for(int r=0;r<4;++r)for(int c=0;c<4;++c)values.push_back(number(m[r][c]));
  return list(values);
}
inline std::string paths(const UsdRelationship& rel) {
  SdfPathVector paths;
  if(rel&&!rel.GetForwardedTargets(&paths))throw std::runtime_error("cannot resolve USD relationship: "+rel.GetPath().GetString());
  std::vector<std::string> values;for(const auto& path:paths)values.push_back(text(path.GetString()));
  return list(values);
}
inline std::string mass_properties(const UsdPrim& prim) {
  UsdPhysicsMassAPI api(prim);
  if(!api)return "null";
  const auto m=api.GetMassAttr(),d=api.GetDensityAttr(),c=api.GetCenterOfMassAttr(),i=api.GetDiagonalInertiaAttr(),q=api.GetPrincipalAxesAttr();
  // Missing authored mass/inertia is deliberately null: Newton computes them
  // from shapes/densities with its own precedence and inertia correction rules.
  return object({{"mass",m.HasAuthoredValueOpinion()?scalar(m):"null"},
    {"density",d.HasAuthoredValueOpinion()?scalar(d):"null"},
    {"center_of_mass",c.HasAuthoredValueOpinion()?mass_vector3(read<GfVec3f>(c)):"null"},
    {"diagonal_inertia",i.HasAuthoredValueOpinion()?vector3(read<GfVec3f>(i)):"null"},
    {"principal_axes_wxyz",q.HasAuthoredValueOpinion()?quaternion(read<GfQuatf>(q)):"null"},
    {"automatic_mass_properties_computed","false"}});
}
inline std::string drives(const UsdPrim& prim) {
  std::vector<std::string> rows;
  for(const auto& drive:UsdPhysicsDriveAPI::GetAll(prim))rows.push_back(object({
    {"name",text(drive.GetName().GetString())},{"type",token(drive.GetTypeAttr())},
    {"max_force",scalar(drive.GetMaxForceAttr())},{"stiffness",scalar(drive.GetStiffnessAttr())},
    {"damping",scalar(drive.GetDampingAttr())},{"target_position",scalar(drive.GetTargetPositionAttr())},
    {"target_velocity",scalar(drive.GetTargetVelocityAttr())}}));
  return list(rows);
}
inline std::string joint(const UsdPrim& prim) {
  UsdPhysicsJoint api(prim);std::string kind="unsupported",axis="",limits="null";
  if(prim.IsA<UsdPhysicsRevoluteJoint>()){
    kind="revolute";UsdPhysicsRevoluteJoint j(prim);axis=read<TfToken>(j.GetAxisAttr()).GetString();
    limits=object({{"lower",scalar(j.GetLowerLimitAttr())},{"upper",scalar(j.GetUpperLimitAttr())},{"unit",text("degrees")}});
  }else if(prim.IsA<UsdPhysicsPrismaticJoint>()){
    kind="prismatic";UsdPhysicsPrismaticJoint j(prim);axis=read<TfToken>(j.GetAxisAttr()).GetString();
    limits=object({{"lower",scalar(j.GetLowerLimitAttr())},{"upper",scalar(j.GetUpperLimitAttr())},{"unit",text("stage-distance")}});
  }else if(prim.IsA<UsdPhysicsFixedJoint>())kind="fixed";
  return object({{"path",text(prim.GetPath().GetString())},{"name",text(prim.GetName().GetString())},
    {"kind",text(kind)},{"body0",paths(api.GetBody0Rel())},{"body1",paths(api.GetBody1Rel())},
    {"local_position0",vector3(read<GfVec3f>(api.GetLocalPos0Attr()))},
    {"local_position1",vector3(read<GfVec3f>(api.GetLocalPos1Attr()))},
    {"local_rotation0_wxyz",quaternion(read<GfQuatf>(api.GetLocalRot0Attr()))},
    {"local_rotation1_wxyz",quaternion(read<GfQuatf>(api.GetLocalRot1Attr()))},
    {"axis",text(axis)},{"limits",limits},
    {"enabled",boolean(read<bool>(api.GetJointEnabledAttr()))},
    {"collision_enabled",boolean(read<bool>(api.GetCollisionEnabledAttr()))},
    {"excluded_from_articulation",boolean(read<bool>(api.GetExcludeFromArticulationAttr()))},
    {"drives",drives(prim)}});
}
inline std::string geometry(const UsdPrim& prim,std::vector<std::string>& unsupported) {
  if(prim.IsA<UsdGeomMesh>()){
    UsdGeomMesh mesh(prim);
    auto points=read<VtVec3fArray>(mesh.GetPointsAttr());
    auto counts=read<VtIntArray>(mesh.GetFaceVertexCountsAttr());
    auto indices=read<VtIntArray>(mesh.GetFaceVertexIndicesAttr());
    auto holes=read<VtIntArray>(mesh.GetHoleIndicesAttr());
    if(points.size()>1000000||indices.size()>6000000)throw std::runtime_error("USD collision mesh exceeds native scene IR bounds");
    size_t expected=0;for(int count:counts){if(count<3)throw std::runtime_error("invalid USD mesh face width");expected+=size_t(count);}
    if(expected!=indices.size())throw std::runtime_error("USD mesh face counts do not match indices");
    for(int index:indices)if(index<0||size_t(index)>=points.size())throw std::runtime_error("USD mesh index out of range");
    for(int hole:holes)if(hole<0||size_t(hole)>=counts.size())throw std::runtime_error("USD mesh hole face out of range");
    std::vector<std::string> vertices;for(const auto& p:points)vertices.push_back(vector3(p));
    if(!holes.empty())unsupported.push_back(text("mesh holes require Newton triangulation: "+prim.GetPath().GetString()));
    return object({{"points",list(vertices)},{"face_vertex_counts",array(counts.cdata(),counts.size())},
      {"face_vertex_indices",array(indices.cdata(),indices.size())},{"hole_indices",array(holes.cdata(),holes.size())},
      {"orientation",token(mesh.GetOrientationAttr())},{"subdivision_scheme",token(mesh.GetSubdivisionSchemeAttr())},
      {"triangulated","false"}});
  }
  if(prim.IsA<UsdGeomCube>())return object({{"size",number(read<double>(UsdGeomCube(prim).GetSizeAttr()))}});
  if(prim.IsA<UsdGeomSphere>())return object({{"radius",number(read<double>(UsdGeomSphere(prim).GetRadiusAttr()))}});
  UsdAttribute radius,height,axis;
  if(prim.IsA<UsdGeomCapsule>()){UsdGeomCapsule s(prim);radius=s.GetRadiusAttr();height=s.GetHeightAttr();axis=s.GetAxisAttr();}
  else if(prim.IsA<UsdGeomCylinder>()){UsdGeomCylinder s(prim);radius=s.GetRadiusAttr();height=s.GetHeightAttr();axis=s.GetAxisAttr();}
  else if(prim.IsA<UsdGeomCone>()){UsdGeomCone s(prim);radius=s.GetRadiusAttr();height=s.GetHeightAttr();axis=s.GetAxisAttr();}
  if(radius)return object({{"radius",number(read<double>(radius))},{"height",number(read<double>(height))},{"axis",token(axis)}});
  unsupported.push_back(text("unsupported collision geometry: "+prim.GetPath().GetString()));return "null";
}
inline std::string articulation_ir(const UsdStageRefPtr& stage,const UsdPrim& root) {
  UsdGeomXformCache transforms(UsdTimeCode::Default());
  std::vector<std::string> bodies,joints,shapes,materials,filtered,roots,unsupported,extensions;
  std::set<std::string> material_paths;
  // Raw schema extraction is intentionally distinct from Newton/Mjc/Physx
  // resolver precedence and cooked model memory layouts.
  unsupported.push_back(text("Newton/Physx/Mjc schema resolver precedence not implemented"));
  unsupported.push_back(text("Newton mass inference, mesh cooking, joint ordering and ModelBuilder.finalize not implemented"));
  for(const auto& prim:UsdPrimRange(root,UsdTraverseInstanceProxies())){
    const auto path=prim.GetPath().GetString();
    if(prim.HasAPI<UsdPhysicsArticulationRootAPI>())roots.push_back(text(path));
    if(prim.HasAPI<UsdPhysicsRigidBodyAPI>()){
      UsdPhysicsRigidBodyAPI api(prim);
      bodies.push_back(object({{"path",text(path)},{"name",text(prim.GetName().GetString())},
        {"world_transform",matrix(transforms.GetLocalToWorldTransform(prim))},
        {"enabled",boolean(read<bool>(api.GetRigidBodyEnabledAttr()))},
        {"kinematic",boolean(read<bool>(api.GetKinematicEnabledAttr()))},
        {"mass_properties",mass_properties(prim)},
        {"velocity",vector3(read<GfVec3f>(api.GetVelocityAttr()))},
        {"angular_velocity_degrees",vector3(read<GfVec3f>(api.GetAngularVelocityAttr()))}}));
    }
    if(prim.IsA<UsdPhysicsJoint>())joints.push_back(joint(prim));
    if(prim.HasAPI<UsdPhysicsFilteredPairsAPI>())filtered.push_back(object({
      {"prim",text(path)},{"targets",paths(UsdPhysicsFilteredPairsAPI(prim).GetFilteredPairsRel())}}));
    if(prim.HasAPI<UsdPhysicsCollisionAPI>()){
      auto ancestor=prim;while(ancestor&&!ancestor.HasAPI<UsdPhysicsRigidBodyAPI>())ancestor=ancestor.GetParent();
      auto material=UsdShadeMaterialBindingAPI(prim).ComputeBoundMaterial(TfToken("physics"));
      if(material)material_paths.insert(material.GetPath().GetString());
      UsdPhysicsMeshCollisionAPI approximation(prim);
      shapes.push_back(object({{"path",text(path)},
        {"body",ancestor?text(ancestor.GetPath().GetString()):"null"},
        {"kind",text(prim.GetTypeName().GetString())},
        {"world_transform",matrix(transforms.GetLocalToWorldTransform(prim))},
        {"geometry",geometry(prim,unsupported)},
        {"material",material?text(material.GetPath().GetString()):"null"},
        {"enabled",boolean(read<bool>(UsdPhysicsCollisionAPI(prim).GetCollisionEnabledAttr()))},
        {"approximation",approximation?token(approximation.GetApproximationAttr()):"null"}}));
    }
    for(const auto& attr:prim.GetAuthoredAttributes()){
      const auto name=attr.GetName().GetString();
      if(name.rfind("physx",0)!=0&&name.rfind("newton:",0)!=0&&name.rfind("mjc:",0)!=0)continue;
      VtValue value;if(!attr.Get(&value,UsdTimeCode::Default()))throw std::runtime_error("cannot read extension attribute: "+attr.GetPath().GetString());
      extensions.push_back(object({{"path",text(attr.GetPath().GetString())},
        {"type",text(attr.GetTypeName().GetAsToken().GetString())},{"value_text",text(TfStringify(value))}}));
    }
  }
  for(const auto& path:material_paths){
    auto prim=stage->GetPrimAtPath(SdfPath(path));UsdPhysicsMaterialAPI api(prim);
    materials.push_back(object({{"path",text(path)},
      {"dynamic_friction",api?scalar(api.GetDynamicFrictionAttr()):"null"},
      {"static_friction",api?scalar(api.GetStaticFrictionAttr()):"null"},
      {"restitution",api?scalar(api.GetRestitutionAttr()):"null"},
      {"density",api?scalar(api.GetDensityAttr()):"null"}}));
  }
  const auto kg=UsdPhysicsGetStageKilogramsPerUnit(stage);
  if(!std::isfinite(kg)||kg<=0)throw std::runtime_error("USD kilogramsPerUnit must be positive finite");
  return object({{"format",text("moonrobo.aligned-usd-articulation-ir.v1")},
    {"root",text(root.GetPath().GetString())},{"meters_per_unit",number(UsdGeomGetStageMetersPerUnit(stage))},
    {"kilograms_per_unit",number(kg)},{"up_axis",text(UsdGeomGetStageUpAxis(stage).GetString())},
    {"bodies",list(bodies)},{"joints",list(joints)},{"shapes",list(shapes)},{"materials",list(materials)},
    {"filtered_pairs",list(filtered)},{"articulation_roots",list(roots)},
    {"unsupported_features",list(unsupported)},{"extension_properties",list(extensions)},
    {"matrix_convention",text("row-major GfMatrix4d, USD row-vector transforms; stage units")},
    {"quaternion_convention",text("wxyz")},{"attribute_time",text("UsdTimeCode::Default")},
    {"native_builder_ready","false"},{"newton_model_constructed","false"}});
}
}
PXR_NAMESPACE_CLOSE_SCOPE
#endif
