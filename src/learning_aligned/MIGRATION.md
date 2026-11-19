# Aligned Python → MoonBit parallel implementation

All `providers/motion_learning/aligned/*.py` files are retained. This directory
contains independent MoonBit algorithms, a native MuJoCo runner and a genuine
Warp CUDA APIC replay adapter. Production has no Python runtime or substituted
simulator; the separate offline artifact producer can embed retained vendor SDK
objects through a limited C API. The original MIT attribution is in
`SMC_LICENSE`.

## Source map

| Python source | MoonBit implementation | Status |
| --- | --- | --- |
| `rotations.py` | `rotations.mbt`, `autodiff.mbt` | Quaternion/matrix conversions, SO(3) exp/log, yaw, 6D, SLERP; differentiable counterparts used in training |
| `robot.py` | `robot.mbt`, `physics/environment.mbt`, `producer/` | G1 names, motor constants, PD, armature, effort bounds, action scales/defaults/setpoints; optional pinned vendor articulation construction belongs to the separate offline APIC producer |
| `kinematics.py` | `kinematics.mbt`, `physics/adapter.mbt`, `analytic_ad.mbt` | Extract compiled MuJoCo tree, pivots/qref/axes/limits; forward poses and link-origin velocities; reverse-mode FK |
| `mdp.py` | `mdp.mbt`, `analytic_ad.mbt` | All three observation modes, noise/scale tables, invariant/critic features, tracking and penalty rewards, hard/soft failures |
| `motion.py` | `motion.mbt`, `motion_io.mbt`, `motion_store.mbt`, `motion_stream.mbt`, `storage/` | CSV/directory and hash-verified split manifests, 50 Hz resampling, finite differences/FK, bins, goals; eager or bounded disk shards with on-demand FK; `verify` command |
| `buffer.py` | `buffer.mbt`, `checkpoint.mbt` | Chronological replay, episode/reference-safe windows, padded histories, clip-complete starts and owned snapshots |
| `sampling.py` | `sampling.mbt`, `physics/environment.mbt` | Uniform/difficulty/history mixture, simultaneous completion averaging, truncation bootstrap, restartable bin/RNG state |
| `networks.py` | `models.mbt`, `networks.mbt` | ELU policy/critic; SiLU+LayerNorm world model, final-layer initialization rules, running statistics, state increments; native CPU f64 only |
| `learning.py` | `autodiff.mbt`, `analytic_ad.mbt`, `learning.mbt` | Multistep masked world-model BPTT, imagined actor BPTT through FK/rewards/soft failure and critic tail, GAE critic targets/minibatches, separate Adam states and actor gradient clipping |
| `mujoco_env.py` | `physics/adapter.mbt`, `physics/environment.mbt` | Real MuJoCo C API; PD/effort/armature/collision setup, resets, friction/calibration/COM randomization, physical transitions, adaptive resets and integration checkpoints |
| `evaluation.py` | `evaluation.mbt` | Deterministic complete-clip adapter loop, failed-remainder denominator, equal-clip/frame-weighted returns, separate strict RMSE; original JSON schema via `report_json`, including per-clip metrics, catalog coverage and replica accounting |
| `export.py` | `export.mbt`, `cmd/main.mbt` | Aligned71→compiled MuJoCo addresses/body-local angular velocity and MotionDataset replay reconstruction; reads new JSON checkpoints |
| `train.py` | `train.mbt`, `checkpoint.mbt`, `weights.mbt`, `report.mbt`, `cmd/main.mbt` | Collection/warmup/UTD/cosine LR, all counters, periodic atomic JSON checkpoints, exact restore/refill fallback, original report schema/provenance, total-target `--iterations`, automatic `--evaluate`, independent held-out catalog with weights-only loading, restricted original Torch weight import; `train/evaluate/export/verify` CLI |
| `assets.py` native compilation | `assets/xml.mbt`, `assets/compile.mbt` | URDF compiler extension, native `mj_loadXML`/`mj_saveLastXML`, free pelvis, floor/contact masks, PD actuators, compiled dimensions/order checks and SHA256 receipt; `compile` CLI |
| `assets.py` USD conversion | `native/usd_converter.cpp`, `usd/`, `native/validate_usd.cpp` | Real compiled MuJoCo → standard UsdGeom/UsdPhysics USDA converter; strict unsupported-feature refusal and hash receipt; optional genuine OpenUSD structural validator. Converter syntax checked against real MuJoCo headers, not executed; no vendor-importer dynamic/byte equivalence claim |
| `isaac_env.py` | `gpu_protocol/environment.mbt`, `gpu_native/`, `native/aot_solver.cpp`, `producer/`, `cmd/runtime_bridge.mbt` | Full batch/reset/context/pre-reset-transition/evaluation/warm-resume protocol; real four-graph Warp APIC native replay and production train/evaluate factory. Offline pinned SDK producer is separate. CUDA C++ cannot be compiled on this host; artifact generation/GPU operation remain unexecuted. The original backend is kit-less Newton/MuJoCo-Warp, not a Kit/PhysX solver |
| `__init__.py` | `moon.pkg` package boundary | MoonBit package imports replace Python relative imports |
| six local and three parent `test_aligned*.py` files | Core, `physics`, `gpu_protocol`, `gpu_native` test sources, plus `learning_differential` | Portable CPU, real-MuJoCo and all nine original Isaac CPU protocol contracts authored/typechecked; differential source/fixture provenance is audited separately in `TEST_MIGRATION.md` and `learning_differential/TEST_MIGRATION.md`. No tests executed |

## Commands (documented only, not executed during migration)

Native builds need matching MuJoCo headers visible to the C compiler and an
explicit matching library path. Missing headers/library/version raise errors.
`--output` names a file; create its parent directory beforehand.

```text
moon run src/learning_aligned/cmd --target native -- compile --library /path/libmujoco.dylib --description /path/g1_description

moon run src/learning_aligned/cmd --target native -- verify --library /path/libmujoco.dylib --scene /path/scene.xml --manifest /path/catalog.json --config /path/config.json --output /path/verification.json

moon run src/learning_aligned/cmd --target native -- train --library /path/libmujoco.dylib --scene /path/scene.xml --motion-dir /path/csvs --config /path/config.json --output /path/checkpoint.json

moon run src/learning_aligned/cmd --target native -- train --library /path/libmujoco.dylib --scene /path/scene.xml --motion-dir /path/csvs --config /path/config.json --output /path/checkpoint.json --resume /path/checkpoint.json

moon run src/learning_aligned/cmd --target native -- evaluate --library /path/libmujoco.dylib --scene /path/scene.xml --motion-dir /path/csvs --config /path/config.json --output /path/evaluation.json --resume /path/checkpoint.json

moon run src/learning_aligned/cmd --target native -- export --library /path/libmujoco.dylib --scene /path/scene.xml --motion-dir /path/csvs --config /path/config.json --output /path/replay.json --resume /path/checkpoint.json

moon run src/learning_aligned/cmd --target native -- train --library /path/libmujoco.dylib --scene /path/scene.xml --manifest /path/catalog.json --config /path/config.json --output /path/checkpoint.json --iterations 100 --evaluate --evaluation-manifest /path/catalog.json --evaluation-split test

moon run src/learning_aligned/cmd --target native -- evaluate --library /path/libmujoco.dylib --scene /path/scene.xml --manifest /path/heldout.json --config /path/heldout-config.json --output /path/heldout-evaluation.json --weights /path/checkpoint.json

moon run src/learning_aligned/cmd --target native -- evaluate --library /path/libmujoco.dylib --scene /path/scene.xml --manifest /path/heldout.json --config /path/heldout-config.json --output /path/torch-evaluation.json --weights /path/original-checkpoint.pt --weights-sha256 EXPECTED_SHA256
```

`--manifest` selects an explicitly hash-verified catalog and configured `split`;
`--split` overrides that split explicitly for standalone held-out evaluation.
`--motion-dir` loads sorted CSVs with `source_fps` (default 30). Config keys mirror
Python: `wm_hidden`, `pi_hidden`, `critic_hidden`, `hist`, `goal_frames`, `horizon`,
`wm_window`, `wm_batches`, `wm_batch`, `pi_batch`, `lr`, `gamma`, `lam`,
`critic_epochs`, `critic_minibatches`, `observation_noise`, `observation_mode`,
`num_envs`, `buffer_steps`, `warmup_steps`, `wm_only_iters`, `utd`, `iterations`,
`lr_decay_iters`, `checkpoint_every`, `action_noise`, `self_collisions`,
`reset_noise`, `max_episode_steps`, `physics_dt`, `context_resampling`, `seed`.
Use `device: "cpu"` and omit `amp` or use `amp: "none"` for the scalar numerical
learner. `backend: "isaac"` selects the separate genuine CUDA physics adapter;
add `--physics-library` and `--physics-artifact`, set `physics_device_id`, and
match `num_envs` to the fixed exported batch. Missing SDK/artifact fails instead
of changing backend. See `NATIVE_GPU.md` for the real build/producer contract and
`NATIVE_USD.md` for `convert-usd`. The library API exposes
`EnvironmentConfig.randomization`.

The added `reference_storage: "mmap"` path streams source CSV/hash processing
and uses resumable Float64 disk shards with a fixed 64 KiB read window; it does
not map the full corpus or keep full state/body arrays resident. Configure
`motion_cache_dir` and `max_reference_gather_frames`; training and evaluation
loaders use the same backend. The name `mmap` is retained for config compatibility
with Python. See [storage implementation and limits](storage/README.md). Small
native storage regressions have now executed, including eager parity and cache
rebuild; the older unexecuted-test statements below concern migration's broader
physics/learning suite. Full BONES loading and CUDA training remain unexecuted.

Training writes `OUTPUT.report.json` and, with `--evaluate`,
`OUTPUT.evaluation.json`. Override these with `--report` and
`--evaluation-output`. Reports retain the original report format/field names and
iteration metric names, adding native source hashes, exact initialization scope,
MuJoCo version/library hash and backend limitations. `source_files` hashes the
preserved Python comparison sources; `moonbit_source_files` separately hashes the
actual native implementation. `dependencies.torch` is null because Torch is not
loaded. Source roots can be set using `--python-source-root` and
`--native-source-root` when invoking outside the repository root; `moon.mod`
still identifies the executing module.

`--weights` is distinct from `--resume` and the options are mutually exclusive.
It imports four network parameter blocks and five running normalizers. Native
imports require the same scene hash, observation semantics and architecture, but
allow a different catalog/split and optimizer options. Original Torch imports
use only the restricted numeric ZIP/pickle reader, verify every Linear/LayerNorm
and normalizer key, tensor shape and finite value, and reject extra state keys.
Full original `moonrobo.aligned-checkpoint.v1` inputs require the same scene hash
and observation mode. A bare original `learner.state_dict()` additionally
requires an explicitly supplied `--weights-sha256`. Original NumPy physical
snapshots are decoded only as passive numeric data by the reader; they are never
restored. Optimizers, RNG, replay, histories and physical integration state stay
fresh. Unsupported pickle globals/types/devices fail explicitly. Torch resume
is rejected; no cross-backend exact-resume claim is made.

## Compatibility and remaining verification

- New checkpoints use `moonrobo.moonbit-checkpoint.v1` JSON, with the aligned
  learner, replay, normalizers, all Adam moments, RNG states, histories, counters
  and physical integration state. Original Torch `.pt` is supported only through
  the strictly separate weights-only path described above.
- Resume checks configuration and scene/catalog hashes. Physical restore is
  considered exact only if the C integration snapshot round-trips exactly;
  otherwise it resets physics, clears replay/history and recollects warmup.
- Scalar reverse-mode CPU f64 preserves the training equations, but is not a
  CUDA tensor backend or a throughput replacement for paper-scale profiles.
  RNG differs from Torch, and floating-point reduction/initialization draw order
  differs, so matching seeds do not imply bitwise learning-curve parity.
- Exact `--resume` checks complete identity/config/catalog equality. Held-out
  evaluation uses `--weights`; its report records the training source identity
  separately from the evaluation catalog, split and SHA. Automatic evaluation
  creates a separate deterministic single-replica environment and imports the
  just-saved checkpoint by verified SHA.
- Asset XML supports quoted attributes, named XML entities and comments. It
  rejects DOCTYPE/CDATA and numeric/custom entities rather than silently misreading them. Asset compilation
  and physical execution have only been typechecked, not run.
- Tests cover rotation limits, observation/reward contracts, replay warmup,
  boundaries/history/ring/empty restore, reset sampler bootstrap, hard/soft GAE
  and timeouts, full-reference evaluation, AD rotation derivatives, normalizer
  restore, 8-step world fitting, 32-step imagined actor/critic updates, frozen
  critic state gradients, export address/velocity conversion, strict metric
  failures, history isolation, subset/replica accounting, original report fields,
  strict Torch weight mapping and rejected shape/key/nonfinite inputs. Real
  MuJoCo tests additionally cover substeps, motor configuration, context/COM
  resampling, exact environment restore and continuous-versus-split training.
  They were **not executed**.
- All nine original Isaac CPU protocol methods now have test-source counterparts
  in `gpu_protocol/isaac_contracts_wbtest.mbt` and
  `gpu_native/availability_wbtest.mbt`; they call the production protocol with
  an explicit contract-fixture adapter or the real missing-library boundary.
  Additional manifest tests reject solver/config/cache/alias/span mismatches.
  No Isaac/GPU test execution or physical benchmark result is claimed. Original
  Python remains the comparison implementation for the deferred physical suite.

Checks performed: native `moon check` on the package, `physics`, `assets`, `usd`,
`gpu_protocol`, `gpu_native` and `cmd`, including authored test source. Native C
bridges were syntax checked with real installed MoonBit headers and the USD C++
converter with real installed MuJoCo headers. CUDA/APIC C++ and the OpenUSD
validator remain uncompiled because their SDKs are unavailable; no fabricated
headers were used. No `moon test`, conversion, simulator, training run, numerical
differential test, or GPU workload was launched. Exact per-file limits and
upstream native API evidence are in `NATIVE_GPU.md` / `NATIVE_USD.md`.

## Test-source audit and exact external boundaries

| Preserved source | Native authored contracts | Remaining external boundary |
| --- | --- | --- |
| `test_aligned_learning.py` (7 methods) | All seven CPU contracts represented in `cpu_contracts_wbtest.mbt`: hard/soft GAE and timeout, short replay/boundary rejection, ring/empty restore, frozen critic input gradients, 8/32-step learner/optimizer restore, identity-model finite derivatives, compiled export ordering/rotation | Algorithm fixture uses native FK/MDP rather than executing the Python fixture class; numerical differential execution remains deferred |
| `test_aligned_evaluation.py` (9 methods) | All nine contracts represented: early failed denominator, negative/final failure, incomplete/missing catalog, separate strict gate, duplicate/nonfinite rejection, full-clip driver history isolation, subset flag, replica accounting, reject training environment | Native has no mutable Torch train/eval module flag; its deterministic evaluation never updates normalizers or uses observation/action noise |
| `test_aligned_resume.py` (1 method) | Real native MuJoCo split-versus-continuous run compares complete learner, replay, counters, history, RNG and integration snapshot; checks policy warmup ordering | Requires real matching MuJoCo library/headers, G1 assets and 128 real CSV rows; not executed |
| `test_aligned_physics.py` (4 methods) | Real MuJoCo substeps and direct compiled gain/damping/armature/effort range values, actual force bounds, fixed environment context versus calibration, selected episode context/COM, direct ground `floor` friction=0.3, profile semantics | Real fixture and execution deferred |
| `test_smc_learning_differential.py` (4 methods) | Actual architecture/forward/fixed-world8/production-fixed-policy32/replay adapters and actual Adam raw/applied gradient hooks; strict immutable fixture/capture tooling and a separate independent ATen oracle in `learning_differential` | Original executed-Python fixtures are not generated or run. Native f64 outputs retain their true dtype and currently fail Float32 bitwise gates; original thresholds are retained, not widened. See `../learning_differential/AUDIT.md` |
| `test_aligned_isaac.py` (9 methods) | `gpu_protocol/isaac_contracts_wbtest.mbt` ports eight methods against production `TrackingProtocol` with an explicit CPU adapter fixture; `gpu_native/availability_wbtest.mbt` ports real native loader refusal. Solver fields are also strictly checked by manifest tests | CPU fixture checks are not GPU numerical validation. Native CUDA graph compilation/loading/execution and pinned SDK artifact generation are deferred; missing dependencies fail explicitly |
| Parent `test_aligned_data.py` (9 methods) | Portable data/corpus contracts plus actual motion/reset/bin-fix differential adapters, separately transcribed original ATen motion/sampling, exact RNG-call replay and strict source-bound fixture routes | Real acquired corpus and original executed-Python fixtures remain unexecuted; native Double/RNG identity is not inferred from seeds |
| Parent `test_aligned_mdp.py` (6 methods) | Observation ambiguity/prefix, scaled default actions/pullback, relative low/sideways failure and survival derivative, all reward scales/limits, exact native FK pose/velocity against MuJoCo with joint AD pullback checked by native finite differences, zero/tiny-angle/vertical-heading rotation contracts | Real MuJoCo FK test requires acquired G1 scene/library; no execution performed |
| Parent `test_aligned_mdp_differential.py` (5 methods) | Actual observation/reward/critic/FK/quaternion pullback candidate adapters, separate ATen original equations, exact noise-call binding and per-method immutable fixture verification | The independent C++ translation is not original Python execution. Original source-bound fixtures, numerical comparison and all runtime verification remain deferred |

Deferred physical test prerequisites: `MOONROBO_MUJOCO_LIBRARY`, optional
`MOONROBO_ALIGNED_SCENE` and `MOONROBO_ALIGNED_MOTION`. Defaults for the last two
point to `target/learning/g1-aligned-data`. Missing fixtures fail explicitly;
they are never replaced by synthetic physics.
