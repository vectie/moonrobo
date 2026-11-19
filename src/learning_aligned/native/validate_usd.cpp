// Optional genuine OpenUSD validator; compile-only during migration.
#include <pxr/usd/usd/stage.h>
#include <pxr/usd/usd/primRange.h>
#include <pxr/usd/usdGeom/mesh.h>
#include <pxr/usd/usdPhysics/articulationRootAPI.h>
#include <pxr/usd/usdPhysics/rigidBodyAPI.h>
#include <pxr/usd/usdPhysics/revoluteJoint.h>
#include <iostream>
PXR_NAMESPACE_USING_DIRECTIVE
int main(int argc,char** argv) {
  if(argc!=2){std::cerr<<"usage: moonrobo_validate_usd converted.usda\n";return 2;}
  auto stage=UsdStage::Open(argv[1]);if(!stage){std::cerr<<"OpenUSD rejected stage\n";return 1;}
  auto root=stage->GetDefaultPrim();
  if(!root||root.GetPath()!=SdfPath("/G1")||!root.HasAPI<UsdPhysicsArticulationRootAPI>()){std::cerr<<"missing G1 articulation\n";return 1;}
  int joints=0,bodies=0,meshes=0;
  for(auto prim:stage->Traverse()) {
    if(prim.HasAPI<UsdPhysicsRigidBodyAPI>())++bodies;
    if(prim.IsA<UsdPhysicsRevoluteJoint>()) {
      ++joints;auto joint=UsdPhysicsRevoluteJoint(prim);SdfPathVector target;
      if(!joint.GetBody1Rel().GetTargets(&target)||target.size()!=1||!stage->GetPrimAtPath(target[0])){std::cerr<<"invalid joint body target\n";return 1;}
    }
    if(prim.IsA<UsdGeomMesh>()) {
      ++meshes;VtVec3fArray points;VtIntArray counts,indices;auto mesh=UsdGeomMesh(prim);
      if(!mesh.GetPointsAttr().Get(&points)||!mesh.GetFaceVertexCountsAttr().Get(&counts)||!mesh.GetFaceVertexIndicesAttr().Get(&indices))return 1;
      size_t expected=0;for(int count:counts){if(count!=3)return 1;expected+=count;}if(expected!=indices.size())return 1;
      for(int index:indices)if(index<0||size_t(index)>=points.size())return 1;
    }
  }
  if(joints!=29||bodies<30){std::cerr<<"G1 joint/body topology differs\n";return 1;}
  std::cout<<"OpenUSD validated "<<bodies<<" bodies, "<<joints<<" hinges, "<<meshes<<" meshes\n";return 0;
}
