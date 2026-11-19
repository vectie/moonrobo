# Python physics, SDK, and probe migration

Python sources remain unchanged. No Python process is started by these packages.
This is a parallel implementation, with the remaining differences below. No tests,
training, simulation, hardware initialization, or command publishing were run.
Native MoonBit type checking and C `-fsyntax-only` checking are the current evidence.

## Source mapping and completion

Paths in the first column are under `providers/motion_learning/` unless stated otherwise.
“Partial” explicitly means the original command is not yet replaceable end to end.

| Python source | MoonBit implementation | Status |
| --- | --- | --- |
| `cpu_physics.py` | `src/learning_physics/native.mbt`, `mujoco_stub.c`, `rollout.mbt`, `cli/main.mbt` | Runtime, state/observation, servo validation, reset/friction, reference motions, native stepping, termination, transitions, dataset axes and evaluation CLI implemented. Partial compatibility: the CLI uses named ChaCha8/Box-Muller streams, not NumPy SeedSequence/PCG64; elapsed time resolution is milliseconds; provider digest bundle and NumPy version are not emitted. Native MuJoCo execution awaits later validation. |
| `bridges/sdk_e1/sdk_e1_readonly_bridge.py` | `src/sdk_e1_native/bridge.mbt`, `native.mbt`, `sdk_loader.c`, `sdk_adapter.cpp`, `cli/main.mbt` | Fixture, shape validation, frame IDs, capture times, atomic output, once/live polling, actual SDK C++ telemetry APIs implemented. Partial deployment: SDK adapter must be built with target architecture dependencies; no live validation. |
| `bridges/sdk_e1/sdk_e1_high_control_writer.py` | same SDK package | Typed command load/validation, dry run, actual SDK publish, watch startup suppression, timestamp/size change tracking implemented. Partial compatibility: JSON loading requires typed fields and rejects nonfinite values instead of Python coercions; live adapter build/qualification pending. |
| `model_probe.py` | `src/learning_probes/model_summary.mbt`, `returns.mbt`, `physical_native.mbt`, `study/model.mbt`, `cli/` | Native checkpoint loading, real collection, exact integration replay checks, analytic action gradients through learned imagination, common-scale MSE, physical directional/ascent perturbations, XY translation audit, missing-window records and full summaries/report runner implemented. CLI command `model`; `summarize-model` also reuses existing JSON evidence. Native execution and Python comparison deferred. |
| `critic_probe.py` | `src/learning_probes/returns.mbt`, `study/critic.mbt`, `cli/` | Selected/latest native critic loading, selected actor's real trajectories, complete hard/soft returns, analytic XY state gradients, translation audit, true-fall censor exclusion, saturation and full report/summary runner implemented. CLI command `critic`; runtime comparison deferred. |
| `actor_update_probe.py` | `src/learning_probes/directions.mbt`, `physical_native.mbt`, `study/actor.mbt`, `cli/` | Native actor/critic/world-model/replay binding, train-only constant-goal origin collection, exact closed-loop replay checks, offline/on-policy analytic fresh-Adam directions, multipliers, restored physical windows, direction artifacts and full report/summary runner implemented. CLI command `actor-update`; runtime comparison deferred. |
| `paired_model_probe.py` | `src/learning_probes/study/actor.mbt` `run_actor(paired=true)`, `cli/` | Initial/adapted native models with strict actor/model SHA pairing and replay layout/digest checks, both bootstrap flags, recent predicted changes, short/full physical windows, per-origin records and report/summary runner implemented. CLI command `paired-model`; runtime comparison deferred. |
| `replay_direction_probe.py` | `src/learning_probes/study/replay.mbt`, `temporal.mbt`, `directions.mbt`, `cli/` | Full original study traversal, float32 teacher replay byte digest, initial calibration JSONL and source SHA checks, causal history/reference reconstruction, coupled teacher/current/mixed sampling, finite-value AD updates, both tail flags, exact physical restoration, alignment/frozen-weight checks and report/direction artifacts implemented. CLI `replay-direction`. RNG remains xorshift32; saved first-update reconstruction rejects differences instead of claiming Torch parity. Execution deferred. |
| `dynamic_refit_probe.py` | `src/learning_probes/study/dynamic.mbt`, `temporal.mbt`, `cli/` | Full old-only/mixed × three fit seeds × frame/preview prior-study traversal; model ancestry, scale, incoming-policy and baseline SHA bindings; analytic fresh directions, scaled physical branches, centered slopes, latest/selected prediction diagnostics and report/direction artifacts implemented. CLI `dynamic-refit`. Execution deferred. |
| `temporal_probe.py` (subsequently delegated by parent) | `src/learning_probes/study/temporal_probe.mbt`, `temporal.mbt`, `cli/` | Full training-motion origin capture with causal history/absolute command phase, selected-refinement bindings and frozen buffers, analytic Adam/actual-selected directions, exact physical replay, scaled branches, centered slopes, XY-excluded open-loop predictions, per-origin evidence and original study report protocol implemented. CLI `temporal`. Execution deferred. |
| `compare_dynamics.py` | `src/learning_probes/directions.mbt` `common_metrics`; parent agent owns `src/learning_comparison/` | Complete common-scale numeric MSE, persistence and late-window metric kernel here. Full native checkpoint/batch CLI and report integration transferred to parent agent; see its delivery status. |
| `teacher_step_verification.py` | `src/learning_probes/study/teacher.mbt`, `directions.mbt`, `cli/` | Original frame/preview study traversal, selected-update filtering, actor SHA binding, legacy/native parameter-direction reconstruction, normalization/action-buffer checks, max error and equality report implemented as `teacher-step`. `verify-teacher` also verifies explicit native actor/direction/selected paths. Legacy additions are rounded to float32 before equality checks. Execution deferred. |
| `test_model_probe.py` | `src/learning_probes/probes_test.mbt` | Both sparse-summary cases ported, type checked, not run. |
| `test_critic_probe.py` | same | Complete two-step return case ported, type checked, not run. |
| `test_actor_update_probe.py` | `src/learning_probes/actor_update_contract_test.mbt` | Complete one-parameter toy actor + action-additive dynamics + linear critic reverse-AD contract ported: fresh Adam direction, reversed/zero/positive scaling, buffer/source preservation, no-tail sign reversal, separate reward/bootstrapped prediction changes and immutable configuration. Type checked, not run. |
| `test_pose_goals.py` | `src/learning_physics/pose_goals_test.mbt` | Both contracts ported: repeatable seeded native-CLI draws, lower/waist/upper bounds across 12 seeds, each coordinate's range exceeding .01, and NaN amplitude rejection. This tests the declared native stream rather than claiming NumPy PCG64 sample equality. Type checked, not run. |

## MuJoCo native build

The shim includes `<mujoco/mujoco.h>` if it is available to the compiler. If it is
not available, construction raises a clear error; the fallback does not simulate
physics. At runtime `--library` names the actual MuJoCo shared library. Header and
library versions are checked before model structs are accessed. No Python module
is imported even when using the native library distributed in the existing venv.

For this checkout the matching headers are currently in
`target/learning-venv/lib/python3.12/site-packages/mujoco/include/`.
Set `CPATH` to the absolute include directory when compiling/running MoonBit,
or install the matching headers into the system compiler's include search path.
Do not change `moon.pkg` to an absolute user-specific path.

Deferred execution example (run only when machines are available):

```sh
CPATH=/ABSOLUTE/MUJOCO/include moon run src/learning_physics/cli --target native -- --scene /ABSOLUTE/scene.xml --experiment examples/learning/g1-cpu-experiment.json --library /ABSOLUTE/libmujoco.dylib --output /ABSOLUTE/moonbit-physics
```

The CLI emits `dataset.json` and `report.json`. The report names its RNG difference.
For strict cross-language replay, the public `rollout` accepts externally supplied
normal draws and reference offsets/schedules; use the same saved draws for Python
and MoonBit instead of assuming equal integer seeds imply equal streams.

The runtime also exposes actual model body/joint topology and qpos/dof addresses
for the aligned migration. `set_state` sets concatenated qpos/qvel/activation and
recomputes derived MuJoCo fields. Integration replay uses `mjSTATE_INTEGRATION`.
The aligned adapter can additionally configure real model PD gains, damping,
force ranges, armature, timestep, geom collision masks, ground friction, and torso
inertial position. These edit the actual MuJoCo fields using the same rules as
`aligned/mujoco_env.py`; COM offsets are always relative to cached original values.
`reset_data` uses `mj_resetData`, and `set_control` writes controls without stepping.

## SDK native build and CLI

`src/sdk_e1_native/CMakeLists.txt` builds the ABI adapter against the SDK's actual
`highcontroller.cpp`, Eigen3, Threads, driver, CycloneDDS and yaml-cpp libraries.
Configure `SDK_ROOT` and `SDK_LIBRARY_DIR` for the deployment architecture. This
adapter does not need pybind11. This build configuration was not executed.
`CYCLONEDDS_URI`, when unset, is set from `--sdk-root/config/dds.xml` before live
initialization. DDS access occurs only in explicitly chosen live modes.

Deferred commands:

```sh
cmake -S src/sdk_e1_native -B target/sdk-e1-native -DSDK_ROOT=/ABSOLUTE/sdk -DSDK_LIBRARY_DIR=/ABSOLUTE/sdk/lib/aarch64
cmake --build target/sdk-e1-native
moon run src/sdk_e1_native/cli --target native -- read --once
moon run src/sdk_e1_native/cli --target native -- read --live --library /ABSOLUTE/libmoonrobo_e1.so --sdk-root /ABSOLUTE/sdk --output /ABSOLUTE/snapshot.json
moon run src/sdk_e1_native/cli --target native -- write --dry-run --input /ABSOLUTE/command.json
```

Both `read` and `write` support `--self-check`. Watch mode deliberately skips a
command already present on startup and acknowledges signatures only after a
successful publish. The SDK singleton owns background threads without exposing a
shutdown API; the native loader therefore retains the shared module for process
lifetime instead of unloading running SDK code during GC.

## Deferred verification

The individual Python-test-to-MoonBit-test mapping is recorded in
[`TEST_MIGRATION.md`](TEST_MIGRATION.md). All original assertions in the assigned
pose/model/critic/actor and reference action/feedback tests now have corresponding
test source. Test execution is still deferred.

1. Run the ported pure unit tests when permitted.
2. Build native shims on target hosts with real SDK/MuJoCo dependencies.
3. Compare identical saved initial integration states, controls, and references.
4. Compare Python float32/PyTorch results against MoonBit Double numerics, including
   the clipped gradient and Adam epsilon order, before making equivalence claims.
5. Execute the full probe checkpoint/report chains against saved artifacts and
   verify all source bindings, output schemas and numerical comparisons.

The implemented collection studies use the existing configuration files,
with one additional explicit `--library` argument for MuJoCo. Model paths point
to versioned native checkpoints or supported legacy PyTorch ZIP checkpoints;
policy directories resolve `actor-seed-N.moon.json` first and then the original
`actor-seed-N.pt` (likewise latest checkpoints). Paired
actors must declare `paired_dynamics_sha256` matching the adapted model artifact;
the runner rejects artifacts without that provenance instead of assuming a pair.

```sh
moon run src/learning_probes/cli --target native -- model --initial INITIAL.moon.json --corrected CORRECTED.moon.json --scene SCENE.xml --library LIBMUJOCO --config examples/learning/g1-model-probe.json --experiment EXPERIMENT.json --output MODEL_REPORT.json
moon run src/learning_probes/cli --target native -- critic --policies POLICY_DIRECTORY --scene SCENE.xml --library LIBMUJOCO --config examples/learning/g1-critic-probe.json --experiment EXPERIMENT.json --output CRITIC_DIRECTORY
moon run src/learning_probes/cli --target native -- actor-update --train TRAIN_WINDOWS.npz --dynamics DYNAMICS.moon.json --policies POLICY_DIRECTORY --scene SCENE.xml --library LIBMUJOCO --config examples/learning/g1-actor-update-probe.json --experiment EXPERIMENT.json --output ACTOR_DIRECTORY
moon run src/learning_probes/cli --target native -- paired-model --train TRAIN_WINDOWS.npz --initial INITIAL.moon.json --adapted ADAPTED_DIRECTORY --policies POLICY_DIRECTORY --scene SCENE.xml --library LIBMUJOCO --config examples/learning/g1-paired-model-probe.json --experiment EXPERIMENT.json --output PAIRED_DIRECTORY
moon run src/learning_probes/cli --target native -- temporal --config examples/learning/g1-temporal-probe.json --experiment EXPERIMENT.json --incoming INCOMING_POLICY_DIRECTORY --refined REFINED_POLICY_DIRECTORY --dynamics DYNAMICS.pt --scene SCENE.xml --library LIBMUJOCO --output TEMPORAL_PROBE_DIRECTORY
moon run src/learning_probes/cli --target native -- dynamic-refit --study REFIT_STUDY_DIRECTORY --probe ORIGINAL_TEMPORAL_PROBE_DIRECTORY --policies INCOMING_GROUPED_POLICY_DIRECTORY --initial INITIAL.pt --scene SCENE.xml --library LIBMUJOCO --output REFIT_PROBE_DIRECTORY
moon run src/learning_probes/cli --target native -- replay-direction --config ACTOR_CONFIG.json --probe-config REPLAY_PROBE_CONFIG.json --collection COLLECTION.json --data TEACHER_DATASET.json --policies INCOMING_POLICY_DIRECTORY --study VALUE_STUDY_DIRECTORY --dynamics DYNAMICS.pt --scene SCENE.xml --library LIBMUJOCO --output REPLAY_PROBE_DIRECTORY
moon run src/learning_probes/cli --target native -- teacher-step --study TEACHER_STUDY_DIRECTORY --incoming INCOMING_GROUPED_POLICY_DIRECTORY --probe REPLAY_GROUPED_PROBE_DIRECTORY --output TEACHER_VERIFICATION.json
```

Native probe report schemas retain the original evidence metrics and additionally
name their numerical backend. Parameter directions are stored as native
`parameter-direction-collection` checkpoints. Sampling uses the shared MoonBit
xorshift32 backend, so equal Python seeds are not a parity guarantee. Direct
Supported PyTorch `.pt` ZIP input is decoded by the repository's data-only,
allowlisted Torch importer and mapped to canonical model/checkpoint layouts.
No Python subprocess fallback or pickle global execution exists. Legacy checkpoint
loading and numerical parity have not been exercised on this machine.

The probe utility CLI can also re-summarize existing Python JSON records without
rerunning simulation:

```sh
moon run src/learning_probes/cli -- summarize-model --input /ABSOLUTE/model-report.json --output /ABSOLUTE/model-resummarized.json
moon run src/learning_probes/cli -- verify-teacher --initial /ABSOLUTE/initial.json --direction /ABSOLUTE/direction.json --selected /ABSOLUTE/selected.json --kind temporal-actor --output /ABSOLUTE/verification.json
```

The second command consumes versioned native checkpoints. Its direction
checkpoint has model kind `parameter-direction`, metadata `actor_sha256`, and
delta tensors named after actor parameter tensors. Omitted tensors are preserved
unchanged, including normalization buffers. The separate `teacher-step` command
also accepts supported legacy Torch direction artifacts through the data-only importer.
