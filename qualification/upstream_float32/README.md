# Executed-upstream Float32 learning qualification

Run from MoonRobo with a clean sibling `smc` checkout at
`a1508d42c9d1699a52e8233ab16d08c488441ab9`:

```text
moon run scripts/qualify_upstream_float32.mbtx \
  /absolute/venv/bin/python \
  /absolute/venv/lib/python3.12/site-packages/torch \
  /absolute/fresh-evidence-directory
```

Use `CXX` to select the C++ compiler. The Python environment needs Torch,
NumPy, MuJoCo and the retained test dependencies; the acquired G1 catalog and
scene must be at the paths used by those tests. macOS and Linux are supported.
The command builds the production tensor plugin and independent RNG adapter
from source, then runs all 54 retained Python methods without skips and
exports two source-bound fixtures from the actual pinned SMC functions.
No Isaac runtime, robot SDK or robot connection is started.

The isolated white-box driver calls the production LibTorch learner with
the original cheap differentiable FixtureMDP heads. It uploads actual Float32
weights, inputs and normalizers, captures real raw/clipped gradients and Adam
state at every update, persists typed NPZ and reloads it before calling the
existing `learning_differential.compare_fixture`. Expected results come from
the unmodified upstream network/train function bodies and real Python Adam.
The independent adapter supplies only ATen RNG draws/state; it never computes
the learner candidate or expected learning result.

The two cases are the original small architecture profile: batch 2, eight
world steps, 32 actor steps, history/goals 10, hidden widths 16/12/8, and eight
critic updates. Case registration checks require the complete parameter,
gradient, normalizer, moment, step and RNG keysets. Floating tensors retain
their actual `<f4>` dtype. Gradient/weight/moment checks retain zero tolerance;
the existing scalar metric tolerances are unchanged.

The qualified eager profile explicitly selects native linear/layer norm,
`smc_world_rotation`, `smc_source_order`, `split_world_delta`,
`world_error_batched`, original xi normalization, actor return, GAE and Adam
arithmetic. `smc_source_order` defaults to false, is serialized with execution
options, and requires the source-order plugin capability. Ordinary scalar
Float64 conformance remains a separate profile. No compiled, microbatch,
CUDA/BF16/TF32 or large-batch equivalence follows from this CPU result.

The `.mbt.in` driver is copied into an isolated source workspace. It adds no
optional test skips to the regular suite. Fixed heads and update observers are
private package types and cannot be installed through the public learner API.

Evidence directories retain compiler/build logs, the 54-method log, sealed
source identities and input/expected NPZ, staged candidate source, native logs,
candidate NPZ hashes and per-output verification reports. Changing source
requires a fresh campaign; a passing report is not reused for modified source.
After the complete comparison, a supplemental raw Float32 payload audit can
also verify sign bits, including signed zeros (requires `unzip`):

```text
moon run qualification/upstream_float32/verify_payload_bits.mbtx /absolute/completed-campaign
```

This is two strict native learning cases plus 54 executed original methods,
not a newly sealed 27-case native data/MDP/Isaac fixture suite or physical GPU
qualification. Historical fixtures and failed campaigns remain intact.
