# Native conformance and source-bound differential execution

This package provides actual MoonBit candidate adapters, a separate optional
ATen C++ mathematical oracle, immutable numerical fixture bundles, and strict
capture verification. The original Python files remain unchanged. The native
conformance suite now builds, loads and executes the independent ATen oracle.
It tests the production scalar learner in Float64, its declared precision.
This is separate from upstream Float32 qualification; it does not establish
bitwise agreement with an executed Python model or qualify GPU dynamics.

[AUDIT.md](AUDIT.md) maps all 54 methods in the nine retained aligned test files;
27 have named entries in `contracts.mbt`. The first five data unit methods and
nine Isaac protocol methods also have direct production-SUT test sources in
`learning_aligned`. Case registration is separate from availability of a real
executed-upstream fixture.

## Two distinct reference routes

- `independent-aten-cpp` / `independent-mathematics`: independently transcribed
  pinned source equations. `native/learning_oracle.cpp` uses real ATen autograd
  and `torch::optim::Adam`, with supplied weights, moments, windows, starts and
  permutations. `mathematical_oracle.cpp` implements original MDP/FK/rotation,
  resampling, reset mixture and actual ATen RNG calls. The replay and architecture
  mathematical references do not call the tested MoonBit implementations.
- `executed-upstream-python`: numeric fixtures exported by an actual execution
  of the preserved original Python oracle/tests. Native tools only ingest and
  verify these artifacts; they do not interpret Python or execute pickle code.
  No such fixture was produced by this test-fix task. When an external suite is
  selected, the 12 methods that compare with executed sibling SMC functions
  still require this label; independent C++ results cannot substitute for it.

## Executable native profile

Run `moon run scripts/test_native.mbtx DEPENDENCIES.json` from the workspace
root. The [dependency guide](../../docs/NATIVE_TESTING.md) describes the explicit
Torch, MuJoCo, G1, qualified E1, acquired motion-data and LP64 BLAS inputs. Missing
inputs fail. An optional list of package paths selects a focused run; the default
runs the full workspace, including MoonNum, Moonphys and LunaKine tests.

Without `MOONROBO_SMC_DIFF_FIXTURES`, the 27 named cases execute production code
against explicit unit expectations, independent data/ring equations, CPU adapter
protocol fixtures or independent ATen autograd/Adam. They cover all network
outputs, normalizer buffers, raw/applied gradients and optimizer states for an
eight-step world update and a 32-step policy/GAE update, plus actual acquired
motion files and genuine ATen generator state/draws. No case returns a skip.

The oracle's `native64.learning.*` and `native64.*` operations specify Double
arithmetic and the native corrected heading/rotation-error equations. Original
unprefixed operations retain the upstream Float32 normalizer/discount behavior
and documented rotation bugs. Regression tests verify failure isolation and
that the two profiles retain different optimizer-step dtypes. Native comparison
requires exact keysets, dtypes and shapes; integers, booleans and RNG bytes are
exact. Float64 comparisons allow `2e-10 + 2e-9 * abs(reference)` for independent
reduction/autograd order. Tests reject missing tensors, corrupted moments,
reshaped arrays and false dtype labels. These bounds never apply to sealed
upstream fixtures.

The native exporter refuses to write an `executed-upstream-python` label. A
manifest label is provenance to inspect, not proof of Python or GPU execution.
The original Python process remains the authoritative external producer when
that exact upstream execution is required; no new Python script, string `exec`,
source mutation or Python subprocess is introduced by the MoonBit tools.

## Source-bound fixture command

From the MoonRobo module, with a previously built explicitly selected oracle:

```text
moon run --target native cmd/reference_differential -- list
moon run --target native cmd/reference_differential -- export TEMPLATE.json SOURCE_ROOT LIBTORCH_ORACLE OUTPUT
moon run --target native cmd/reference_differential -- run FIXTURE SOURCE_ROOT FIXTURE_SHA256 LIBTORCH_ORACLE OUTPUT
moon run --target native cmd/reference_differential -- verify-capture FIXTURE SOURCE_ROOT FIXTURE_SHA256 CAPTURE OUTPUT.json
```

`SOURCE_ROOT` is a directory containing both sibling `smc/` and `moonrobo/`.
Every file identity is relative to its declared root, disallows `..`/absolute
paths, and requires a complete lowercase SHA256. The explicit adapter library's
canonical path and bytes must match `oracle_adapter` in the sealed manifest;
its reported Torch version must match the fixture. Each evaluation clears all
old oracle inputs/outputs before loading the next complete keyset.

`export` accepts a source-bound template and existing numeric input NPZ. It
computes only the independent reference and writes a fresh immutable bundle.
It never invents initialization, weights, source data or RNG state. Native
fixed execution is available for catalog verification, three-clip resampling,
reset mixture/terminal-bin correction, all five MDP cases, architecture, network
forward/world8, policy32 and replay. The five original data unit cases and nine
Isaac cases use their direct native tests or an explicit external capture;
`run` rejects an unsupported implicit fallback.

`run` invokes the actual candidate and writes `candidate.npz` plus
`capture.json` before numerical comparison, preserving failure evidence. A
`verification.json` with `passed: true` is written only after every gate passes.
`verify-capture` checks a supplied full candidate capture against the trusted
fixture and current source identities; it does not attest how a third party
executed that capture.

## Fixture format

`fixture.json` is `FixtureManifest` in `protocol.mbt`, format
`moonrobo.smc-differential.fixture.v1`. It contains:

| Field | Required meaning |
|---|---|
| `case_id` | One exact original-method ID from `contracts.mbt` |
| `oracle_kind` | One explicitly declared reference route above, or `sdk-protocol-trace` for CPU protocol captures |
| `upstream_revision` | Exactly `a1508d42c9d1699a52e8233ab16d08c488441ab9` |
| `upstream_sources`, `candidate_sources` | Nonempty maps of `{path, sha256}` for all source dependencies; oracle/candidate paths must be disjoint |
| `original_test`, `producer` | SHA-bound preserved test and actual producing artifact identities |
| `oracle_adapter` | Optional SHA-bound native shared library; mandatory for native `export`/`run`, unnecessary for capture-only ingestion |
| `torch_version`, `device`, `threads`, `dtype` | Exact producer identity; original profiles are CPU, one thread, Float32 or Float64 |
| `config` | Original method configuration and static source/model/catalog identities |
| `input`, `expected` | Relative numeric NPZ file identities; complete SHAs |
| `input_keys`, `expected_keys` | Complete, exact tensor keysets, including all model/normalizer/Adam/gradient evidence |
| `rng_before_sha256`, `rng_after_sha256` | SHA256 of explicit byte-valued generator states |

Every input bundle includes `rng.before`; every expected/candidate bundle
includes `rng.after`. Deterministic cases may use an explicitly empty `|u1`
array, whose SHA remains bound. Stochastic cases require actual nonempty state
and call evidence. Integer shapes/ranges, boolean values, finite floats and
exact Float32 representability are checked before an ATen conversion; `<u8>` is
not supported and is rejected. No silent narrowing or fractional-index cast is
accepted. Native outputs retain their truthful `<f8>` dtype.

`CandidateManifest`, format `moonrobo.smc-differential.candidate.v1`, binds the
fixture SHA, input SHA, the complete same candidate-source identity map, the
output NPZ SHA and an explicit backend (`moonbit-float64`,
`cpu-batch-adapter-contract-fixture`, or `actual-isaaclab3-newton`). A CPU
protocol fixture never constitutes evidence of CUDA/Newton dynamics.

## Fixed learning payload

All tensor names preserve PyTorch `state_dict` names after these prefixes:

- `weights.wm.*`, `weights.pi.*`, `weights.critic.*`, including every running
  normalizer `mean`, `var`, scalar `count`.
- `optimizer_before.MODEL.PARAM.{exp_avg,exp_avg_sq,step}` for every trained
  parameter, including explicit zero state at step zero. Per-parameter steps
  must be bounded uniform integers for the native canonical optimizer.
- Outputs `weights_after.MODEL.*`, `optimizer_after.MODEL.PARAM.*`,
  `grad.raw.MODEL.PARAM`, `grad.clipped.MODEL.PARAM`. Critic updates include
  `step0` through `step7` before the parameter name. Missing one supplied model
  tensor, gradient or Adam moment causes rejection; a scalar loss is insufficient.

The original small profile is enforced: world hidden `[16,16,16]`, policy
`[16,12]`, critic `[16,8]`, history 10, goals 10, batch 2, window 8, imagination
32, critic epochs 2/minibatches 4, noise disabled, gamma .99, lambda .95 and
the source learning rate. Architecture comparison separately constructs the
actual default candidate models; the native architecture test constructs them.

| Operation | Fixed inputs |
|---|---|
| `network` | `inputs.state [2,71]`, `action [2,29]`, `xi_normalized [2,33]`, `observation_history [2,10,93]`, `goal [2,730]`, `critic_features [2,914]` |
| `world_update` | `inputs.windows.{s,s1} [2,8,71]`, `.a [2,8,29]`, `.xi [2,8,33]`, `.mask [2,8]`; original error floor `[70]` |
| `policy_update` | `inputs.starts.s [2,71]`, `.a_prev [2,29]`, `.xi [2,33]`, `.f [2]`; `inputs.history.s [2,10,71]`, `.a_prev [2,10,29]`, `.xi [2,10,33]`, `.f [2,10]`; exact integer `inputs.critic_permutations [2,64]` |

The candidate uses `WorldModel::fit_fixed` and
`Learner::update_policy_fixed(FixtureHeads)` as seams into the same production
core. The cheap heads exactly represent the original `FixtureMDP`, not a
simulator. Actual raw and applied gradients are observed inside canonical Adam
after its clipping arithmetic and before updating moments/parameters. Original
default training still chooses its physical heads and original native sampler.

The C++ oracle preserves the upstream yaw epsilon in world-model features and
errors, Float32 running-normalizer update, Float32 discount tensor, policy
norm-then-value clipping and actual Adam semantics. The original FixtureMDP's
critic uses its locally corrected proper yaw. These differences are not edited
to imitate the candidate. Upstream returns the last critic minibatch loss while
the native production summary returns a mean; that scalar is not one of the
four original policy differential assertions and is not relabeled as equal.

## MDP, motion, RNG and replay payloads

MDP/FK inputs have `inputs.state.{p,R,v,w,q,qd}` and
`reference.{p,R,v,w,q,qd,body_p,body_R,body_v,body_w}`. Static model tensors are
`kin.parent`, `kin.joint`, `kin.axis`, `kin.offset_p`, `kin.offset_R`,
`kin.tracked`, `kin.q_lo`, `kin.q_hi`. Bind the source MJCF/topology asset SHA in
the source identities. Reward pullbacks additionally use
`inputs.rotation_vector [12,3]`, `inputs.action`, `inputs.previous`,
`inputs.xi`, `inputs.default_q`, and actual `inputs.observation_uniform [12,99]`.
Quaternion pullback uses the five original `inputs.vectors [5,3]` and
`inputs.quaternion_weights [4]`. Observation-mode outputs store only the
originally compared prefixes, plus exact full dimensions `[93,99,102]`.

Real-clip resampling accepts `motion.raw [SOURCE_FRAMES,36]` and
`config.source_fps`. The original three named acquired clips need separate
fixtures. Catalog verification streams all 40 original CSV files, checks
their hashes/rows/quaternions and the source revision
`ce1572906efe6157840e8474d5a0d7aa87481e74`; config `catalog` identifies the actual
`motion-manifest.json`. It never substitutes a synthetic corpus.

Reset-mixture inputs include `sampler.bin_G`, `bin_w_avg`, `bin_start`,
`bin_clip_end`, `update_bins`, `update_returns`, `config.G_max`,
`config.sample_count` and actual generator bytes. The production sampler's
optional batch-draw seam uses real ATen multinomial followed by one batched
Float32 uniform call, retaining the original law without substituting native
inverse-CDF RNG. The 31-frame terminal-only-bin counterexample separately
requires `sampler.rng_before`; it records the actual old buggy sample and the
corrected candidate behavior, rather than demanding equality of a bug and fix.

Replay accepts all original `replay.{s,s1,a,a_prev,xi,f,ep_step,done}` time×env
fields, capacity 8, explicit `inputs.window_ages/window_environments`, patched
`inputs.start_ages = [0,2,3,7]`, and `inputs.restore_ages`. It invokes the actual
ring buffer on the candidate side and independent upstream age/padding/mask
equations on the reference side.

`rng.calls [CALLS,3]` holds `(kind,count,high)`: kind 0 is Long randint, 1 is
Float32 uniform, 2 is Long randperm, 3 is multinomial with
`rng.weights.CALL_INDEX`, and 4 is Float64 uniform. Policy shuffles must be
exactly two `randperm(64)` calls and match supplied permutations. MDP noise and
replay choices are also matched against actual ATen draws before the candidate
calculation. No fallback seed law is accepted.

## Strict upstream profile and remaining boundaries

`fixtures_wbtest.mbt` has 27 method entries plus strict schema tests. To run the
external qualification route instead of native conformance, set
`MOONROBO_SMC_DIFF_FIXTURES` to an actual exported suite and run
`moon test src/learning_differential --target native` directly. `suite.json`
uses format `moonrobo.smc-differential.suite.v1`, `source_root`,
`oracle_library`, and `cases` records with `case_id`, relative `folder`, trusted
`manifest_sha256`, optional `capture`, optional `variant`. The real-clip method
requires all three exact names from the original test. Missing fixtures fail
explicitly; no skip/fake pass or independent-for-upstream substitution occurs.

The native runner builds the optional C++ library with an explicitly selected
compiler and Torch headers/libraries. CMake with TorchConfig is also supported.
The normal MoonBit production module has no LibTorch/Python link dependency;
the adapter is explicitly loaded at differential execution time.

The canonical candidate uses Float64. Original Float32 fixtures currently fail
the strict dtype gate, before any claim of bitwise tensor/optimizer equality.
That is a real unresolved numerical boundary, not permission to relabel dtype,
round results or widen the original thresholds. Missing upstream-executed
fixtures and unperformed real SDK/GPU runs remain external execution evidence;
they are not reported as successful migration verification.
