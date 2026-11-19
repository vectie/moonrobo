// Genuine-header syntax fixture only. This file is never linked or executed.
#define WP_ENABLE_MATHDX 0
#include "builtin.h"
#include <type_traits>
static_assert(sizeof(wp::array_t<float>)==56);
static_assert(sizeof(wp::launch_bounds_t<1>)==24);
static_assert(std::is_same_v<decltype(wp::index(std::declval<wp::array_t<float>>(),0,0,0)),float&>);
void genuine_metric_primitives(wp::array_t<int> failure,wp::array_t<float> values) {
  float x=wp::index(values,0,0);
  float y=wp::sqrt(wp::max(1.0e-15f,x));
  if(!wp::isfinite(y))wp::atomic_or(failure,0,1);
  wp::index(values,0,0)=y;
}
// Full multi-hyphen logical keys must map to legal actual entry identifiers.
extern "C" void mr_mjw_metric_copy_backbone_rhs(wp::launch_bounds_t<1>);
extern "C" void mr_mjw_metric_fold_contact_rank1(wp::launch_bounds_t<1>);
extern "C" void mr_mjw_metric_add_tendon_qh_diag(wp::launch_bounds_t<1>);
extern "C" void mr_mjw_metric_add_actuator_qh_diag(wp::launch_bounds_t<1>);
