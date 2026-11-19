# G1 Model Prediction And Physical Action Sensitivities

Implemented: 2026-10-23. This measurement compares learned dynamics with MuJoCo
on the same restored integration state and open-loop action sequence. It
separates short prediction accuracy from action-gradient quality.

## Run

After the [initial dynamics fit](G1_DYNAMICS.md) and first
[policy feedback round](G1_POLICY_LEARNING.md):

```sh
moon run --target native scripts/probe_g1_model.mbtx /absolute/path/to/moonrobo /absolute/path/to/moonrobo/target/learning/g1-dynamics /absolute/path/to/moonrobo/target/learning/g1-policy-feedback /absolute/path/to/moonrobo/target/learning/g1-policy-feedback /absolute/path/to/moonrobo/target/learning/g1-physical-probe
```

Arguments identify the repository, initial dynamics run, corrected dynamics run,
policy run and output directory. The script tests reference-position control
and the first policy round's latest seed-zero actor. Implementation is in
[`model_probe.py`](../providers/motion_learning/model_probe.py), using the fixed
[`probe configuration`](../examples/learning/g1-model-probe.json).

## Measurement

Integration states are captured at control steps 0, 20 and 40 in three procedural
cases, using seed zero. Each experiment restores MuJoCo's full
`mjSTATE_INTEGRATION`, including solver warm-start state. Replaying recorded
controls must match the original trajectory within 1e-8; the measured maximum
difference was zero. Model and physics use the same actuator clipping.

Horizons are 1, 8 and 32 steps. Windows extending beyond the source episode are
omitted: the measured 1/8-step sets have nine snapshots each; the 32-step set has
six. Both models' normalized errors use the initial model's training scale.

The return uses actor training's tracking, balance, height and smoothness terms,
discount 0.99 and soft survival. It excludes critic bootstrap and holds recorded
actions fixed. It probes action sensitivities of the model component, not the
complete closed-loop policy-parameter gradient.

Four seeded random directions per snapshot have unit L2 norm over the whole
action sequence. MuJoCo central differences use sequence-norm perturbations of
0.001 and 0.01 rad. Learned derivatives use automatic differentiation. Both
numerical estimates and every model derivative are retained without filtering.

## Measured Findings

On the first learned policy's actual trajectories:

| Horizon | Snapshots | Initial model MSE | Corrected model MSE | Initial / corrected directional sign agreement at 0.001 rad |
| --- | ---: | ---: | ---: | ---: |
| 1 | 9 | 0.068026 | 0.007891 | 69.4% / 75.0% |
| 8 | 9 | 0.139729 | 0.014727 | 61.1% / 72.2% |
| 32 | 6 | 1.313138 | 0.041165 | 54.2% / 62.5% |

Policy-data correction substantially improves prediction on that policy's states.
This supports continuing collection/model/policy feedback; it does not establish
that action gradients are sufficiently accurate for control.

The two MuJoCo perturbation sizes agree in sign on 91.7%, 83.3% and 66.7% of
their respective direction sets. Contacts and finite perturbations make these
derivatives scale-dependent. The corrected model's 32-step sign agreement is
70.8% at the larger perturbation. Read raw directions and denominators before
drawing a gradient-quality conclusion.

On nominal position-reference trajectories, initial/corrected 32-step MSE is
0.031514/0.028510. The much larger initial error on learned-policy trajectories
therefore exposes a coverage issue hidden by the original prediction diagnostic.
These are small development probes, not generalization or robot-release tests.

## Outputs

`position-report.json` and `policy-report.json` preserve per-case returns,
common-scale errors, both finite differences, model derivatives, counts,
configuration, checkpoint digests and runtime versions. Verification checks
replay fidelity and nonempty measurements; a direction-agreement percentage
does not grant deployment qualification. For current simulator control results,
see the policy-learning guide. Stable balance remains open.

The subsequent [failure-tail/ablation study](G1_DIAGNOSTIC_ABLATIONS.md) probes
1.0–2.2 s starts, records unavailable windows, and tests actual physical return
changes along model gradients. It also measures horizontal-translation symmetry,
introduces an explicitly encoded invariant model, and checks policy outcomes.
