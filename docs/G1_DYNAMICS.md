# G1 Differentiable Dynamics Fit

Implemented: 2026-10-23. This is partial SM-3.1: exploratory MuJoCo transitions
are materialized by the MoonBit reader and used to fit a differentiable dynamics
model. It supplies inference weights, held-out prediction metrics and an
eight-step input-gradient check. The subsequent [actor/critic workflow](G1_POLICY_LEARNING.md)
now consumes these models; stable control remains outstanding.

The later [diagnostic ablations](G1_DIAGNOSTIC_ABLATIONS.md) add an optional
horizontal-translation-invariant encoding for the same flat-plane body. Its
v2 checkpoints mask absolute root X/Y from network inputs while retaining
residual position outputs. v1 checkpoints keep the original computation;
`load_model` checks the encoding/format binding. This corrects a measured model
symmetry error, not all prediction or control errors.

## Run

Use the Python environment and pinned G1 model from [CPU physics setup](G1_CPU_PHYSICS.md).
Install the updated requirements and run from the repository root:

```sh
target/learning-venv/bin/python -m pip install -r providers/motion_learning/requirements.txt
moon build --target native
moon run scripts/fit_g1_dynamics.mbtx /absolute/path/to/moonrobo /absolute/path/to/moonrobo/target/learning/g1-dynamics
```

The MoonBit script collects physics trajectories, invokes the actual
`motion_dataset` executable for each split, runs three training seeds, and
checks the saved diagnostics. Large intermediate batches and model files stay
under the chosen output directory. The script saves `fit.log`; model training
failures and a failed diagnostic exit nonzero while retaining evidence.

The numerical learning implementation is
[`dynamics.py`](../providers/motion_learning/dynamics.py). The fixed collection
and fitting configurations are
[`g1-dynamics-collection.json`](../examples/learning/g1-dynamics-collection.json)
and [`g1-dynamics-fit.json`](../examples/learning/g1-dynamics-fit.json).

## Data And Model

The collection uses 0.05 rad independent Gaussian action exploration, clipped
to actuator control ranges. Each transition retains its applied noisy input.
Standing reference families at friction 1.0, 0.8, and 0.6 belong to training;
waist sway belongs to validation and arm wave to test. Twelve collection seeds
produce 60 episodes and 3711 physical-simulator transitions. All episodes end
in falls under the simple position controller; this is fall-dynamics data, not
a library of successful skills.

The MoonBit window builder produces 1971 train, 658 validation, and 662 test
windows of length eight. It validates all source splits and keeps windows inside
episode boundaries. Related standing references remain in the same train
family, including across friction changes.

The CPU model has two 128-wide SiLU hidden layers. Inputs are the 71 simulator
state channels, 29 applied setpoints, and two context values. Its residual output
predicts the next physical state. The G1 root quaternion is explicitly normalized
in each predicted state. Loading another body's state layout is rejected.
This initial model does not learn observation, reward, or termination heads.

State, action, and context normalization use only training windows, with a 0.1
minimum channel scale. Overlapping windows weight the normalization statistics
by their occurrence in those windows. There is no fitting on validation or test
data. Each update autoregressively predicts all eight steps from the first
logged state, using the logged action sequence. The loss is the mean squared
state error divided channel-wise by the training state scale squared.

The frozen run configuration uses 400 Adam updates, batch size 64, learning rate
0.001, gradient clipping at norm 1.0, and training seeds 0, 1, 2. Validation every
50 updates selects a checkpoint. The test set is scored after that selection;
test metrics do not select parameters or checkpoints. Keep this test set out of
future hyperparameter tuning, or designate a new held-out evaluation set.

## Measured Diagnostics

The diagnostic target is to beat persistence (predicting the initial state at
every future step) on held-out normalized state MSE for every training seed.
Both methods use the same source windows and training normalization.

| Training seed | Selected update | Test eight-step mean normalized MSE | Persistence MSE |
| --- | ---: | ---: | ---: |
| 0 | 400 | 0.237499595 | 1.189369202 |
| 1 | 400 | 0.237513781 | 1.189369202 |
| 2 | 400 | 0.235124379 | 1.189369202 |

The reduction is approximately 80% on this small collection. Errors are averaged
over windows, eight steps and normalized state channels; the numbers have no
single physical unit. Overlapping windows are correlated. The three seeds share
one collection and split. This is not a motion-control success rate, a comparison
against PPO, or a claim of general robot dynamics coverage. Validation MSE is
approximately 0.053-0.054, so the higher test error also exposes distribution
shift between these procedural references.

For each model, the verification freezes model parameters and differentiates
through the full eight-step rollout with respect to initial state and applied
actions. Gradients must be finite and nonzero. A double-precision directional
finite difference independently checks the action derivative; all three probes
passed. This checks our automatic differentiation implementation, not whether
the learned Jacobians match MuJoCo or physical hardware.

## Artifacts And Next Step

`fit/report.json` includes per-step errors, persistence errors, validation
history, input batch digests, provider digest, settings, input-gradient probes
and checkpoint references. Each `dynamics-seed-N.pt` contains model weights,
training normalization, input layout, configuration and selected update.
`load_model(path)` reconstructs inference without needing the source dataset;
its predictions were verified to match the pre-save test metrics exactly on
the current CPU environment. PyTorch is pinned to 2.9.1; reproducibility across
platforms or library versions is not implied.

These are local inference checkpoints. Optimizer/replay/RNG restoration, durable
job recovery are deferred. Completed feedback runs can now register these
weights through the [MoonData experiment registry](LEARNING_EXPERIMENT_REGISTRY.md).
There is no exact
training-resume claim. Policy improvement through the frozen model and independent
MuJoCo scoring now run in the policy workflow. That workflow also adds fresh
policy data and refits this model. The failing control results and incomplete PPO
comparison remain visible in the phase plan.
