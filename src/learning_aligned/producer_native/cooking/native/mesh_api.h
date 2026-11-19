#ifndef MOONROBO_COOKING_MESH_API_H
#define MOONROBO_COOKING_MESH_API_H
#include <stdint.h>
#include <stddef.h>
#if defined(_WIN32)
#define MR_MESH_EXPORT __declspec(dllexport)
#else
#define MR_MESH_EXPORT __attribute__((visibility("default")))
#endif
#ifdef __cplusplus
extern "C" {
#endif
MR_MESH_EXPORT int mr_host_mesh_abi(void);
// All byte spans are copied before return. The handle owns geometry arrays,
// the actual Warp Mesh/BVH and the loaded Warp library. Cleanup destroys the
// Mesh/BVH first, unloads Warp, then destroys the owned geometry vectors.
MR_MESH_EXPORT void* mr_host_mesh_open(const char* library,
 const uint8_t* points,size_t point_bytes,const uint8_t* velocities,size_t velocity_bytes,
 const uint8_t* indices,size_t index_bytes,const uint8_t* groups,size_t group_bytes,
 int constructor_type,int leaf_size,int winding_number);
MR_MESH_EXPORT const char* mr_host_mesh_error(void* mesh);
MR_MESH_EXPORT uint64_t mr_host_mesh_id(void* mesh);
MR_MESH_EXPORT void mr_host_mesh_refit_points(void* mesh,const uint8_t* points,size_t bytes);
MR_MESH_EXPORT void mr_host_mesh_close(void* mesh);
MR_MESH_EXPORT void mr_host_mesh_make_device(void* mesh,uint64_t context,uint64_t stream,int constructor_type,int leaf_size);
MR_MESH_EXPORT uint64_t mr_host_mesh_device_id(void* mesh);
MR_MESH_EXPORT void mr_host_mesh_sample(void* mesh,const uint8_t* points,size_t point_bytes,
 int sign_mode,float max_distance,float winding_threshold,uint8_t* output,size_t output_bytes);
MR_MESH_EXPORT void mr_host_mesh_refit_velocities(void* mesh,const uint8_t* values,size_t bytes);
MR_MESH_EXPORT void mr_host_mesh_enable_gradients(void* mesh);
MR_MESH_EXPORT void mr_host_mesh_zero_gradients(void* mesh);
MR_MESH_EXPORT void mr_host_mesh_gradient_snapshot(void* mesh,int device,int velocity,uint8_t* output,size_t bytes);
#ifdef __cplusplus
}
#endif
#endif
