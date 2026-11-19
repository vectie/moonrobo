# Upstream Float32 learning qualification — 19 November 2026

The production native LibTorch learner now passes the original small CPU
world/actor comparisons against actual execution of pinned SMC revision
`a1508d42c9d1699a52e8233ab16d08c488441ab9`. Both libraries were freshly built by
the reproducible [qualification command](../qualification/upstream_float32/README.md).

| Check | Result |
| --- | --- |
| Nine retained Python files | 54 methods passed, zero skips |
| Native eight-step world update | 101 outputs, maximum absolute difference 0 |
| Native 32-step actor / eight critic updates | 226 outputs, maximum absolute difference 0 |
| Affected native packages | 98 tests passed, zero failures; existing optional device notices retained |
| Complete MoonRobo native workspace after checkpoint fix | 1,891 passed, zero failed; the same 120 optional device notices as the prior baseline |

The 327 strict outputs include actual Float32 network values, all raw and
clipped parameter gradients, post-update weights/normalizers, Adam moments and
steps, metrics and RNG state. Shapes, dtypes and complete keysets pass the
existing verifier. Gradient/weight/moment checks retain zero tolerance; the
original scalar metric tolerances were not widened. Even the scalar metrics
have zero difference in this recorded run.

The executed reference uses unmodified SMC network/train function bodies and
real Python Adam. The candidate uses the production MoonBit/LibTorch learner
with the same cheap differentiable FixtureMDP heads and original fixed inputs.
The independent native oracle supplies only actual ATen RNG replay. Candidate
values are persisted to NPZ, reloaded and checked; no expected values are used
as candidate outputs.

The investigation resolved four distinct issues:

1. Three stale Python setups lacked the current motion `body_state` callback
   or resume manifest field. Setup was repaired without changing assertions.
2. NPZ serialization always widened tensors to Float64. It now preserves the
   declared numeric dtype and rejects silent narrowing; mixed-dtype regression
   coverage includes signed zero and integer/range failures.
3. Mathematically equivalent rotation/scalar expressions built different ATen
   autograd graphs and produced one-ULP gradient differences. The explicit
   source-order profile preserves SMC multiplication/division, shared views,
   detached constants, Rodrigues/heading expressions and rollout packing.
4. After the first optimizer step, C++ Adam's moment arithmetic differed from
   Python CPU Adam's `lerp_` path. The optional SMC Adam route now preserves
   Python single-tensor CPU arithmetic alongside its existing CUDA foreach
   route, while retaining authoritative LibTorch optimizer/checkpoint state.

The new `smc_source_order` option defaults to false and is recorded with
execution options. Fixed heads and update observers are package-private. The
scalar MoonNum learner keeps its Float64 contract. No original numeric gate,
sealed fixture, or expected result was modified to obtain this pass.

The source-bound [summary](evidence/upstream-float32-20261119/summary.json),
[world report](evidence/upstream-float32-20261119/learning.world8.json),
[actor report](evidence/upstream-float32-20261119/learning.policy32.json), and
[54-method log](evidence/upstream-float32-20261119/original-tests.log) preserve
hashes, compiler/runtime identity and per-output errors. Raw inputs, expected
and actual NPZ, source snapshots and complete logs remain under the recorded
local campaign path.

This qualifies two strict native learning cases on CPU and executes all 54
retained Python methods. It does not establish a newly sealed full 27-case
native data/MDP/Isaac fixture suite, CUDA/BF16/TF32 or compiled/microbatch parity,
large-batch performance, policy quality, or physical robot operation.
