# MuJoCo-Warp factorization fragments in MoonBit

This package performs actual CPU/Double factorization and triangular solves for
explicit supported layouts. It does not initialize Python, MuJoCo, a device,
JIT, or an external numerical library. The original upstream/Python path remains
available. No generic dense solver is labeled as a sparse implementation.

The source reference is the actual MuJoCo-Warp 3.15.0 source distribution:

| Source | Ported or inspected operations | SHA256 |
| --- | --- | --- |
| `_src/smooth.py` | `_qLD_acc`, `_qLDiag_div`, `_solve_LD_sparse_fused`, scalar/gather factor and solve, `factor_m` mixed ordering | `6268f0e1b6cb4c9ec6bbd3aa29828dfb36224efb2a3a3e1f54e5f87b6623fdef` |
| `_src/io.py` | Actual tree partition, sparse update depth grouping, scalar/gather classification and factor offsets, gather `elemid` | `2334b394e8f319f0fd2a2957240cdcc77a998513be11767a00f55f26ae07f4b0` |
| `_src/block_cholesky.py` | Inspected tiled/augmented block routines; these are not ported here | `0773678b85d27692d2571ebecaca3ece6573fe30531660e8c993be285407af99` |
| `_src/support.py` | Inspected surrounding mass-matrix/support interface; no replacement full solver claimed | `c924593f7be8447c76328bcf7dc5b4ce92b6a54458c4afdbf36806cb8e036d46` |
| Warp 1.17.0 `native/tile_cholesky.h` | Upper scalar-fallback arithmetic and opposite-triangle zeroing; MathDx path also zeros lower output | `2941d27c329535c63f9f8b0e23dc414bc4d1a70f33b8242291982be4fad224f5` |

Primary source locations are `_src/io.py:247` (`m_block_layout`),
`io.py:1133` (update groups), `io.py:1190` (gather indices),
`smooth.py:1195` (whole-CSR tail and reciprocal diagonal),
`smooth.py:1210` (scalar), `smooth.py:1250` (gather),
`smooth.py:1311` (`factor_m`), and `smooth.py:3544` (`solve_m`).

## Packed-tree sparse LDL

`factor_tree(TreeRequest)` operates directly on the actual diagonal-last CSR
storage and returns a privately owned `TreeFactor`. It validates:

- Contiguous nonempty CSR rows, strictly increasing lower-triangle columns, and
  diagonal at `M_rowadr[i] + M_rownnz[i] - 1`.
- Parent DOFs precede their children; each row is exactly its complete
  root-to-self ancestor prefix. Branching and independent trees are supported.
- Every `qLD_block_adr` is the actual sparse sentinel `-1`, and
  `qLD_block_total == 0`. Mixed dense/compact/sparse closure is rejected.

The package derives precisely the depth-grouped `(i,k,Madr_ki)` updates used by
pinned `io.py`, traverses groups in reverse during factorization, and updates
packed storage in place. A per-group snapshot preserves the read/barrier
relationship of the GPU kernels; contributions to a common ancestor accumulate
in canonical source order. No dense matrix is allocated.

`TreeFactor::solve(rhs)` performs the actual reverse-level UP pass, reciprocal
diagonal multiplication, and forward-level DOWN pass. `qld`,
`inverse_diagonal`, and `data` export copies. Request arrays and returned arrays
cannot mutate the retained factors/layout. The data receipt includes actual
CSR, parent metadata, grouped/concatenated updates and level offsets, including
the upstream unused dummy update when there are no levels.

Arbitrary CSR fill-in, compact diagonal-only rows inside a larger sparse
ancestor chain, and pivoted/indefinite systems are unsupported. Such input is
rejected instead of being silently densified or interpreted as a different
sparsity structure. This boundary is deliberate: ancestor-prefix alignment is
what makes the pinned `_qLD_acc` row-prefix update valid.

## Independent compact and small Cholesky blocks

`factor_small_blocks(BlockRequest)` supports independent contiguous blocks with
at most six DOFs, matching pinned `M_BLOCK_SCALAR_MAX`:

- Compact sentinel `-2`: actual diagonal-only CSR input; compute reciprocal
  diagonals without allocating a dense factor.
- Full small block: actual packed local lower-triangle CSR input; store the
  upper factor `U` in the declared row-major `size*size` factor segment.
  `BlockFactor::solve` performs `U^T` forward and `U` backward substitution.

Actual block coverage, CSR columns, common per-block factor offset and total
packed factor size must match. `factor_seed` preserves every lower/unused
factor slot that the upstream scalar kernel does not write;
`inverse_diagonal_seed` preserves entries unused by full Cholesky blocks. If
seeds are omitted, new zero-filled output arrays are explicitly used. All
input/output state is copied, rather than aliasing request arrays.

This narrow API deliberately rejects larger or mixed layouts; the following
separate API handles those actual source layouts.

## Mixed scalar, gather and packed sparse trees

`factor_mixed(MixedRequest)` implements the actual mixed `factor_m` dataflow
and returns `MixedFactor`, with `solve`, `qld`, `inverse_diagonal` and `data`.
It requires actual compiled-model `tree_dofadr` and `tree_dofnum`. Filtering
zero-sized trees must produce exactly the supplied ordered `blocks`. These
arrays are trusted model metadata, rather than proof that a model was compiled
by MuJoCo. The package validates their consistency, coverage and absence of
cross-block parent/CSR references; it does not infer tree identity from the
number of `dof_parentid == -1` entries. Decoupled DOFs can share a tree.

Block classification follows pinned `m_block_layout` without changing sizes:

- At most six DOFs and diagonal-only CSR: compact reciprocal `-2`.
- At most six DOFs and complete triangular CSR: scalar upper Cholesky.
- Other blocks through 64 DOFs: gather upper Cholesky. A branched three-DOF
  block therefore uses gather too. The package constructs the exact local
  `size*size` index map; structurally missing pairs use the actual `nC`
  sentinel and read zero. Optional `elemid` must match every generated entry.
- More than 64 DOFs: actual sparse `-1` updates. Nontrivial rows must contain
  complete ancestor prefixes and every ancestor target must have the prefix
  required by `_qLD_acc`. Diagonal-only rows that emit no updates are allowed.
  A compact ancestor incompatible with those source reads is rejected.

Factor storage is the real dense prefix of `qLD_block_total` entries followed,
if any sparse tree exists, by a copy of the **entire** input CSR matrix of
length `nC`. The sparse tail is not compressed to sparse-tree entries. Dense
blocks are factored first; sparse updates follow. Finally `_qLDiag_div` writes
inverse diagonals for **all** DOFs using that tail. Consequently scalar/gather
DOFs have inverse original matrix diagonals when sparse trees exist, while
their inverse-diagonal seeds remain unchanged without a sparse tail. Full
upper-factor solves ignore those inverse diagonals. Compact solves use them.

Scalar factors preserve unused lower seed slots. Gather factors explicitly
zero their lower triangle, as both Warp's scalar fallback and MathDx-backed
`tile_cholesky_inplace` do. The CPU implementation allocates at most a local
64-by-64 matrix per gather block; it keeps the large-tree tail in actual CSR
storage. It neither splits tiles into smaller blocks nor densifies the whole
system. Receipts retain tree metadata, factor offsets, exact gather indices,
update groups, and the complete CSR-tail length.

This is a CPU/Double arithmetic baseline for the tile/gather calculation and
mixed storage contract. GPU tile lowering, MathDx LTO compilation, cooperative
launch/barrier wiring and GPU execution remain unimplemented. Warp's tile
Cholesky implementation is a C++ template/LTO interface, not an exported
Cholesky C symbol that this package can safely load. No invented C binding or
generic dense-library alias is supplied. Augmented Cholesky, constraint Newton
decrement routines, LU and the complete constraint solver remain unsupported.

The separate `producer_native/sparse_solver` package now consumes the same
pure `describe_mixed_layout` metadata and provides actual generated GPU
mixed/gather/sparse-tail factor/solve plus D-CSR LU bodies using genuine Warp's
cooperative scalar tile backend. This CPU package does not implicitly compile
or execute that GPU path. The original MathDx tile compiler remains separate;
no accelerated mixed MathDx claim or numerical-equivalence claim is made.

## Command API

`execute(CommandRequest { operation, parameters })` exposes six actual
computation operations:

- `tree-factor` / `tree-factor-solve`, decoding a `TreeRequest`.
- `small-block-factor` / `small-block-factor-solve`, decoding a `BlockRequest`.
- `mixed-factor` / `mixed-factor-solve`, decoding a `MixedRequest`.

Factor-solve requires a real `rhs`; factor-only refuses a supplied RHS instead
of silently discarding it. MoonBit struct fields use `m_rownnz`, `m_rowadr`,
`m_colind`; JSON also accepts original upstream `M_rownnz`, `M_rowadr`,
`M_colind`. Supplying both spellings is rejected. Unknown parameter/layout/block
fields are rejected, including unimplemented metadata flags.

All numeric batches have exact `[world,storage]` / `[world,dof]` shape and finite
values. No hidden diagonal floor, pivoting or regularization is added. Explicit
nonzero regularization and any true `skip_worlds` entry are unsupported and
rejected. Nonpositive or nonfinite pivots and overflow raise errors. Positive
world count and 1..65536 DOFs are required by this fragment. These strict errors
replace unsupported/undefined inputs, not successful SPD upstream behavior.

Receipts always state `numeric_backend: CPU/Double`, `full_solver: false`,
`device_state_modified: false`, and `runtime_equivalence_verified: false`.
Upstream GPU float32 arithmetic and atomic accumulation order can differ from
the deterministic Double implementation; numerical and learning equivalence
still require the deferred differential runs.

## Verification status

Only source inspection, `moon check`, generated interfaces and formatting are
used during this task. Pending regression sources cover branched/deeper sparse
trees, triangular solves, state ownership, compact/scalar/gather/sparse mixtures,
full CSR tails, all-DOF inverse-diagonal overwrites, gather missing-pair sentinels,
seven-DOF blocks, preserved scalar seeds and cleared gather lower triangles,
tree/layout rejection and explicit regularization/skip rejection. They have not
been executed. No numerical example, test, SDK/model initialization, JIT,
training, simulation or export has been run.
