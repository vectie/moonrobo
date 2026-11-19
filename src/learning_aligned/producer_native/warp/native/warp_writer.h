// Moonrobo's Python-free authoring ABI. This is not a replacement Warp header.
#pragma once
#include <stdint.h>
#include <stddef.h>
#if defined(_WIN32)
# define MRW_API __declspec(dllexport)
#else
# define MRW_API __attribute__((visibility("default")))
#endif
#ifdef __cplusplus
extern "C" {
#endif
typedef struct mrw_writer mrw_writer;
MRW_API int mrw_api_version(void);
MRW_API const char* mrw_error(mrw_writer*);
MRW_API mrw_writer* mrw_borrow(const char* library, uint64_t state, uint64_t context, uint64_t stream, int arch);
MRW_API mrw_writer* mrw_create(const char* library, int cpu, uint64_t context, uint64_t stream, int arch);
MRW_API int mrw_release(mrw_writer*);
MRW_API const char* mrw_version(mrw_writer*);
MRW_API const char* mrw_library(mrw_writer*);
MRW_API uint64_t mrw_state_pointer(mrw_writer*);
MRW_API int mrw_begin(mrw_writer*);
MRW_API int mrw_end(mrw_writer*);
MRW_API uint32_t mrw_operation_count(mrw_writer*);
MRW_API uint32_t mrw_register_region(mrw_writer*, uint64_t pointer, uint64_t capacity, uint32_t element_size);
MRW_API int mrw_snapshot_region(mrw_writer*, uint32_t region, uint64_t pointer, uint64_t capacity, uint32_t element_size, int transient);
MRW_API int mrw_register_module(mrw_writer*, const char* hash, const char* name, const char* binary_filename);
MRW_API int mrw_register_kernel(mrw_writer*, const char* key, const char* hash, const char* forward, const char* backward, int forward_smem, int backward_smem, int block_dim);
MRW_API int mrw_register_binding(mrw_writer*, const char* name, uint32_t region);
MRW_API int mrw_register_pointer_location(mrw_writer*, uint32_t region, uint64_t offset, uint64_t stride);
MRW_API int mrw_register_mesh(mrw_writer*, uint64_t mesh);
MRW_API int mrw_save(mrw_writer*, const char* path);
// Owned host storage stays alive until release. No MoonBit/foreign pointer is retained.
MRW_API uint32_t mrw_host_region(mrw_writer*, const uint8_t* bytes, uint64_t count, uint32_t element_size);
MRW_API uint64_t mrw_host_pointer(mrw_writer*, uint32_t region);
MRW_API int mrw_host_memset(mrw_writer*, uint32_t region, uint64_t offset, int value, uint64_t count);
MRW_API int mrw_host_copy(mrw_writer*, uint32_t destination, uint64_t destination_offset, uint32_t source, uint64_t source_offset, uint64_t count);
#ifdef __cplusplus
}
#endif
