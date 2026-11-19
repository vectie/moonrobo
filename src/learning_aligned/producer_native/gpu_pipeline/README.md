# Owned native GPU programs

This package connects the actual MoonBit-generated G1, MuJoCo-Warp sparse/NXN,
primitive-contact, rigid GJK/EPA/manifold, mixed sparse/LU, Newton/CG,
compact/incremental, effective-metric, device-convergence and MathDx tile modules to the
native Warp 1.17 dispatch and APIC writer.
It loads existing compiled PTX/CUBIN; it never invokes NVRTC or Python. The
original Python producer remains available for later differential verification.

`decode_config(Json)` rejects unknown configuration and command fields.
`execute(config, initial_buffers?=[])` is an explicit async execution API; only
calling it opens native libraries/CUDA. Pure host adapters `host_buffers` and
`mixed_factor_buffers` can supply additional owned initial bytes directly.
No algorithm, GPU operation, JIT or test was run while implementing this package.

Config contains explicit dispatch/writer/Warp library paths, device ordinal and
architecture, SHA-pinned compiled module directories, SHA-pinned raw buffers,
optional finalizer artifact imports, a program, mode, graph-launch flag and fresh
output directory. The supported module receipt formats are checked against the
actual current lowerers, exact source bytes, specialization hashes, compiled
image hashes, architecture flags, parameter ABIs and emitted launch policies.
G1's genuine NOTICE is required and retained. Physics/contact CUDA source retains
its upstream license header. No `.meta` file is fabricated or required.

Each command has exactly `operation` and `parameters`. Operations are:

- `launch`: module ID, entry key and exact named arguments. Arrays use explicit
  `buffer`, `dtype`, `shape`, `byte_strides`, `offset_bytes`; scalars use their
  actual generated ABI. Narrowphase's entry key is `contacts`.
- `copy`: source/destination owner names, source/destination offsets and byte
  count. Ranges are proven, positive, primitive aligned and nonoverlapping.
- `zero`: owner name, offset and byte count, with the same range/alignment proof.
- `if`: actual scalar int32 condition view, `on_true` and `on_false` programs.
- `while`: actual scalar int32 condition view and body whose last unconditional
  operation either zeros that same four-byte predicate (the original zero/one
  iteration profile), or launches a real device-convergence producer updating
  that exact `nsolving` view. The latter permits repeated actual device iterations,
  bounded by each world's original convergence/iteration-limit transition.

`eager` records APIC operations while actually executing them. `capture` records
one real outer CUDA graph, with native IF/WHILE child graphs; conditions never
fall back to CPU branches. `launch_captured_graph=true` launches that graph once
after capture. Record-only mode does not validate contact results. Native graph
support/driver failures propagate without an eager fallback or success receipt.

Primitive owners are bool/int32/int64/uint64/float32/float64. `uint64` supports
storage and byte copies only; current generated kernels have no uint64 argument.
Finalizer tags i32/i64/u64/f32/f64/bool are mapped without changing any bits.
Finalizer shape/components/length/SHA are checked. Empty arrays retain their
upstream artifact metadata and receive no allocation. A zero-extent logical view
may use an explicit existing aligned owner; it contains no logical elements.
Only physical entries in `files` are allocated. Aliases remain explicit views
onto a physical owner with an offset; their names do not create duplicate owners.
Float32/Double inputs are never implicitly converted to each other.

Every complete reachable strided span and writable self-alias is checked.
G1 maps are bounded permutations read from actual int32 input bytes. Sparse
gather/CSR/compact mappings and NXN geom indices are checked against concrete
specializations and their owners are immutable throughout the entire program.
Writable views cannot overlap another argument in a launch, except the precise
in-place RHS/result cases explicitly supported by mixed solve and three metric
helpers. Sparse LU forbids that alias because it uses the output as scratch. Atomic counter
owners admit only their unique producer and aligned zero operations, protecting
initial-zero proofs from earlier copies, kernels and conditional branches.
NXN currently requires full worst-case candidate capacity and one top-level
producer. Primitive and full convex contacts form a terminal top-level suffix;
when combined, they share exactly the same outputs and bounded append count.
They cannot feed downstream consumers before the host publication gate. After
real execution, all rejection counters must be zero and contact count must fit capacity.

Device-convergence producers (`newton-done` and `cg-beta-finalize`) must be the
final unconditional launch of a top-level WHILE. Before CUDA setup, actual input
bytes prove `nsolving == count(!done)` and active `niter < iterations`. Its four
control owners are distinct and frozen to the unique producer across the full
program: unlike append counters, even another zero is rejected. Tolerance and
mean-inertia owners are immutable. Every unfinished world advances its real
iteration counter until convergence or its exact limit and decrements `nsolving`
once, guaranteeing device-loop termination. Results are validated only after an
actual graph launch. The new Newton module supplies actual initialization,
objective, line search, gradient/Hessian and factor/direction bodies. Newton and
CG use matching convergence tails with line-search flags; CG additionally uses
the actual beta/search transition. Control initialization resets done, iteration
count and unfinished-world count on every graph replay, without clearing failures.
CG beta uses serial FP32 per-world reduction; upstream tile association remains
unverified. See the [device transition support](../device_convergence/README.md).

The convex entry key is `convex-gjk`. It is a single terminal top-level distance
and witness stage, not a contact stream. Mandatory owned-view validation runs
before setup, and synchronized `status_out` plus five `rejected_out` counters
must pass `convex.validate_results`. EPA-required, exhausted, unsupported, invalid
or numeric-failure results refuse publication. Rejection owners cannot be hidden
by any later copy/zero/kernel. The existing primitive contact path is preserved.

MathDx `mathdx-tile-factor` and `mathdx-tile-factor-solve` use the actual lowerer's
block size, one-block-per-tile launch and `grid_stride=false` policy. The linked
CUBIN target comes from its explicit request and real Warp C compiler policy;
no fictional NVRTC option list is inferred. Owned rank-three contiguous tile
views pass the tile module's binding proof. All synchronized per-tile status
values must be zero before publication. Tile launches currently occur only at
top level: repeated/conditional tile execution with persistent failure state is
not implemented, so a later iteration cannot hide an earlier failure. Status
owners reject other kernels, copies and zeros. These are actual independent
dense tiles. The separate mixed-sparse module implements gather, reverse-level
LDL and UP/D/DOWN solve, and the sparse-LU module supplies the actual no-pivot tail.

Newton and compact/incremental modules may share one complete sticky `status`
owner. Mixed/LU/metric operators may share a separate complete sticky `failure`
owner. Every accepted device entry checks and latches failure; copies, zeros and
unrelated arguments cannot erase it. Actual metadata bytes prove indices and
CSR layouts. Newton numeric inputs may be prepared in a native prefix and are
frozen once state initialization starts. Incremental plans authenticate their
initializer, change queues, cached factor and ordered iteration sequence.
External CG preconditioners must match the genuine metric/mixed helper chain,
read the current gradient, write the current M-gradient and use the exact done
view. The typed `prepare-effective-cg` entry constructs this coupling explicitly;
an arbitrary well-typed kernel list does not establish it.

All initial owners are snapshotted before APIC begin. A synchronous native scope
holds context, modules, kernels, buffers, graph and writer through save and
observations, without coroutine thread migration. Cleanup releases graph before
writer, then kernels/buffers/context. A failed capture is discarded using the
existing native poison-context safeguards. Output retains exact source/images,
compiled receipts, NOTICE, initial and observed bytes and SHA identities. Native
APIC's `pipeline.wrp` has its real `pipeline_modules` companion directory.
Library file hashes are rechecked after native work, before the success receipt
is written last.

The reference Newton/CG and incremental iteration programs are now authored in
MoonBit and lowered to genuine native Warp entries. The complete SDK/model
physical-coefficient construction, deformable providers and upstream optimized
routes remain separate boundaries. Host factor seeds are actual CPU/Double bytes;
MathDx tiles and scalar/cooperative reference GPU paths retain distinct policies.
Full solver closure, full aligned bundle, numerical equivalence and replay
validation remain false. Pending metadata-only regression sources are included;
runtime and upstream differential tests await an available machine.

Primary semantics are inherited from the already pinned lowerers and native
dispatch/writer packages: IsaacLab revision 46d6cc3d7b115906fad12efd372fbf69f4e3d3ed,
Newton 71eeba16a717d4dcf0b9dd7056a7b6f863054dc3,
MuJoCo-Warp 3.15.0 and Warp 1.17.0. Exact source identities are retained in each
input module receipt and recomputed specialization. This package adds orchestration,
ownership and validation, without introducing replacement physics equations.
