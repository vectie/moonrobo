# Reference root diagnostics: parallel MoonBit providers

All three Python files remain unchanged. These implementations use the existing native MoonBit dynamics/autodiff/reference/NPZ/MuJoCo APIs and never invoke Python. Only `moon check` has been executed; no fits, physical sweeps, decomposition evaluations, export gates, or tests have been run.

| Original Python | MoonBit implementation | Retained behavior |
|---|---|---|
| `providers/motion_learning/reference_root_integration.py` | `common.mbt`, `integration.mbt`, `cli` | Source-report, actor-initialization, reference-manifest and initial-critic state hashes; common-first-collection training only; separate model-diagnostic records; identical initial weights/normalization and fresh Adam for paired free/root-integrated hypotheses; identical minibatch stream hash assertion; H8/H32 within-episode windows at original half-horizon stride; normalized/persistence/root-position/root-velocity errors; all nine episode-start actor gradients; unit parameter direction; epsilon 0.001 raw-logit RMS calibration with original 1e-8 response floor; unchanged critic/model checks; actual baseline and signed-amplitude MuJoCo trajectories; saved direction/checkpoint/NPZ hashes and original report fields. |
| `providers/motion_learning/reference_root_decomposition.py` | `decomposition.mbt`, `cli` | Existing directions only, original response normalization, prefix with a zero critic tail and full calibrated value tail, actual reverse-mode actor directional derivatives, central differences at 1e-6/1e-7/1e-8 including active-step counts, original 1e-4+1e-3*abs(numeric) consistency rule, stored physical finite-amplitude secants, unchanged model/value and restored actor guards. No physics or fitting is called by this command. |
| `providers/motion_learning/reference_root_export.py` | `export.mbt`, `float32.mbt`, `cli` | Model/direction/critic/probe/actor byte hashes; exact base actor and direction-name/hash checks; deterministic origin-zero probe law; strict storage dtype and continuity checks; causal actual/reference features and actor logits/actions rebuilt; reward/fall and full/H32 returns rebuilt; original maxima and typed `record`/`dataset`/`maxima` JSONL schema. |

## Deferred commands

Run from repository root after resources are available:

```text
moon run src/learning_reference_roots/cli -- integration SOURCE LIBMUJOCO SCENE OUTPUT src/learning_reference_roots/integration.mbt
moon run src/learning_reference_roots/cli -- decomposition STUDY src/learning_reference_roots/decomposition.mbt
moon run src/learning_reference_roots/cli -- export STUDY LIBMUJOCO SCENE
```

As in the original integration provider, `OUTPUT/config.json` and `OUTPUT/initial/actor-zero-output.pt` must already exist; a native `.moon.json` initial actor may be supplied instead, but its bytes must match the source report's declared initialization hash. Existing original study paths and original `.pt` direction/value/model files are accepted through the structural Torch readers. New files are `.moon.json` checkpoints.

## Numerical boundaries and strict export gates

New native fits, neural networks, gradients and physical collection use Float64 and xorshift32, so fresh weights/minibatches are not claimed to equal Torch's Float32 RNG or learning results. Paired hypotheses within a native run share exactly the same initial tensors and sampled batches. New reports declare `numerical_backend=moonbit-float64`, `rng=xorshift32; not Torch-identical`, and `parity_verified=false`; their physical arrays must be `<f8` at export. Historical reports without that explicit backend declaration must still have original `<f4` state arrays.

Legacy export has a separate Float32 arithmetic path: independent Float operations/rounding for dense networks, policy feedback, FK, causal feature transport/filtering, shared reward, quaternion normalization and parameter perturbations. `learning_balance/float32/body_poses` is reused for geometry. Operator accumulation and transcendental library differences can still prevent exact Torch reconstruction. No gate is widened to conceal such a mismatch:

- Achieved raw-logit RMS differs from the target by at most **1e-5**.
- Reconstructed actor mean error is at most **8e-5**; action and feature limits come from the original source config.
- Reward error is at most **1e-6**, and falls match exactly.
- Recomputed prefix/full physical returns differ from their archived report values by at most **1e-10**.

An export that fails any gate stops rather than emitting a success report. Float32 scientific parity remains unverified until the deferred comparison is actually run.

`root_contract_wbtest.mbt` adds four pending pure algorithm regressions: paired
initial model tensors/root trapezoid gradients, horizontal translation,
episode-local decomposition returns/origins/central secants, and analytic H8/H32
root position/velocity metrics. They have been native type checked and have not
been executed. See `../learning_reference/TEST_MIGRATION.md` for exact mapping.
