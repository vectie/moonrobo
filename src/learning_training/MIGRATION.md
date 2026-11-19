# Python / MoonBit parallel implementation

Core script routing is now native: see `launch/README.md`. Thirty workflow entrypoints plus the dynamic-refit report filename adapter retain complete original scripts and SHA receipts under `scripts/python_reference/`. `launch/cmd` strictly maps reviewed provider descriptors and original flags to real native functions, including newly connected policy collection/evaluation and compatible separate policy replay. Descriptors ending `.py` are never executed. New artifact paths use `.moon.json`; old `.pt` inputs remain passive restricted-reader inputs. Missing/unknown options and missing explicit native MuJoCo libraries fail instead of invoking an interpreter.

Checkpoint copies now use the native `checkpoint-copy` operation: validate and preserve native JSON bytes, or actually convert restricted Torch ZIP into native JSON. A source/destination SHA receipt and exact `.pt` companion preserve format and original-report provenance; there is no raw `.pt` to `.moon.json` rename. Optimizer/RNG resumption is not implied. Three regression test sources cover copy priority, native byte identity and invalid-Torch/output rejection; none were executed. Native probe/calibration/refinement directories accept pre-created output paths and nested parents, matching original workflow directory behavior.

Final policy/PPO/supervised physical evaluation explicitly spans **all** experiment cases, as in original `evaluate_physics(split=None)`: canonical three cases and three seeds yield nine trials. Validation selection remains validation-only; library calls explicitly passing `test` still select only that split. A new real-runtime test source asserts the 9-versus-3 distinction, unexecuted. Final physics report groups retain both counted summaries and complete trial/replay arrays for scoring and update-zero checks. Original automatic unittest steps in orchestration were replaced with explicit deferred-test records, not a fake pass or another test invocation.

Python files and existing run paths remain intact. New native MoonBit packages compute and train directly; they never launch Python. All listed packages, CLIs and test sources have passed `moon check`. No tests, training, MuJoCo execution, benchmarks, or Python/MoonBit differential comparisons were run in this session, as requested.

The implementation provides runnable counterparts for the assigned learning experiments. This does not establish numerical or learning-quality parity, broad Torch checkpoint compatibility, or byte-for-byte equivalence of original reports.

## Per-source status

Original sources are under `providers/motion_learning/`.

| Original source | MoonBit counterpart | Differences / remaining validation |
| --- | --- | --- |
| `dynamics.py` | `dynamics.mbt`, `fit.mbt`, `artifacts.mbt`: residual SiLU MLP, zero final layer, training-only population normalization, XY invariant encoding, normalized quaternion, arbitrary-horizon reverse-mode BPTT, Adam, gradient clipping, late sampling, validation selection, persistence/late metrics, gradient probe; full train CLI, best/latest JSON weights, SHA and reload check | Float64 / RNG / report schema differ; restricted original TorchZIP inputs are accepted through `load_learning_checkpoint`; original timing/thread configuration is not reproduced |
| `root_integrated_dynamics.py` | `Dynamics::new(root_integration_dt=Some(dt))`: trapezoid root integration from offsets 36..39, G1 71-state check, checkpoint dt | Constructor/load path available; no separate root-integrated fit CLI in Python either; numerical parity pending |
| `online_dynamics.py` | `replay.mbt`: train-only finite timestamp/reset-safe windows, bounded recent replay, independent RNG, old/new mixed minibatches, persistent optimizer and counters; integrated into native policy runner when `online_model_updates > 0` | No exact Torch RNG state equivalence; immutable normalization is structural (updates mutate network parameters only) |
| `behavior_cloning.py` | `supervised.mbt`, `physics/supervised_runner.mbt`: actual point batches, early-time half sampling, full Adam loop, validation at update zero and configured updates, ranking, untrained zero critic bundle, best/latest checkpoints, selected-actor whole-corpus training-action RMSE, real final physics evaluation and saved data; `cloning` CLI | Statistics/reload arithmetic unverified against Torch |
| `policy.py` | `policy.mbt`, `actor_critic_fit.mbt`, `physics/runner.mbt`: actor/critic, observation/gravity/reward/continuation, full imagined gradients and bootstrap ablation, imagined and physical GAE/returns, critic epochs/minibatches, real physics calibration/evaluation (including initial calibration before update-zero validation and paired snapshots), all three critic sources, warm-start actor+critic units/weights, separate collection experiment, online world-model adaptation, gzip physics-return evidence, best/latest snapshots; selected/completed model rounds, optimizer-step count, paired model SHA, validation/test model metrics and gradient probe, frozen-weight/unit checks, calibration seed/tail/MAE/source audit, actor initialization and return/gradient history | Versioned MoonBit report/checkpoint schema; canonical Float64 JSON parameter digests differ from Torch's named Float32 byte digests; timing and numerical parity unverified |
| `ppo.py` | `ppo.mbt`, `actor_critic_fit.mbt`, `physics/ppo_runner.mbt`: actual MuJoCo collection, stored Gaussian pre-tanh latent samples, true-terminal/time-limit GAE, normalized advantages, shuffled minibatch epochs, KL early stop, clipped surrogate, critic fitting, full-update reservation against step budget and wall-clock limit, validation selection, warm start, saved best/latest, reload and final baseline/test evidence; native baseline servo diagnostic (per-joint mean/RMS error, gain-derived residual force, root pose) and per-goal-column update norms/coverage; `ppo` CLI | Evaluation/collection RNG differs from NumPy/Torch; float precision, reduction order and versioned report schema differ |
| `counterfactual.py` | `physics/branches.mbt`, `physics/counterfactual_runner.mbt`: parent trace snapshots, complete integration restoration, parent controls/history, antithetic clipped Gaussian pulses, train-only physical branches, physical falls/truncations, parent-time timestamps, saved origin/parent/omission metadata, source-family ownership, unperturbed replay check over all state/observation/action arrays, full dataset/report/summary CLI | Pulse RNG differs; episode IDs include full digest rather than Python's abbreviated suffix; versioned MoonBit report format |
| `dataset_aggregation.py` | `supervised.mbt`, `physics/supervised_runner.mbt`: real privileged native MuJoCo balance teacher at student-visited states, train-only teacher labels kept separate from actual student controls, bounded recent points, 50/50 old/new minibatches, persistent Adam, validation selection, warm actor bundle, fitted Python source digest check, gzip student-physics + labels evidence, full final physics/reload/checkpoint CLI | Source digest check proves preserved fitted Python source identity, not cross-language teacher parity. Teacher parameter mappings explicitly translate `pitch_bias_rad`/`residual_bound_rad`; report fields differ |
| `dynamic_refit.py` | `actual_actions.mbt`, `fit.mbt`: native-validated manifest, per-source SHA, datasets/gzip student JSONL, counts/schema/split/identity checks, actual applied actions only, reset/timestamp windows including final stride endpoint, frozen units, old-only/mixed arms, update-zero selection, hashed `training-input.json`, full native CLI and reload; old/added-training, validation and test diagnostics, full selection history and frozen-model gradient probe | Mixed old/new RNG draw order differs; checkpoint/report formats differ |

## Native commands (execution deferred)

Run from repository root. Output parent directories must exist. These are product CLI packages, not standalone `.mbtx` scripts, so local source imports resolve from this checkout.

```sh
# dynamics.py
moon run src/learning_training/cmd -- TRAIN_BATCH VALIDATION_BATCH TEST_BATCH CONFIG OUTPUT

# dynamic_refit.py
moon run src/learning_training/cmd -- refit CONFIG ACTUAL_ACTION_MANIFEST INITIAL_MOON_JSON VALIDATION_BATCH TEST_BATCH OUTPUT

# policy.py (optional actor+critic weights-only warm start)
moon run src/learning_training/physics/cmd -- TRAIN_BATCH DYNAMICS_MOON_JSON MUJOCO_LIBRARY SCENE CONFIG EXPERIMENT OUTPUT [WARM_START_DIRECTORY]

# ppo.py
moon run src/learning_training/physics/cmd -- ppo TRAIN_BATCH MUJOCO_LIBRARY SCENE CONFIG TRAIN_EXPERIMENT EVAL_EXPERIMENT OUTPUT [WARM_START_DIRECTORY]

# behavior_cloning.py
moon run src/learning_training/physics/cmd -- cloning TRAIN_BATCH MUJOCO_LIBRARY SCENE CONFIG EXPERIMENT OUTPUT

# dataset_aggregation.py
moon run src/learning_training/physics/cmd -- aggregation TRAIN_BATCH MUJOCO_LIBRARY SCENE CONFIG EXPERIMENT OUTPUT POLICIES_DIRECTORY TEACHER_JSON COLLECTION_EXPERIMENT

# counterfactual.py
moon run src/learning_training/physics/cmd -- counterfactual MUJOCO_LIBRARY SCENE CONFIG EXPERIMENT POLICIES_DIRECTORY OUTPUT
```

`MUJOCO_LIBRARY` is an installed MuJoCo dynamic library matching the native runtime headers. Runtime state/stepping/geometry/Jacobians use MuJoCo directly. No commands above were run during migration.

## Numerical and checkpoint contract

`src/learning_numeric` supplies a reverse-mode scalar tape, Double arrays, SiLU dense networks, population normalization, Adam, gradient norm/value clipping, and xorshift32/Box–Muller RNG. Per-layer parameters are row-major `[output,input]` weights followed by output biases. A minibatch binds parameters once and reuses them throughout model unrolling. Only parameters passed to Adam mutate; frozen world-model input gradients remain live.

The tape includes exp/log/sqrt/tanh/sigmoid/SiLU, clipping, minimum, trigonometric functions and atan2. Zero-adjoint disconnected nodes are skipped so unused singular branches do not contaminate gradients. Genuine singular derivatives on active paths still require the caller's declared regularization.

This implementation uses float64. Original training mostly uses Torch float32; some probes use float64. RNG algorithms and reduction order differ. Equal seed integers do not imply equal initial weights, samples, noise or learned checkpoints. MuJoCo numerical equivalence needs shared injected draws/fixtures. Statistical and learning-quality parity remains unverified.

Checkpoint output format is `moonrobo.moonbit-checkpoint.v1`, with `.moon.json` names. The restricted safe TorchZIP reader accepts the original dense actor/critic/dynamics state-dict layouts through `load_learning_checkpoint`; it does not execute pickle globals or support arbitrary Python object graphs. Incoming policy directories prefer `.moon.json` and fall back to `.pt`. Actor bundles store normalization, body indices, control bounds (explicit infinity masks), action scale and network. Critic bundles additionally store frozen units, bounded-value semantics, translation encoding and parameters. Dynamics bundles store units, input encoding and root integration dt. Saved training checkpoints are weights-only and do not claim exact resumable optimizer/RNG state. For future resume support, Adam has JSON serialization and deep snapshot/restore, and RNG has exact state getters/setters/snapshot.

## Deferred validation

Type-checked test sources include `src/learning_numeric/numeric_test.mbt` (shared-node reverse gradients/reset, disconnected singular nodes, atan2 derivative, population floor, Adam update/snapshot) and the following source-contract translations. This assigned group contains eight original `test_*.py` files; `behavior_cloning.py` has no separate original test file.

| Original test source | MoonBit test source | Preserved contracts |
| --- | --- | --- |
| `test_dynamics.py` | `training_test.mbt`, `source_contracts_wbtest.mbt`, `../learning_comparison/source_contract_test.mbt` | Common-scale learned/persistence errors and explicit late subset; late boundary/pools including rejection; global versus late-weighted selection including absent-evidence rejection; multi-step XY equivariance, action gradient and checkpoint predictions |
| `test_policy.py` | `training_test.mbt`, `source_contracts_wbtest.mbt` | Physical truncation/true-terminal returns; critic zero-XY values and gradients including legacy saved-input encoding; imagined terminal/time-limit GAE; bootstrap ablation preserves states/rewards and the live boundary gradient |
| `test_ppo.py` | `training_test.mbt` | Falls remove bootstrap; time limits retain bootstrap without leaking a following episode |
| `test_online_dynamics.py` | `training_test.mbt`, `source_contracts_wbtest.mbt` | Reset/terminal/gap-safe windows, heldout rejection, recent replay cap, persistent step count, changed weights with frozen normalization and independent actor RNG, live frozen-model action derivatives |
| `test_root_integrated_dynamics.py` | `training_test.mbt`, `source_contracts_wbtest.mbt` | Trapezoid integration, multi-step XY equivariance, finite nonzero action-to-root-position gradient, checkpoint round trip |
| `test_dynamic_refit.py` | `source_contracts_wbtest.mbt` | Actual controls exclude teacher targets, strided final endpoint, gaps, gzip manifest counts/heldout/source-SHA rejection, selected/latest exports with frozen incoming units, training-input SHA and reload metrics |
| `test_counterfactual.py` | `physics/source_contracts_wbtest.mbt` | Real native toy MuJoCo scene: restored zero-pulse replay, parent times, previous controls, pulse duration, terminal/truncation flags, source family and solver-state restoration |
| `test_dataset_aggregation.py` | `physics/source_contracts_wbtest.mbt` | Real native toy MuJoCo scene and deterministic teacher: labels remain separate from actual student controls; ordering/observations/goals agree; invalid heldout case is never visited |

The native physical fixtures require `MOONROBO_MUJOCO_LIBRARY` at later execution and fail explicitly if it is absent. They use the original toy free-root/hinge servo setup with added teacher support sites; the aggregation test uses a real deterministic native teacher in place of Python mocks. Dense-network fixtures use compact MoonBit dimensions and float64 while asserting the original behavioral contracts. Negative abort-based guards use MoonBit's `panic ` test naming convention.

Tests were not executed. Runner gradient probes and reload checks execute only when these CLIs are later run. Type checking does not establish those runtime checks have passed.

## Review fixes and remaining production details

Review corrected disconnected zero-adjoint singular-node propagation in reverse AD; seed-zero/seed-one aliasing; exact max/min tie gradients for actor clipping; finite Adam configuration/norm checks; independent per-reset physics and reference RNG streams so prior policy survival cannot alter a later paired reset; initial physical critic/model calibration before update-zero validation and paired best snapshots; logged-observation reconstruction with the original tolerances; warm-start body/model/action/gamma checks; separate latest/best update metadata; selected/latest actor-to-adapted-model SHA pairing; explicit unbounded-actuator masks; and `CreateOrTruncate` output modes. These are source/type-check reviews, not runtime validation.

The original PPO baseline servo diagnostic and per-goal-column update norms, selected-actor cloning training-action RMSE, and refit old/added-training metrics plus gradient-probe reports are now connected to the native drivers. The refit reload checks compare full selected test metrics and incoming normalization buffers; the diagnostic probe is checked for model immutability. No original Python source has been deleted or routed through a Python subprocess. Exact Float32 learning trajectories, Torch optimizer restart interchange and performance remain unverified.

Policy online-model evidence now records selected/completed adaptation rounds, optimizer steps, physical batch SHA, selected/latest model hashes and actor pairing, frozen normalization, canonical model validation/test input hashes, complete prediction metrics and frozen-model gradient probes with selected-model reload checks. Physical critic batches include reset seed, actor parameter digest and its declared native encoding, soft targets/tail values, transitions/episodes/falls/time limits, fit MAE and model-update counters. Actor history includes imagined return, gradient norm and current calibration evidence; final reports include warm-start lineage, weights-changed/frozen checks, original-source and native-provider hashes, input hashes and qualification aggregation. The configured `online_dynamics_output` holds model files and its fit report; when it equals the policy output directory the fit report is named `online-dynamics-report.json` to preserve both reports. These runtime audits have been type-checked but not executed.
