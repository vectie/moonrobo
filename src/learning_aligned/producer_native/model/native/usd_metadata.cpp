#include "model_api.h"
#include "json_writer.hpp"
#include <pxr/base/tf/errorMark.h>
#include <pxr/pxr.h>
#ifdef PXR_PYTHON_SUPPORT_ENABLED
#error "Use an OpenUSD build configured with PXR_ENABLE_PYTHON_SUPPORT=OFF"
#endif
#include <pxr/usd/sdf/assetPath.h>
#include <pxr/usd/sdf/layer.h>
#include <pxr/usd/pcp/primIndex.h>
#include <pxr/usd/usd/editContext.h>
#include <pxr/usd/usd/primRange.h>
#include <pxr/usd/usd/stage.h>
#include <pxr/usd/usd/variantSets.h>
#include <pxr/usd/usdGeom/metrics.h>
#include <pxr/usd/usdPhysics/articulationRootAPI.h>
#include <pxr/usd/usdPhysics/revoluteJoint.h>
#include <pxr/usd/usdPhysics/rigidBodyAPI.h>
#include <pxr/usd/usdUtils/dependencies.h>
#include <algorithm>
#include <map>
#include <new>
#include <set>
#include "../../scene/native/usd_scene.hpp"
PXR_NAMESPACE_USING_DIRECTIVE
namespace {
using namespace mr_json;
struct Metadata {std::string error,json;};
std::string layer_json(const SdfLayerHandle& layer) {
  return object({{"identifier",text(layer->GetIdentifier())},
    {"real_path",text(layer->GetRealPath())},{"anonymous",boolean(layer->IsAnonymous())}});
}
}
extern "C" MR_MODEL_EXPORT int mr_prepared_usd_abi(){return 1;}
extern "C" MR_MODEL_EXPORT void* mr_prepared_usd_open(const char* path,const char* const* sets,
                                                    const char* const* selections,size_t count){
  Metadata* result=new(std::nothrow) Metadata;if(!result)return nullptr;
  try {
    if(!path||!*path||count>256||(count&&(!sets||!selections)))throw std::runtime_error("explicit USD path and at most 256 variant selections required");
    std::map<std::string,std::string> requested;
    for(size_t i=0;i<count;++i){
      if(!sets[i]||!*sets[i]||!selections[i]||!*selections[i])throw std::runtime_error("empty variant name/selection is unsupported");
      if(!requested.emplace(sets[i],selections[i]).second)throw std::runtime_error("duplicate requested variant set");
    }
    TfErrorMark errors;
    auto stage=UsdStage::Open(path,UsdStage::LoadAll);
    if(!stage)throw std::runtime_error("OpenUSD rejected stage");
    auto root=stage->GetDefaultPrim();
    if(!root||!root.IsActive()||!root.IsDefined())throw std::runtime_error("USD has no active defined default prim");
    const auto root_path=root.GetPath();
    // Select only into a new anonymous session layer: no on-disk USD is edited.
    auto session=stage->GetSessionLayer();
    if(!session||!session->IsAnonymous())throw std::runtime_error("stage session layer must be anonymous");
    UsdEditContext session_edit(stage,session);
    std::set<std::string> pending;
    for(const auto& kv:requested)pending.insert(kv.first);
    // A variant can reveal another variant set, so resolve actual composed sets
    // incrementally instead of assuming map iteration is a dependency order.
    while(!pending.empty()){
      bool progress=false;
      for(auto it=pending.begin();it!=pending.end();){
        root=stage->GetPrimAtPath(root_path);
        if(!root)throw std::runtime_error("variant removed USD default prim");
        auto variants=root.GetVariantSets();
        if(!variants.HasVariantSet(*it)){++it;continue;}
        auto variant=variants.GetVariantSet(*it);
        const auto names=variant.GetVariantNames();
        const auto& selected=requested.at(*it);
        if(std::find(names.begin(),names.end(),selected)==names.end()){++it;continue;}
        if(!variant.SetVariantSelection(selected))throw std::runtime_error("cannot select existing USD variant: "+*it);
        it=pending.erase(it);progress=true;
      }
      if(!progress)throw std::runtime_error("requested USD variant set or value does not exist in composed default prim: "+*pending.begin());
    }
    root=stage->GetPrimAtPath(root_path);
    if(!root||!root.IsActive()||!root.IsDefined())
      throw std::runtime_error("selected USD variants removed, deactivated or undefined the default prim");
    std::vector<std::string> variants;
    for(const auto& kv:requested){
      auto v=root.GetVariantSets().GetVariantSet(kv.first);
      if(!v||v.GetVariantSelection()!=kv.second)throw std::runtime_error("requested variants are not mutually composable");
      std::vector<std::string> available;for(const auto& name:v.GetVariantNames())available.push_back(text(name));
      variants.push_back(object({{"set",text(kv.first)},{"selection",text(kv.second)},{"available",list(available)}}));
    }
    const double meters=UsdGeomGetStageMetersPerUnit(stage);
    if(!std::isfinite(meters)||meters<=0)throw std::runtime_error("USD metersPerUnit must be positive finite");
    const auto axis=UsdGeomGetStageUpAxis(stage).GetString();
    if(axis!="Y"&&axis!="Z")throw std::runtime_error("USD up axis is unsupported");
    std::vector<SdfLayerRefPtr> dependencies;
    std::vector<std::string> assets,unresolved;
    if(!UsdUtilsComputeAllDependencies(SdfAssetPath(path),&dependencies,&assets,&unresolved)||!unresolved.empty())
      throw std::runtime_error("USD dependency resolution incomplete (all authored variants)");
    std::vector<std::string> layers,used,asset_json,bodies,joints;
    for(const auto& layer:dependencies)layers.push_back(layer_json(layer));
    for(const auto& layer:stage->GetUsedLayers())used.push_back(layer_json(layer));
    std::sort(assets.begin(),assets.end());assets.erase(std::unique(assets.begin(),assets.end()),assets.end());
    for(const auto& asset:assets)asset_json.push_back(text(asset));
    for(const auto& prim:stage->Traverse()){
      if(!prim.GetPrimIndex().GetLocalErrors().empty())
        throw std::runtime_error("USD prim composition has unresolved errors: "+prim.GetPath().GetString());
      if(prim.HasAPI<UsdPhysicsRigidBodyAPI>())bodies.push_back(text(prim.GetPath().GetString()));
      if(prim.IsA<UsdPhysicsRevoluteJoint>())joints.push_back(text(prim.GetPath().GetString()));
    }
    if(!errors.IsClean())throw std::runtime_error("OpenUSD reported an error during asset preparation");
    result->json=object({{"format",text("moonrobo.aligned-native-usd-metadata.v1")},
      {"openusd_version",text(std::to_string(PXR_MAJOR_VERSION)+"."+std::to_string(PXR_MINOR_VERSION)+"."+std::to_string(PXR_PATCH_VERSION))},
      {"default_prim",text(root_path.GetString())},{"default_prim_type",text(root.GetTypeName().GetString())},
      {"articulation_root_api",boolean(root.HasAPI<UsdPhysicsArticulationRootAPI>())},
      {"variants",list(variants)},{"meters_per_unit",number(meters)},{"up_axis",text(axis)},
      {"layers",list(layers)},{"used_layers",list(used)},{"assets",list(asset_json)},
      {"rigid_body_paths",list(bodies)},{"revolute_joint_paths",list(joints)},
      {"articulation_ir",moonrobo_scene::articulation_ir(stage,root)},
      {"dependency_scope",text("all authored references/payloads/asset paths, including unselected variants")},
      {"stage_files_modified","false"},{"python_used","false"},{"simulation_executed","false"},
      {"newton_model_constructed","false"},{"physical_equivalence_verified","false"}});
    if(result->json.size()>64u*1024u*1024u)throw std::runtime_error("USD metadata/scene IR exceeds 64 MiB limit");
  }catch(const std::exception& e){result->error=e.what();}
   catch(...){result->error="unknown native USD metadata failure";}
  return result;
}
extern "C" MR_MODEL_EXPORT const char* mr_prepared_usd_error(void* p){return p?static_cast<Metadata*>(p)->error.c_str():"USD metadata allocation failed";}
extern "C" MR_MODEL_EXPORT const char* mr_prepared_usd_json(void* p){return p?static_cast<Metadata*>(p)->json.c_str():"";}
extern "C" MR_MODEL_EXPORT void mr_prepared_usd_close(void* p){delete static_cast<Metadata*>(p);}
