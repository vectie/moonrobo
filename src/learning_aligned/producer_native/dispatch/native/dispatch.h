#pragma once
#include <stdint.h>
#include <stddef.h>
#if defined(_WIN32)
#define MRD_API __declspec(dllexport)
#else
#define MRD_API __attribute__((visibility("default")))
#endif
#ifdef __cplusplus
extern "C" {
#endif
typedef struct mrd_context mrd_context;
typedef struct mrd_buffer mrd_buffer;
typedef struct mrd_kernel mrd_kernel;
typedef struct mrd_conditional mrd_conditional;
typedef struct mrd_partition mrd_partition;
typedef struct mrd_graph mrd_graph;
MRD_API int mrd_abi(void);
MRD_API const char* mrd_error(void);
MRD_API mrd_context* mrd_open(const char*,uint64_t,uint64_t,int,int);
MRD_API void mrd_context_release(mrd_context*);
// Additive optional ABI-3 entry point: a new token sharing the same Device
// arena/actual owning CUDA context, without creating or borrowing a new one.
MRD_API mrd_context* mrd_context_retain(mrd_context*);
MRD_API uint64_t mrd_context_pointer(mrd_context*);
MRD_API uint64_t mrd_stream_pointer(mrd_context*);
MRD_API int mrd_architecture(mrd_context*);
MRD_API int mrd_synchronize(mrd_context*);
MRD_API int mrd_copy_external(mrd_context*,uint64_t,uint64_t,uint64_t,uint64_t);
MRD_API int mrd_zero_external(mrd_context*,uint64_t,uint64_t,uint64_t);
MRD_API mrd_buffer* mrd_allocate(mrd_context*,uint64_t);
MRD_API void mrd_buffer_release(mrd_buffer*);
MRD_API uint64_t mrd_buffer_pointer(mrd_buffer*);
MRD_API uint64_t mrd_buffer_size(mrd_buffer*);
MRD_API int mrd_write(mrd_buffer*,uint64_t,const uint8_t*,size_t);
MRD_API int mrd_read(mrd_buffer*,uint64_t,uint8_t*,size_t);
MRD_API mrd_kernel* mrd_load(mrd_context*,const char*,const char*,const char*,const char*,const char*,const char*,int,int,int,int);
MRD_API void mrd_kernel_release(mrd_kernel*);
// Additive optional ABI-3 query, genuine Warp occupancy information only.
MRD_API int mrd_suggested_block_size(mrd_kernel*,int,int*,int*);
// MRL1 is our bounded launch argument transport, not an APIC file format.
// Every vendor record is constructed using actual apic_types.h definitions.
MRD_API int mrd_launch(mrd_kernel*,const uint8_t*,size_t,mrd_buffer*const*,size_t,uint64_t);
MRD_API int mrd_scan(mrd_context*,mrd_buffer*,mrd_buffer*,uint64_t,uint64_t,int,int,int,int,int,int,uint64_t);
MRD_API mrd_partition* mrd_partition_create(mrd_context*,const uint8_t*,size_t,int);
MRD_API void mrd_partition_release(mrd_partition*);
MRD_API int mrd_segmented_sort(mrd_context*,mrd_buffer*,mrd_buffer*,mrd_partition*,uint64_t,uint64_t,int,uint64_t);
MRD_API mrd_conditional* mrd_conditional_begin(mrd_context*,mrd_buffer*,uint64_t,uint64_t,int,int,int,int);
MRD_API int mrd_conditional_enter(mrd_conditional*,int);
MRD_API int mrd_conditional_leave(mrd_conditional*);
MRD_API int mrd_conditional_finish(mrd_conditional*);
MRD_API void mrd_conditional_abort(mrd_conditional*);
MRD_API void mrd_conditional_release(mrd_conditional*);
MRD_API mrd_graph* mrd_graph_begin(mrd_context*,uint64_t);
MRD_API int mrd_graph_end(mrd_graph*);
MRD_API int mrd_graph_launch(mrd_graph*);
MRD_API void mrd_graph_release(mrd_graph*);
#ifdef __cplusplus
}
#endif
