# Native mixed CSR factorization and sparse solve

This package contains complete generated GPU bodies for the supported
MuJoCo-Warp **3.15.0** inertia factor/solve dataflow. It preserves the original
Python implementation and the separate CPU/Double `factorization` baseline.
The GPU compiler, kernels, numerical examples and tests have **not run**.

The implementation uses actual Warp **1.17.0** by-value arrays, native atomic
operations, non-owning shared tiles, `tile_cholesky_inplace<true>(0,A)` and
`tile_cholesky_solve_inplace<true>(0,A,B)`. The zero function argument selects
Warp's genuine cooperative scalar fallback. It does not invent a C symbol for
a template. It does not claim MathDx acceleration: the separate `tile_solver`
package retains the real MathDx LTO/FATBIN/NVJitLink path.

## Actual mixed lifecycle

`lower(Request)` produces three callable entries in one CUBIN source module:

| Entry | Actual upstream interface | Numeric arrays |
| --- | --- | --- |
| `mixed-factor` | `factor_m`, `_factor_blocks`, `_factor_i_sparse` | matrix → factor, diagonal |
| `mixed-solve` | `solve_LD`, `solve_m` | factor, diagonal, rhs → solution |
| `mixed-factor-solve` | `factor_solve_i`, scalar/gather fused block factories | matrix, rhs → factor, diagonal, solution |

The request contains actual `factorization.MixedLayout`, `dtype`, `nworld`,
`block_dim`, `architecture`, and `check_done`. It is not a matrix-value request:
layout planning performs no numerical factorization. Layout validation is
shared directly with the CPU baseline through `describe_mixed_layout`.

- Actual `tree_dofadr/tree_dofnum` identify contiguous independent tree blocks;
  CSR rows are contiguous, strictly sorted lower columns with diagonal last.
  The actual `qLD_block_adr` and `qLD_block_total` must match source policy.
- Compact blocks through six DOFs use `-2` and reciprocal diagonal storage.
  Full triangular blocks through six DOFs use the source scalar upper
  Cholesky loop. Fused scalar factor-solve keeps the forward RHS live during
  factorization, matching the actual fused source factory.
- Other blocks through 64 DOFs use their **original** size and the exact
  symmetric CSR gather map, including missing-pair `nC` sentinel reads of zero.
  This includes branched blocks of six or fewer DOFs. Gather uses genuine
  shared-tile factor/solve operations and scatters the complete upper factor,
  including zeroed lower triangle, to its actual dense-prefix offset.
- Oversized trees retain packed sparse storage. Factorization copies the
  **entire** `nC` matrix, including dense/compact tree entries, after the dense
  factor prefix. It then executes actual reverse depth-level LDL updates with
  native atomic subtraction and a barrier after every level. Source rows and
  target-prefix compatibility are validated, so same-level reads remain
  immutable while targets accumulate. There is no global densification.
- Whenever a sparse tail exists, inverse diagonals are written for **all nv**
  from the tail after factorization. Dense factors ignore those D entries;
  compact and sparse solves use them. Without a sparse tail, full dense blocks
  preserve unused inverse-diagonal seed entries. Scalar factors preserve
  unused lower seed slots; gather factors zero them.
- Sparse solve performs actual sparse-only RHS copy, reverse-level UP atomic
  subtraction, reciprocal diagonal multiplication, and forward-level DOWN
  subtraction. Each level has the same synchronization dependency as the
  pinned `_solve_LD_sparse_fused` kernel. Dense and compact solutions occupy
  their own DOF ranges and remain intact.

One cooperative CUDA block owns a whole world and processes its actual tree
blocks and levels. Different worlds run independently; no grid synchronization
is assumed. Launch shape is `[nworld*block_dim]` with real rank-one bounds,
`grid_stride=false`, `coord_mult=1`, cluster dimension one, and zero dynamic
shared memory. Whole blocks flatten the actual lean 3D CUDA grid. Gather scratch
is sized to the largest actual gather block in this model (at most 64), never a
replacement smaller block. Thread counts are explicit multiples of 32 through
1024; real hardware/compiler resource acceptance still awaits compilation.
The model supports up to 65536 DOFs and each owned numeric view is bounded by
the pipeline's 256 MiB owner capacity. These are explicit storage limits, not
small demonstration dimensions.

## Genuine non-symmetric sparse LU

`lower_lu(LuRequest)` emits `sparse-lu-factor-solve`, translating
`_factor_solve_lu_sparse_fused` and `factor_solve_lu`:

1. Store each actual remaining CSR row count in the solution scratch, as the
   source does. The DOF bound makes every count exactly representable in FP32.
2. Eliminate from the last diagonal toward the first, scanning predecessor
   rows and merging actual sorted row columns. Store upper multipliers and
   update matching packed entries in place.
3. Execute the actual `(U+I)` backward pass followed by the `L` forward pass
   and nonzero diagonal division. There is no pivoting or symmetrization.

`LuLayout` uses `d_rownnz`, `d_rowadr`, `d_diag`, `d_colind`; `d_diag` is a
**relative index inside the row**, not an absolute address. CSR is checked for
contiguity, sorted in-range columns and the actual diagonal. Symbolic reverse
elimination closure is proved so a potentially nonzero fill term cannot be
silently discarded. Arbitrary nonclosed CSR and pivot-requiring profiles are
rejected. The `lu[world,nD]` input is overwritten with its real factor. RHS must
not alias solution because the source first uses solution as row-count scratch.
This kernel keeps the original per-world serial elimination arithmetic; the
GPU implementation does not pretend that a generic dense solver is sparse LU.

## Binding, state and failure contracts

`validate_bindings(request,key,bindings)` checks exact typed C-contiguous
shapes, byte strides, alignment, real capacities and owned allocation identity.
Matrix is `[world,nC]`; factor is `[world,dense_prefix+(has_sparse?nC:0)]`;
diagonal/RHS/solution are `[world,nv]`. All-compact models omit the empty factor
parameter and require no zero-byte GPU allocation. Mixed RHS and solution may
share exactly the same view, preserving upstream `solve_LD(res,res)` support;
other allocations must be independent. LU has separate
`validate_lu_bindings` and refuses RHS/scratch aliasing.

`Lowered.metadata` contains real little-endian int32 buffers with dtype, shape,
bytes and SHA. Mixed parameters are `row_nnz`, `row_adr`, `factor_adr`, `blocks`
(`start,size,kind,factor_offset,gather_offset`), `gather_indices`, `updates`
(`i,k,Madr_ki`) and `level_offsets`. Empty logical gather/update lists carry the
same harmless dummy-storage convention while loops still have zero work.
LU metadata contains its four actual CSR arrays. `validate_metadata` and
`validate_lu_metadata` compare **actual initial view bytes**, not hashes alone,
against every derived array. All metadata owners must remain immutable for the
entire program, including every branch and while body.

Every entry has sticky `failure: int32[world]`. Check once with
`validate_initial_failure` that its actual initial owner is all zero. No kernel
clears failure. Existing failures skip subsequent invocations; nonfinite
arithmetic or invalid pivots set a bit with real atomic OR. Mixed entry gating
uses a lane-zero snapshot plus a barrier before any lane can change failure,
preventing late lanes from taking a different return path around barriers.
Publication requires every failure entry to remain zero. Graph/loop planners
must protect this owner from any clear/copy or unrelated producer, retain
factor/diagonal provenance, and bind the same layout/workspace through the
lifecycle. Outputs written before use must not be validated as though they
were initial matrix inputs.

`check_done=true` adds a whole-world `done: bool[world]` wrapper that preserves
already-finished world state. This is an explicit iteration embedding wrapper;
the original inertia routines do not themselves accept `ctx_done`. The done
owner may be updated only by the authenticated convergence producer between
invocations. It is not an immutable model mapping.

## Compilation and source evidence

`decode_config` / `decode_lu_config` strictly decode compilation records.
`compile_artifact` / `compile_lu_artifact` explicitly invoke the existing
MoonBit → NVRTC **C ABI** compiler with fixed CUBIN target, C++17, device default
execution and `--fmad=false`. Explicit CUDA include paths are recorded. Full
supplied native header bytes are passed as virtual NVRTC headers and preserved;
primary ABI/tile headers and MuJoCo-Warp sources must match exact pins.
Compilation creates no CUDA context and executes no kernel. Only a successful
nonempty CUBIN produces a success manifest in a fresh output directory. There
are no Python imports or Python compiler steps.

| Primary source | Ported contract | SHA256 |
| --- | --- | --- |
| MuJoCo-Warp 3.15 `_src/smooth.py:1147..1320,3334..3829` | Scalar/gather/mixed/sparse LDL factor+solve and non-symmetric sparse LU | `6268f0e1b6cb4c9ec6bbd3aa29828dfb36224efb2a3a3e1f54e5f87b6623fdef` |
| MuJoCo-Warp 3.15 `_src/io.py:237..290,1133..1205` | Actual tree partition, thresholds, CSR update grouping and gather indices | `2334b394e8f319f0fd2a2957240cdcc77a998513be11767a00f55f26ae07f4b0` |
| Warp 1.17 `native/tile.h` | Non-owning shared tile layouts and synchronization | `27cf1ea9f52814d51174b98df4904899e9ff32a3923ccf6635458c12d5893f4f` |
| Warp 1.17 `native/tile_cholesky.h` | Actual upper cooperative factor and lower-zeroing fallback | `2941d27c329535c63f9f8b0e23dc414bc4d1a70f33b8242291982be4fad224f5` |
| Warp 1.17 `native/tile_solve.h` | Actual upper `U^T/U` vector solve fallback | `c0976c1b1072781ec7890ec7074fd964690f54ab8d84832f1f8b2c467112efbf` |
| Warp 1.17 `native/builtin.h` | Genuine bounds, math and atomic primitive ABI | `9a8c44dda8453dcee2308ec016a648da43bc77d41427c7694b6555a1f810d7bf` |
| Warp 1.17 `native/array.h` | Genuine by-value arrays and typed atomic overloads | `f85ab644afcf70be5b9feb6097fd9ffe4dfe22d5f88948c511609dac60b2d07a` |

The source distribution has no `_src/matrix.py`; these actual matrix routines
live in `smooth.py`, with layout construction in `io.py`. Newton's dense
constraint Hessian may couple the original independent mass trees and must not
be mislabeled as this ancestor-prefix layout. `newton_solver` owns that separate
dense Hessian/iteration path; `mixed-solve` can supply the real CG mass
preconditioner. Sparse-tail factor/solve closure is implemented in source;
complete constraint iteration and complete physics-step closure remain separate.

Only MoonBit check/info/fmt and syntax-only genuine-header C++ template/atomic
signature validation are performed here. Pending test sources cover mixed
layouts, full-tail sizing, exact metadata bytes, cooperative gating, in-place
RHS support, empty compact factor, LU addressing/fill rejection and scratch
aliasing. No test or algorithm has run. GPU compilation, real resource limits,
atomic-order tolerance, numerical equivalence, learning equivalence and full
upstream differential tests remain deferred. Artifacts report these limits,
including `mathdx_accelerated:false`, `runtime_equivalence_verified:false`,
external SDK/transitive dependencies not attested, and no full physics-step
claim.
