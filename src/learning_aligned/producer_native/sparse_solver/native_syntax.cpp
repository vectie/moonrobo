// Syntax-only fixture against genuine Warp 1.17 headers. Never linked/run.
// It validates the actual non-owning tile template and array atomic overloads.
#define WP_ENABLE_MATHDX 0
#include "builtin.h"
#include "tile_cholesky.h"
#include "tile_solve.h"
#include <type_traits>
static_assert(sizeof(wp::array_t<float>) == 56);
static_assert(sizeof(wp::launch_bounds_t<1>) == 24);
static_assert(std::is_same_v<decltype(wp::index(std::declval<wp::array_t<float>>(),0,0)),float&>);

template<class T,int N> void actual_tile_templates(T* a,T* b,wp::array_t<T> factor,wp::array_t<int> failure) {
    using ALayout=wp::tile_layout_strided_t<wp::tile_shape_t<N,N>>;
    using BLayout=wp::tile_layout_strided_t<wp::tile_shape_t<N>>;
    wp::tile_shared_t<T,ALayout,false> A(a,nullptr,true);
    wp::tile_shared_t<T,BLayout,false> B(b,nullptr,true);
    wp::tile_cholesky_inplace<true>(0,A);
    wp::tile_cholesky_solve_inplace<true>(0,A,B);
    wp::atomic_sub(factor,0,0,T(1));
    wp::atomic_or(failure,0,1);
}
template void actual_tile_templates<float,1>(float*,float*,wp::array_t<float>,wp::array_t<int>);
template void actual_tile_templates<float,3>(float*,float*,wp::array_t<float>,wp::array_t<int>);
template void actual_tile_templates<float,7>(float*,float*,wp::array_t<float>,wp::array_t<int>);
template void actual_tile_templates<float,32>(float*,float*,wp::array_t<float>,wp::array_t<int>);
template void actual_tile_templates<float,64>(float*,float*,wp::array_t<float>,wp::array_t<int>);
template void actual_tile_templates<double,1>(double*,double*,wp::array_t<double>,wp::array_t<int>);
template void actual_tile_templates<double,7>(double*,double*,wp::array_t<double>,wp::array_t<int>);
template void actual_tile_templates<double,64>(double*,double*,wp::array_t<double>,wp::array_t<int>);
