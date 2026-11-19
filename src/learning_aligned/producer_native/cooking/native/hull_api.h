#pragma once
#include "mesh_api.h"
#ifdef __cplusplus
extern "C" {
#endif
MR_MESH_EXPORT int mr_convex_hull_abi(void);
MR_MESH_EXPORT void* mr_convex_hull_open(const char* qhull_library,const uint8_t* points,size_t bytes,int max_vertices);
MR_MESH_EXPORT const char* mr_convex_hull_error(void* hull);
MR_MESH_EXPORT const uint8_t* mr_convex_hull_points(void* hull,size_t* bytes);
MR_MESH_EXPORT const uint8_t* mr_convex_hull_indices(void* hull,size_t* bytes);
MR_MESH_EXPORT int mr_convex_hull_joggled(void* hull);
MR_MESH_EXPORT void mr_convex_hull_close(void* hull);
#ifdef __cplusplus
}
#endif
