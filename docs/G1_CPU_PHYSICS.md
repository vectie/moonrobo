# G1 CPU Physics Collection And Evaluation

Implemented: 2026-10-23. This is partial SM-2 development: a real MuJoCo
floating-base G1 produces numeric transitions consumed by the SM-1 reader.
It includes a repeatable scoring harness and traces. A [PPO baseline](G1_PPO_BASELINE.md)
now trains directly in MuJoCo and is scored alongside model-based policies.
A stable balance controller and paper-level efficiency comparisons remain
outstanding. The subsequent [dynamics fit](G1_DYNAMICS.md) adds exploratory
collection and a trainable state predictor; it does not change these control
baseline results.

Completed feedback runs now register their datasets and physics reports through
the [MoonData experiment registry](LEARNING_EXPERIMENT_REGISTRY.md).

## Inputs And Implementation Route

The numerical runtime is our independent implementation in
[`cpu_physics.py`](../providers/motion_learning/cpu_physics.py). It uses official
[MuJoCo Python bindings](https://mujoco.readthedocs.io/en/stable/python.html).
Job invocation and cross-language verification use the MoonBit
[`verify_g1_physics.mbtx`](../scripts/verify_g1_physics.mbtx) script.

The G1 model comes from [MuJoCo Menagerie](https://github.com/google-deepmind/mujoco_menagerie/tree/main/unitree_g1),
revision `cda5236f98383f6fbaa4820c6b18dba892cd087f`, using
`unitree_g1/scene_mjx.xml`. Its [README](https://github.com/google-deepmind/mujoco_menagerie/blob/cda5236f98383f6fbaa4820c6b18dba892cd087f/unitree_g1/README.md)
identifies the Unitree-derived model and BSD-3-Clause license. Keep the upstream
license alongside the model checkout. Assets are fetched into ignored `target/`;
no SuperMimic Demo assets are used.

References are original procedural standing, waist sway, and arm-wave commands,
not human motion capture. Distinct reference families are assigned to train,
validation, and test. This small split exercises the data path and does not
establish broad motion generalization. NumPy and MuJoCo versions are pinned in
[`requirements.txt`](../providers/motion_learning/requirements.txt).

## Setup And Run

From the repository root, using Python 3.12 (replace `python3.12` below with
the path to that interpreter if it is not on PATH; the verified environment
uses Codex's bundled Python 3.12):

```sh
python3.12 -m venv target/learning-venv
target/learning-venv/bin/python -m pip install -r providers/motion_learning/requirements.txt
git clone --depth 1 --filter=blob:none --sparse https://github.com/google-deepmind/mujoco_menagerie.git target/mujoco_menagerie
git -C target/mujoco_menagerie fetch --depth 1 origin cda5236f98383f6fbaa4820c6b18dba892cd087f
git -C target/mujoco_menagerie checkout --detach cda5236f98383f6fbaa4820c6b18dba892cd087f
git -C target/mujoco_menagerie sparse-checkout set unitree_g1
moon build --target native
```

Run a single experiment, without a viewer or GPU:

```sh
target/learning-venv/bin/python providers/motion_learning/cpu_physics.py --scene target/mujoco_menagerie/unitree_g1/scene_mjx.xml --experiment examples/learning/g1-cpu-experiment.json --output target/learning/g1-cpu
moon run cmd/motion_dataset --target native -- target/learning/g1-cpu/dataset.json train 8
```

Run the end-to-end verification using absolute source and output directories:

```sh
moon run scripts/verify_g1_physics.mbtx /absolute/path/to/moonrobo /absolute/path/to/moonrobo/target/learning/g1-verification
```

The script runs the experiment twice, compares the exact transition payloads,
checks state continuity and report/episode bindings, reads all three splits
through the actual MoonBit executable, and exercises both time-limit truncation
and noisy-action collection. Repeatability is checked on the current environment,
not promised across library versions or machines.

## Transition Semantics

The scene has 29 scalar joint position actuators, a floating root, and 71 state
channels (`qpos`, `qvel`, activation if present). The observation has 93 channels:
absolute joint positions, joint velocities, projected gravity in the root frame,
root angular velocity, and previous actuator setpoints. This initial observation
layout is not the paper's normalized history encoder.

Each 20 ms control interval consists of an integer number of physics steps.
State is copied before action and after stepping; observation and goal belong
to the interval start. The action is the actual setpoint after exploration noise
and actuator control-range clipping. The next observation carries that applied
setpoint as previous action. No interpolation or invented feedback is used.

Context contains sliding friction and whether actuation is enabled. Friction is
set on geometry and explicit contact pairs because the latter override geometry
values in this scene. The `unpowered` control disables actuation; a zero setpoint
on an enabled position servo would still exert force and is a different test.

Use `action_noise_std_rad` for dynamics collection; zero is used by the checked-in
evaluation configuration. Noise is seeded per trial and is recorded in the
applied input. The configuration also freezes reference cases, seeds, duration,
cadence, friction, and the root-height/upright termination thresholds.

## Outputs And Metrics

`dataset.json` uses `moonrobo.motion-dataset.v1`; `report.json` contains simulator
and provider versions/digests, configuration, summaries, and per-trial replay.
Scene hashes cover the entry XML only; the declared upstream revision identifies
the remaining assets and is not an authenticated seal of an arbitrary local
checkout. The provider does not register these files as MoonData artifacts yet.

Replay contains full `qpos`, reference joint targets, time, root height, upright
direction, and contact count. It is numeric inspection data, not yet a Rabbita
viewport import. Each trial links directly to its episode ID.

Joint RMSE uses post-step joint positions against the interval's reference
target. Pooled RMSE weights squared per-trial RMSE by observed step count.
Different fall times mean different observation spans, so RMSE alone must not
rank control quality. Falls and completed duration are reported alongside it.
Reward is `exp(-joint_MSE / 0.09)`; it is a plumbing objective, not the paper's
whole-body tracking reward. Root height below 0.35 m or upright Z below 0.5
terminates the episode; reaching the configured duration truncates it instead.

## Measured Result

Verified on ARM64 CPU with MuJoCo 3.3.7 and NumPy 2.5.4, three references and
three seeds, up to two simulated seconds per trial:

| Controller | Trials | Falls | Recorded control steps | Pooled joint RMSE (rad) |
| --- | ---: | ---: | ---: | ---: |
| Position setpoints | 9 | 9 | 560 | 0.0971122364 |
| Actuation disabled | 9 | 9 | 162 | 0.3809285075 |

The actual MoonBit reader accepted 198 train, 198 validation, and 200 test
eight-step windows. Repeated datasets were byte-identical. The one-step test
produced time-limit truncations; exploratory collection preserved noisy applied
actions. Full reports and traces are generated under
`target/learning/g1-verification/` rather than checked into source control.

Both simple controls fail the balance task. The experiment verifies physics
sampling, scoring, and data integration; it does not pass SM-2's learned-policy
baseline gate. Next work is an exploratory transition collection for world-model
fitting and the CPU training/evaluation adapter, now implemented as the separate
dynamics slice. Policy optimization and independent control evaluation follow.
Keep all failed trials visible.
