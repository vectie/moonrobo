# Aligned learner: optional GPU physics

`providers/motion_learning/aligned/isaac_env.py` connects the aligned learner to
Isaac Lab 3's kit-less Newton / MuJoCo-Warp simulator. CPU and GPU paths share
the motion library, policy inputs, rewards, relative termination, adaptive
reset sampler, world model and imagined GAE learning code. The GPU module can
be imported on a CPU host without Isaac Lab installed.

The API target is Isaac Lab commit
[`46d6cc3d7b115906fad12efd372fbf69f4e3d3ed`](https://github.com/isaac-sim/IsaacLab/commit/46d6cc3d7b115906fad12efd372fbf69f4e3d3ed),
matching the local `../smc` reference implementation. Its
[`launch_simulation` API](https://github.com/isaac-sim/IsaacLab/blob/46d6cc3d7b115906fad12efd372fbf69f4e3d3ed/source/isaaclab/isaaclab/app/sim_launcher.py)
accepts the explicit headless launcher configuration used by this adapter.
No claim is made that a different Isaac Lab revision is compatible.

| Setting | Aligned GPU backend |
| --- | --- |
| Physics | Newton with MuJoCo-Warp, MuJoCo contacts |
| Control / physics step | 0.02 s / four substeps of 0.005 s |
| Solver | `implicitfast`, pyramidal friction cone |
| Robot | G1 29 DoF, retarget-model USD with MuJoCo physics variant |
| Action | Default posture + motor-specific scale × normalized action + episode calibration |
| Joint drives | The shared `robot.py` motor armatures, effort and velocity limits, stiffness and damping |
| Self-collisions | Enabled by default; a profile can explicitly set `self_collisions: false` |
| Numeric precision | FP32 default; `amp: bf16` is an explicit learner MLP option, physics remains FP32 |
| Reset sampling | Shared return-bin sampler, including mean aggregation of repeated bins |
| Friction / COM resampling | `episode` for the paper-oriented profile; `environment` for the smc profile |
| Resume | Learner/optimizer restored; new physical episodes and replay refill |

The pinned Newton manager divides `SimulationCfg.dt` by `num_substeps` when
constructing the solver timestep, then executes that many solver steps. Thus
the configured 0.02 / 4 is 0.005 s per solver step; it is not four 0.02 s steps.
See the pinned
[`initialize_solver` and `_run_solver_substeps`](https://github.com/isaac-sim/IsaacLab/blob/46d6cc3d7b115906fad12efd372fbf69f4e3d3ed/source/isaaclab_newton/isaaclab_newton/physics/newton_manager.py).

Both this adapter and `smc` reject a USD whose exposed joint-name order differs
from `G1_JOINT_NAMES` before reading raw joint tensors. They do not assume that
an arbitrary imported USD has the SDK order, nor silently reorder one. The
reset state, observations and action targets therefore use the same accepted
order. The training collector's noisy action is capped at ±20 as in `smc`;
deterministic evaluation passes the policy output without that collection cap.

The collision setting and optional bf16 mode are recorded in the run's saved
configuration. The old CPU reference experiments retain their previous
protocol; this is a distinct method-aligned baseline.

## Runtime and robot assets

Use a CUDA host with the pinned Isaac Lab kit-less environment, Newton and
MuJoCo-Warp installed. The repository's ordinary CPU learning virtualenv does
not contain those dependencies. The adjacent `smc/README.md` describes its
pinned container build. Run the numerical module with that container's Python
interpreter and mount this repository plus the motion/robot assets into it.

The USD is a required external asset. It must be converted **offline**, before
launching the simulator, from the same retarget robot used for kinematics and
motion data. The repository's `aligned.assets` module handles both the native
URDF compilation and optional USD conversion, registering the importer's schema
before conversion; it has no runtime dependency on `../smc`. In the pinned
GPU environment, run:

```bash
python -m providers.motion_learning.aligned.assets \
  --mjcf /data/g1_description/g1_29dof.xml --usd-output /data/g1_usd
```

This optional conversion entrypoint is implemented but was not executed on the
CPU host. Keep the generated USD
payload directory together with its `.usda` entrypoint. Supply the converted
MJCF to `--scene` and the USD entrypoint to `--usd-path`; do not substitute an
unrelated G1 model without checking its link frames, inertias and joint order.

Example from the mounted repository root, inside that GPU environment:

```bash
python -m providers.motion_learning.aligned.train \
  --config examples/learning/g1-aligned-scale.json \
  --backend isaac --device cuda:0 \
  --motion-dir /data/lafan1_g1 \
  --scene /data/g1_description/g1_29dof.xml \
  --usd-path /data/g1_usd/g1_29dof/g1_29dof.usda \
  --output /results/g1-aligned-seed0 --evaluate
```

The scale profile specifies 4,096 environments, a three-layer 2,048-wide world
model, 8-step model training, 32-step imagination, 10-step policy history and
10-frame preview. Use a separately saved smaller profile when validating a
new GPU installation. Its results remain a reduced-budget run, even though
the learning equations are shared.

## Checkpoint and evaluation behavior

The physics adapter currently accepts only `physics_dt: 0.005`; a different
value is rejected rather than recorded while silently running four 5 ms steps.

Newton's internal solver state is not serialized by this adapter.
`state_dict()` marks its environment payload `exact_resume: false` and
`replay_refill_required: true`. Loading restores the adaptive sampler and
environment context, starts new physical episodes, then the trainer clears
replay/history and collects enough valid transitions before fitting the
8-step model. It never treats a nonzero saved iteration as evidence that an
empty replay buffer is usable. Checkpoints contain learner/optimizer states
and sampler state; this GPU path is a warm restart rather than an exact
physical continuation. With `context_resampling: environment`, friction and
COM remain constant per environment during a training run and survive a warm
restart, matching `smc`. With `context_resampling: episode`, each reset samples
new friction and COM values and updates those physical properties only for
the reset environments. A warm restart creates new episodes, so that mode
also resamples the saved friction/COM. Both modes resample joint calibration
in ±0.01 rad after each reset. The saved resampling mode is checked on restore;
the two protocols cannot silently share a checkpoint. Evaluation sets nominal
context and disables both resampling modes.

The trainer saves its training checkpoint before `--evaluate` changes the
environment. `for_evaluation()` disables reset noise, training timeout and
auto-reset; restores unit friction, zero torso COM perturbation and zero
joint calibration; and resets each clip to its first reference frame.
It exposes one measured slot of the already allocated GPU scene to the
sequential full-clip evaluator. All GPU slots receive the same reset and
action; only slot zero contributes metrics. The report records both
`simulated_replica_count` and `measured_replica_count`; extra replicas are
computational overhead, not extra evaluation trials.
`evaluation_simulated_physical_steps` includes their cost. A separate small
evaluation allocation is preferable for large-budget benchmarking.

## DGX Spark

DGX Spark is a feasible target for this headless backend. NVIDIA's current
Isaac Lab Release 3.0 installation guide explicitly includes Linux aarch64 /
DGX Spark and requires CUDA 13 or newer with a matching PyTorch build. The
Newton-only installation does not require Isaac Sim or RTX rendering.
[Official system requirements](https://docs.nvidia.com/isaaclab/isaac-lab/installation#system-requirements).

That current release support does not independently validate this adapter's
pinned `46d6cc3` dependency set on Spark. No dependency upgrade was made here.
The pinned environment, robot conversion, one physical rollout and one
model/actor/critic update must first run successfully on the actual Spark
before launching the scale profile. Start with a separately recorded small
environment/batch profile and measure memory and update throughput; no H100
training-time estimate is transferred to Spark.

## Validation recorded locally

Nine CPU protocol tests passed:

```bash
target/learning-venv/bin/python -m unittest \
  providers.motion_learning.aligned.test_aligned_isaac
```

They check the lazy dependency boundary, solver configuration, rejection of a
joint-order mismatch, pre-reset transition labels and truncations,
deterministic evaluation configuration with no training timeout or collection
action cap, physical context setter arguments and the explicit warm-resume /
refill / calibration-resampling contract. Their simulator objects are
test doubles. They do **not** verify Newton stepping, CUDA execution, USD
conversion, training throughput or learned tracking performance. Those remain
GPU execution checks; no GPU result is inferred from these tests.

The adapted simulator code retains the upstream MIT notice in
`providers/motion_learning/aligned/SMC_LICENSE`.
