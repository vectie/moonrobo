# Warp MathDx tile solver native chain

This package connects MoonBit to the real Warp **1.17.0** exported C compile
interfaces. Original Python and the CPU/Double `factorization` implementation
remain available. The new GPU compile and execution paths have **not been
run**. Source generation is not evidence of a working GPU image or equivalent
physical/numerical results.

`lower(Request)` generates actual CUDA entry points calling cuSolverDx POTRF
and, for `factor-solve`, POTRS. It never loads a library or performs numerical
work. `validate_bindings` proves the exact host-side dtype, shape, contiguous
strides, alignment, actual capacity and distinct allocation owners. There are
no gradients, pivoting, regularization, generic LU or fallback dense solvers.

`decode_config(Json)` strictly decodes the native compilation request.
`compile_artifact(CompileConfig)` is a separate explicit, deferred operation:

1. Verify exact upstream primary SHA pins and snapshot every supplied Warp
   header, then compile from the snapshot directory. The existing output
   directory is refused. Merely reading reference `.py` source never executes
   Python.
2. Load the explicitly selected Warp library. Only query `wp_version`,
   `wp_is_cuda_enabled`, `wp_is_mathdx_enabled` and `wp_libmathdx_version`.
   Refuse another Warp version or a build with disabled CUDA/MathDx stubs.
   There is no `wp_init`, context creation, driver initialization, module load
   or kernel launch in this package.
3. Call **`wp_cuda_compile_solver`** for POTRF and optional POTRS. This genuine
   C API uses libmathdx's cuSolverDx descriptor to write real LTOIR and a
   universal FATBIN. Its three legacy include arguments must be exactly
   `0, nullptr, nullptr`; no MathDx include-path argument is invented.
4. Pass the generated LTOIR and exactly one identical universal FATBIN to
   **`wp_cuda_compile_program`**. Warp compiles the shader with NVRTC LTO and
   links through `nvJitLinkCreate`, `nvJitLinkAddData`, `nvJitLinkComplete` and
   `nvJitLinkGetLinkedCubin`. The returned `size_t` is a status: **zero means
   success**, not an image byte count. Only an actual nonempty CUBIN gets a
   success manifest. No C++ template is looked up with `dlsym`.

The fresh artifact contains CUDA source, pinned primary references, supplied
headers, actual LTOIR/FATBIN/CUBIN bytes and SHA256s, native Warp-library SHA,
MathDx version and typed launch policy. CUDA SDK include bytes and transitive
native dependencies are explicitly not attested. Compiler diagnostics go to
Warp's stderr and are not falsely described as a captured log. A failure may
leave intermediate files, but never a successful manifest.

## Supported layout and launch contract

`Request` fields are `operation`, `dtype`, `tile_size`, `rhs_columns`,
`batch_size`, `block_dim`, `architecture`. The operation is `factor` or
`factor-solve`; standalone solving from an untrusted factor is refused.

- Scalar type is `float32` or `float64`. Tiles are independent row-major dense
  `[batch_size, tile_size, tile_size]` arrays, with tile size 1..64. There is no
  implicit float32 narrowing of CPU/Double seeds.
- `factor` accepts matrix input and factor output plus `int32 status[batch]`.
  It requires the explicit unused RHS sentinel `rhs_columns == 1`.
- `factor-solve` also accepts RHS and solution arrays of
  `[batch_size, tile_size, rhs_columns]`, with RHS columns 1..64. All arrays
  have distinct owned allocations and exact C-contiguous strides.
- POTRF uses upper fill mode and row-major arrangements. Every thread in the
  CUDA block participates. Lower output entries are explicitly zeroed,
  matching genuine Warp tile Cholesky. Only successful finite positive
  factors reach POTRS. Nonfinite inputs or results produce failure status and
  zeroed outputs. No result can be published unless **all status entries are
  zero**. A positive status is the actual POTRF `info`; `-1` is additional
  nonfinite/invalid-factor rejection. Status is overwritten per invocation;
  callers must not bury failures in a loop or overwrite status before checking.
- One CUDA block handles one whole tile. Compile-time block size is exactly
  32, 64, 128 or 256. Metadata launch shape is
  `[batch_size * block_dim]`, with genuine `launch_bounds_t<1>` by value,
  `coord_mult=1`, `grid_stride=false`, cluster dimension one and zero dynamic
  shared memory. A lean 3D CUDA grid is flattened by block index, with a
  uniform whole-block out-of-range return. Thread count, shape and bounds must
  match; an ordinary one-thread-per-tile launch would be incorrect.
- Explicit shader-body static storage is bounded to 48 KiB. This includes the
  full original tile and RHS; sizes are never reduced to fit. MathDx internal
  static storage/occupancy and real device limits await compilation. An
  unsupported MathDx specialization fails compilation; there is no scalar
  success fallback. Architectures are explicit and never silently capped or
  changed to another target.

This independent dense-tile interface is not the complete mixed CSR/gather
factorization path. Actual MuJoCo block selection, CSR gather/scatter,
compact/sparse tail processing, world masks and complete constraint-Newton
solver scheduling remain outside this new GPU module. All manifests state
`physics_solver_closure_generated:false`,
`mixed_sparse_gather_closure_generated:false`, and
`runtime_equivalence_verified:false`. Existing CPU mixed routines retain their
actual layouts and remain the deferred differential baseline.

## Primary source evidence

Exact references come from the published Warp `v1.17.0` source tree. No source
module has been imported or executed during this task.

| Source | Relevant contract | SHA256 |
| --- | --- | --- |
| `native/warp.h:801,855` | Actual compile C signatures | `8dba30fadc4315eb7d08795888b822c2d7e30b4a0057861c5d41431310cf8c8b` |
| `native/warp.cu:4888,5171` | NVRTC/NVJitLink and cuSolverDx descriptors | `f8b9f4cef163b2c24fd45e8ded06d608c99d0392b8f89b45bef2931fa143c709` |
| `native/mathdx.cpp` | Disabled-build APIs return false | `a8737e3144a800c88a6ac40d95d4422b134561524efdcaa8670cd1d8abc4e3a5` |
| `_src/build.py:21,613` | Link enum values, LTOIR plus FATBIN, legacy include nulls | `63d84f6814789a95366c9ef155fa2b35b566e53a5dae84ce316d650e16cd5513` |
| `_src/builtins.py:16554,16659,16940` | POTRF=2, POTRS=3; FP32=5/FP64=6; row-major=1, upper=0; device function signatures | `24f5d991a21d480d43e26db91753528a4c2d9441dd9be9eb1aec380ea4ca6be6` |
| `native/tile_cholesky.h:408` | POTRF collective call and opposite-triangle clearing | `2941d27c329535c63f9f8b0e23dc414bc4d1a70f33b8242291982be4fad224f5` |
| `native/tile_solve.h` | POTRS collective call and synchronization | `c0976c1b1072781ec7890ec7074fd964690f54ab8d84832f1f8b2c467112efbf` |
| `native/builtin.h` | Genuine array/bounds and floating helpers | `9a8c44dda8453dcee2308ec016a648da43bc77d41427c7694b6555a1f810d7bf` |
| `native/array.h` | Actual by-value array ABI | `f85ab644afcf70be5b9feb6097fd9ffe4dfe22d5f88948c511609dac60b2d07a` |

The C stub has syntax-only signature assertions against genuine `warp.h` for
both compile functions and every query. MoonBit check/info/fmt and source
inspection are permitted verification only. Pending host regression sources
cover metadata, cooperative shape, exact byte layout, alias/capacity rejection,
unsupported sizes/budgets and strict JSON. They have not run. POTRF/POTRS
specializations, native library opening, GPU shader compilation, numerical
factor/solve checks, status gating and upstream differential tests all await
the available machine.
