# Local Physical Action-Response Measurement

Updated: 2026-10-23. Status: all 36 planned states measured and all 324
baseline/branch archives independently verified. Existing policies remain unchanged.

The [last-cycle comparison](G1_REFERENCE_LAST_CYCLE.md) found H32 model/physics
return-change sign agreement in only 8/18 complete saved policy updates. This
study isolates a smaller, directly measurable question: does the model's
gradient for **one first position setpoint**, with later controls fixed, improve
the same finite-horizon return in restored physics?

## Frozen protocol

The [charter](../examples/learning/g1-reference-action-response.json) pins the
last-cycle source report at SHA-256
`3dfd575b497e9def98807c0a4543a3c8baaea5725a2f133b93dc452435466405`.
All six cycle-6 models are used: two replay methods times three training seeds.
Each receives its own saved cycle-5 actor's actual controls on normal-friction
stand, pose-offset and high joint-sine references. States at 0 and 50 control
steps (0 and 1 s) give **36 conditions**. None is missing.

The original controls are replayed from the unchanged reference integration
snapshot. All 1,476 source transitions needed to reach and check these windows
match the source float32 state arrays exactly. Full `mjSTATE_INTEGRATION`,
including solver warm starts, is captured at each state; branch restoration
does not approximate a solver state with qpos/qvel alone. Unperturbed branches
again match the original float32 next-state windows exactly.

At each state, the H8 and H32 return gradients are computed with respect to
the first setpoint's 29 joint coordinates. Each gradient direction has unit
joint RMS. Both signs are physically tested at **0.0001 and 0.001 rad RMS**;
all subsequent recorded controls stay fixed. Every branch lasts 32 steps
(0.64 s), or ends at a physical fall, and its H8/H32 rewards are kept separately.
All measured branches complete 32 steps. There is no critic tail.

The preliminary collection stopped when its model finite-difference check
encountered a saturated actuator coordinate: a symmetric clipped perturbation
does not have the unconstrained derivative at that boundary. Before the complete
collection, a uniform feasibility rule was added: zero gradient coordinates
within `sqrt(29) * 0.001` = 0.005385 rad of either actuator limit, then normalize.
This guarantees both tested signs and amplitudes remain interior on every
changed coordinate. Seeds, states, horizons and amplitudes are unchanged.
The two incomplete directories (`g1-reference-action-response` and its `-r1`
diagnostic retry) are not included in the final dataset or results. The complete
study is `target/learning/g1-reference-action-response-interior`.

Frozen learned tensors and float32 reference reward targets are promoted to
float64 for differentiation and reward evaluation. Physics arrays are retained
in float64. Reward form and gamma 0.99 are unchanged, but accumulation is not
claimed bit-identical to the original float32 training reward. This is an
open-loop finite action-response diagnostic, not a full policy parameter
gradient, an exact simulator Jacobian, or an unseen-motion test.

## Results

Each row covers the same 36 states. Direction agreement compares the signs of
the model and physical symmetric finite differences. Positive gain means the
positive model direction beats the unperturbed physical baseline at that row's
matching horizon. These are different measurements.

| Horizon | Joint RMS amplitude, rad | Direction sign agreement | Positive direction improves physics | Mean model directional response | Mean physical directional response |
| --- | --- | --- | --- | --- | --- |
| H8, 0.16 s | 0.0001 | 36/36 | 36/36 | 0.69750 | 0.64308 |
| H8, 0.16 s | 0.001 | 36/36 | 36/36 | 0.69747 | 0.60904 |
| H32, 0.64 s | 0.0001 | 29/36 | 27/36 | 2.03491 | 0.82437 |
| H32, 0.64 s | 0.001 | 34/36 | 32/36 | 2.03454 | 0.72278 |

Directional responses are change in discounted return per rad of the signed
RMS amplitude parameter along each condition's own model-selected direction.
They are not the same direction across states or horizons. Both amplitudes are
reported; the larger-amplitude H32 result is not selected as an adopted setting.
The physical response changes with finite-difference scale, so these numbers
must not be presented as a converged infinitesimal physical derivative.

H8 local directions work consistently in this measured slice. H32 has useful
directions in most states, but the mean predicted response is substantially
larger than the physical response and some positive branches lose return.
This narrows the interpretation of the earlier 8/18 policy-update result:
the evidence does not support treating the whole world model as having uniformly
wrong local action directions. A saved actor update changes many future actions
and controller feedback, unlike this first-control experiment. It can also
move through model errors and contact changes over a finite parameter step.

The next controlled comparison should measure perturbations of the complete
multi-step control tape and then closed-loop feedback, retaining the same
states and frozen models. These results alone do not identify one cause, justify
a new model loss, select another checkpoint or qualify the complete policy.
Large motion sources, unseen-motion evaluation, the full workbench and E1
qualification remain required by the original plan.

## Data and verification

The [verified report](../output/research/g1-reference-action-response.json)
contains **324 episodes /10,368 transitions**: **288 new counterfactual branches
/9,216 transitions**, plus **36 baseline replays /1,152 transitions**. Baseline
replays and source-control reconstruction are not counted as new independent
collection. This adds action-response data at known states, not new motions.

All 72 model directions pass float64 central finite-difference checks at
epsilon 1e-6; maximum absolute error is 4.67e-9. This establishes model autodiff
consistency separately from the physical agreement measurements above.
Independent export reconstructs the one-control perturbation, fixed remaining
controls, state continuity, previous-action observation history, reward and fall
semantics. MoonBit recomputes discounted returns and every archive passes its
native MotionDataset reader. Maximum reward reconstruction error is 2.09e-17;
observation reconstruction error is 2.23e-15.

The raw report SHA-256 is
`88c753f4485773ab66629cc868875255a0a1cbffbbdc2e760f8135abbae88404`.
The complete provider takes 36.53 s of local CPU wall time, excluding native
verification and the two stopped preliminary runs. This is not GPU-hours or
a successful cost-to-target measurement. Four focused numerical tests pass for
first-control isolation/clipping, feasible directions, deterministic full-solver
restoration and model action-gradient finite differences.
All five native motion-learning tests pass. `moon info` and scoped script
formatting complete with no new public MoonBit interface changes; existing
toolchain warnings remain.

## Reproduce

Use a fresh output directory and the existing frozen last-cycle source:

```sh
moon run --target native scripts/probe_g1_reference_action_response.mbtx /Users/kq/Workspace/moonrobo /Users/kq/Workspace/moonrobo/target/learning/g1-reference-last-cycle /Users/kq/Workspace/moonrobo/target/learning/g1-reference-action-response-interior
moon run --target native scripts/report_g1_reference_action_response.mbtx /Users/kq/Workspace/moonrobo /Users/kq/Workspace/moonrobo/target/learning/g1-reference-action-response-interior /Users/kq/Workspace/moonrobo/output/research/g1-reference-action-response.json
target/learning-venv/bin/python -m unittest discover -s providers/motion_learning -p test_reference_action_response.py
```

This remains a local research artifact, without new platform registration or
physical execution authority. The full [phase plan](SUPERMIMIC_PHASE_PLAN.md)
remains active.

The subsequent [whole-tape/feedback comparison](G1_REFERENCE_FEEDBACK_RESPONSE.md)
now crosses both direction sources under both execution modes at the same 36
states. It finds substantial feedback amplification and weaker own-feedback
directions, while retaining two unverified small-scale derivative checks. The
next ablation should keep forward control fixed and test the backward feedback
path; these results do not justify removing the physical controller's feedback.
