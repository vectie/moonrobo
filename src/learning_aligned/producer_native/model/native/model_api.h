#ifndef MOONROBO_PRODUCER_MODEL_API_H
#define MOONROBO_PRODUCER_MODEL_API_H
#include <stddef.h>
#include <stdint.h>
#if defined(_WIN32)
#define MR_MODEL_EXPORT __declspec(dllexport)
#else
#define MR_MODEL_EXPORT __attribute__((visibility("default")))
#endif
#ifdef __cplusplus
extern "C" {
#endif
// Returned handles own all returned strings/bytes until close. Errors never throw
// across this C ABI. No function creates mjData or advances a simulation.
MR_MODEL_EXPORT int mr_prepared_model_abi(void);
MR_MODEL_EXPORT void* mr_prepared_model_open(const char* mujoco_library, const char* mjcf);
MR_MODEL_EXPORT const char* mr_prepared_model_error(void* model);
MR_MODEL_EXPORT const char* mr_prepared_model_json(void* model);
MR_MODEL_EXPORT const uint8_t* mr_prepared_model_mjb(void* model, size_t* size);
MR_MODEL_EXPORT void mr_prepared_model_close(void* model);
// OpenUSD is an independent optional plugin, not a CPython/Kit dependency.
MR_MODEL_EXPORT int mr_prepared_usd_abi(void);
MR_MODEL_EXPORT void* mr_prepared_usd_open(const char* usd, const char* const* sets,
                                        const char* const* selections, size_t count);
MR_MODEL_EXPORT const char* mr_prepared_usd_error(void* usd);
MR_MODEL_EXPORT const char* mr_prepared_usd_json(void* usd);
MR_MODEL_EXPORT void mr_prepared_usd_close(void* usd);
#ifdef __cplusplus
}
#endif
#endif
