/* Warp 1.17's genuine exported C compile APIs. No CUDA context, wp_init,
 * Python, driver initialization, module loading or kernel execution here.
 * The explicitly invoked compile calls do use MathDx/NVRTC/NVJitLink. */
#include <moonbit.h>
#include <stdbool.h>
#include <stdint.h>
#include <stddef.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#if defined(_WIN32)
#include <windows.h>
#else
#include <dlfcn.h>
#endif
#if defined(MOONROBO_TILE_VERIFY_WARP_HEADERS)
#include <type_traits>
#include "warp.h"
#endif

typedef struct {
    void* library;
    const char* (*version)(void);
    const char* (*mathdx_version)(void);
    const char* (*get_error)(void);
    int (*cuda_enabled)(void);
    int (*mathdx_enabled)(void);
    bool (*solver)(const char*, const char*, const char*, int, const char**,
                   const char*, int, int, int, int, int, int, int, int, int, int, int, int);
    size_t (*program)(const char*, const char*, int, const char*, const char*, int,
                      const char**, bool, int, bool, bool, bool, bool, bool, bool,
                      bool, const char*, const char*, size_t, char**, size_t*, int*);
    char error[2048];
} TileBackend;

#if defined(MOONROBO_TILE_VERIFY_WARP_HEADERS)
#define VERIFY(field, symbol) static_assert(std::is_same_v<decltype(TileBackend::field), decltype(&symbol)>, "Warp C ABI mismatch: " #symbol)
VERIFY(version, wp_version);
VERIFY(mathdx_version, wp_libmathdx_version);
VERIFY(get_error, wp_get_error_string);
VERIFY(cuda_enabled, wp_is_cuda_enabled);
VERIFY(mathdx_enabled, wp_is_mathdx_enabled);
VERIFY(solver, wp_cuda_compile_solver);
VERIFY(program, wp_cuda_compile_program);
#undef VERIFY
#endif

static moonbit_bytes_t copied(const char* value) {
    if (!value) value = "";
    size_t n = strlen(value);
    if (n > INT32_MAX) n = 0;
    moonbit_bytes_t result = moonbit_make_bytes((int32_t)n, 0);
    if (n) memcpy(result, value, n);
    return result;
}
static int clean(moonbit_bytes_t value) {
    return Moonbit_array_length(value) > 0 && !memchr(value, 0, (size_t)Moonbit_array_length(value));
}
static void cleanup(void* object) {
    TileBackend* backend = (TileBackend*)object;
    if (!backend->library) return;
#if defined(_WIN32)
    FreeLibrary((HMODULE)backend->library);
#else
    dlclose(backend->library);
#endif
    backend->library = NULL;
}
static void* symbol(TileBackend* backend, const char* name) {
#if defined(_WIN32)
    return (void*)GetProcAddress((HMODULE)backend->library, name);
#else
    return dlsym(backend->library, name);
#endif
}
static int alive(TileBackend* backend) {
    if (!backend->library && !backend->error[0]) strcpy(backend->error, "closed MathDx compiler");
    return backend->library && !backend->error[0];
}
static void failed(TileBackend* backend, const char* stage, size_t code) {
    const char* detail = backend->get_error ? backend->get_error() : "";
    snprintf(backend->error, sizeof(backend->error), "%s failed (status %zu); Warp diagnostics are written to stderr%s%.1500s",
             stage, code, detail && *detail ? ": " : "", detail ? detail : "");
}
MOONBIT_FFI_EXPORT TileBackend* mr_tile_open(moonbit_bytes_t path) {
    TileBackend* backend = (TileBackend*)moonbit_make_external_object(cleanup, sizeof(TileBackend));
    memset(backend, 0, sizeof(*backend));
    if (!clean(path)) { strcpy(backend->error, "explicit NUL-free Warp library path required"); return backend; }
#if defined(_WIN32)
    backend->library = LoadLibraryA((const char*)path);
#else
    backend->library = dlopen((const char*)path, RTLD_NOW | RTLD_LOCAL);
#endif
    if (!backend->library) { strcpy(backend->error, "cannot load explicit Warp native library and dependencies"); return backend; }
#define LOAD(field, name) do { *(void**)(&backend->field) = symbol(backend, name); if (!backend->field) { snprintf(backend->error, sizeof(backend->error), "Warp native API missing %s", name); return backend; } } while (0)
    LOAD(version, "wp_version");
    LOAD(cuda_enabled, "wp_is_cuda_enabled");
    LOAD(mathdx_enabled, "wp_is_mathdx_enabled");
    LOAD(mathdx_version, "wp_libmathdx_version");
    LOAD(get_error, "wp_get_error_string");
    LOAD(solver, "wp_cuda_compile_solver");
    LOAD(program, "wp_cuda_compile_program");
#undef LOAD
    const char* version = backend->version();
    if (!version || strcmp(version, "1.17.0")) strcpy(backend->error, "exact Warp 1.17.0 native ABI required");
    else if (!backend->cuda_enabled() || !backend->mathdx_enabled()) strcpy(backend->error, "Warp must be built with CUDA and MathDx; disabled false stubs are unsupported");
    return backend;
}
MOONBIT_FFI_EXPORT moonbit_bytes_t mr_tile_error(TileBackend* backend) { return copied(backend->error); }
MOONBIT_FFI_EXPORT moonbit_bytes_t mr_tile_mathdx_version(TileBackend* backend) { return copied(alive(backend) ? backend->mathdx_version() : ""); }
MOONBIT_FFI_EXPORT void mr_tile_close(TileBackend* backend) { cleanup(backend); strcpy(backend->error, "closed MathDx compiler"); }

MOONBIT_FFI_EXPORT int32_t mr_tile_solver(TileBackend* backend, moonbit_bytes_t fatbin,
    moonbit_bytes_t ltoir, moonbit_bytes_t function_name, int32_t arch, int32_t n,
    int32_t nrhs, int32_t solve, int32_t precision, int32_t threads) {
    if (!alive(backend)) return 0;
    if (!clean(fatbin) || !clean(ltoir) || !clean(function_name) || n < 1 || n > 64 ||
        nrhs < 1 || nrhs > 64 || (solve != 0 && solve != 1) ||
        (precision != 5 && precision != 6) ||
        (threads != 32 && threads != 64 && threads != 128 && threads != 256)) {
        strcpy(backend->error, "invalid cuSolverDx compilation arguments"); return 0;
    }
    /* Exact builtins.py/build_lto_solver enums: POTRF=2/POTRS=3,
     * side/diag unspecified=-1, REAL, ROW_MAJOR=1, UPPER=0. The libmathdx
     * Warp implementation requires all three legacy include arguments empty. */
    bool ok = backend->solver((const char*)fatbin, (const char*)ltoir, (const char*)function_name,
        0, NULL, NULL, arch, n, n, solve ? nrhs : 1, solve ? 3 : 2,
        -1, -1, precision, 1, 1, 0, threads);
    if (!ok) failed(backend, "wp_cuda_compile_solver", 1);
    return ok ? 1 : 0;
}

MOONBIT_FFI_EXPORT int32_t mr_tile_program(TileBackend* backend, moonbit_bytes_t source,
    moonbit_bytes_t native, moonbit_bytes_t* includes, moonbit_bytes_t output, int32_t arch,
    moonbit_bytes_t* ltoirs, moonbit_bytes_t fatbin) {
    if (!alive(backend)) return 0;
    int ninclude = Moonbit_array_length(includes), nlto = Moonbit_array_length(ltoirs);
    if (!clean(source) || !clean(native) || !clean(output) || nlto < 1 || nlto > 2 ||
        !Moonbit_array_length(fatbin) || ninclude < 0 || ninclude > 64) {
        strcpy(backend->error, "invalid MathDx source, include or link inputs"); return 0;
    }
    for (int i=0; i<ninclude; ++i) if (!clean(includes[i])) { strcpy(backend->error, "invalid include path"); return 0; }
    char* data[3]; size_t sizes[3]; int types[3];
    for (int i=0; i<nlto; ++i) {
        if (!Moonbit_array_length(ltoirs[i])) { strcpy(backend->error, "empty MathDx LTOIR"); return 0; }
        data[i]=(char*)ltoirs[i]; sizes[i]=(size_t)Moonbit_array_length(ltoirs[i]);
        types[i]=3; /* genuine nvJitLinkInputType LTOIR, build.py:21 */
    }
    data[nlto]=(char*)fatbin; sizes[nlto]=(size_t)Moonbit_array_length(fatbin); types[nlto]=4; /* FATBIN */
    /* The genuine Warp function performs NVRTC -dlto then nvJitLink with these
     * borrowed bytes synchronously. Size_t return is a status: ZERO succeeds.
     * No PCH/cache, fast math, FMA contraction, debug or implicit architecture. */
    size_t result = backend->program((const char*)source, "moonrobo-mathdx-tile.cu", arch, "",
        (const char*)native, ninclude, ninclude ? (const char**)includes : NULL,
        false, 3, false, false, false, false, false, false, false,
        (const char*)output, NULL, (size_t)nlto+1, data, sizes, types);
    if (result != 0) failed(backend, "wp_cuda_compile_program/NVJitLink", result);
    return result == 0 ? 1 : 0;
}
