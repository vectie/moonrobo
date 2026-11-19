#pragma once
#include "mesh_api.h"
#ifdef __cplusplus
extern "C" {
#endif
MR_MESH_EXPORT int mr_cooked_field_abi(void);
MR_MESH_EXPORT void* mr_cooked_field_open(const char* library,int kind,const uint8_t* data,size_t bytes,
 int nx,int ny,int nz,int channels,int dtype,const uint8_t* placement,size_t placement_bytes,float background);
MR_MESH_EXPORT const char* mr_cooked_field_error(void* field);
MR_MESH_EXPORT uint64_t mr_cooked_field_host_id(void* field);
MR_MESH_EXPORT uint64_t mr_cooked_field_device_id(void* field);
MR_MESH_EXPORT uint64_t mr_cooked_field_array_id(void* field);
MR_MESH_EXPORT void mr_cooked_field_make_device(void* field,uint64_t context,uint64_t stream);
MR_MESH_EXPORT const uint8_t* mr_cooked_field_snapshot(void* field,size_t* bytes);
MR_MESH_EXPORT void mr_cooked_field_close(void* field);
MR_MESH_EXPORT void* mr_cooked_volume_open_tiles(const char* library,const uint8_t* tiles,size_t tile_bytes,
 const uint8_t* values,size_t value_bytes,const uint8_t* placement,size_t placement_bytes,float background);
MR_MESH_EXPORT void mr_cooked_volume_sample(void* field,const uint8_t* xyz,size_t xyz_bytes,uint8_t* output,size_t output_bytes);
#ifdef __cplusplus
}
#endif
