# Complete Control-Tape And Feedback Response

Updated: 2026-10-23. All 36 planned conditions are measured and all 648 physical
archives pass independent reconstruction and the native reader. Two local
model derivative checks remain unverified; no policy is trained or adopted.

The [first-action study](G1_REFERENCE_ACTION_RESPONSE.md) found useful local
model directions, particularly at H8, despite poor agreement for complete
saved actor updates. This study crosses full H32 control-sequence directions
with execution that either holds the original control tape fixed or advances
the recorded policy's causal feedback.

## Frozen protocol

The [charter](../examples/learning/g1-reference-feedback-response.json) pins the
first-action source report at SHA-256
`88c753f4485773ab66629cc868875255a0a1cbffbbdc2e760f8135abbae88404`.
All six cycle-6 world models and all 36 solver snapshots are retained: both
replay methods, three seeds, three representative reference families and
offsets 0/50 steps. The controller is the same run's saved cycle-5 actor.

Two model gradients are computed at each state with respect to a complete
32×29 additive control sequence: one around recorded open-loop controls, one
through the modeled closed-loop actor, observation history and full EMA.
**Each frozen direction is tested under both execution modes**, both signs,
and both amplitudes, 0.0001/0.001 rad RMS over the full 928-coordinate sequence.
Every physical branch lasts 32 steps (0.64 s) or ends at a fall. All collected
records have 32 steps.

A common feasibility mask excludes coordinates within
`sqrt(32×29) × 0.001` = approximately 0.03046 rad of a limit in any of the
recorded tape, model feedback baseline or physical feedback baseline. Each
masked direction is normalized over all 928 coordinates. Actuator clipping is
identical in both simulators. In feedback execution, subsequent policy changes
can still change saturation, so nominal injected RMS need not equal realized
control RMS. These are constrained local directions, not unconstrained full
action Jacobians.

Feedback starts with the source episode's actual H10 observation history and
actual/reference balance features, including the original causal EMA at the
one-second offsets. These archived float32 tensors are promoted to float64;
model and physics receive exactly the same initial controller memory. Later
observations and memory evolve from each rollout's own states. Initial full
solver state is restored once, and never replaced by reference states again.
Reference commands/features retain the original float32 schedule promoted to
float64. This precision-defined diagnostic controller is not claimed bit-exact
to the original float32 runner.

Open-tape execution reuses the preceding study's 36 exact physical baselines;
feedback has 36 newly collected baselines. Each cell compares against its own
execution mode's baseline. The directions and subsequent unperturbed actions
differ between modes. Consequently, the crossed comparison describes response
and transfer, not a numerical causal effect size attributable solely to feedback.

## Results

Each row covers the same 36 states. “Positive gains” counts physical H32 return
improvement over that mode's unperturbed baseline. “Sign agreement” compares
model/physics symmetric finite changes. A cross-executed positive direction is
not necessarily an ascent direction for its new execution mode.

| Direction computed through | Executed with | Nominal RMS rad | Sign agreement | Positive physical gains | Mean realized control RMS / injected RMS |
| --- | --- | --- | --- | --- | --- |
| Fixed tape | Fixed tape | 0.0001 | 35/36 | 35/36 | 1.00 |
| Fixed tape | Fixed tape | 0.001 | 36/36 | 35/36 | 1.00 |
| Fixed tape | Feedback | 0.0001 | 26/36 | 33/36 | 20.44 |
| Fixed tape | Feedback | 0.001 | 29/36 | 35/36 | 5.81 |
| Feedback | Fixed tape | 0.0001 | 21/36 | 26/36 | 1.00 |
| Feedback | Fixed tape | 0.001 | 27/36 | 27/36 | 1.00 |
| Feedback | Feedback | 0.0001 | 26/36 | 26/36 | 17.92 |
| Feedback | Feedback | 0.001 | 25/36 | 26/36 | 5.17 |

Realized RMS is recomputed by MoonBit from each branch's actual applied controls
minus its matching unperturbed physical baseline, averaged over all 32 steps
and 29 joints. The table averages ratios across both signs. Maximum amplification
is 90.63× for a fixed-tape direction executed with feedback at 0.0001 rad;
feedback's own directions reach 66.48× at that amplitude. These are finite
trajectory responses, not intrinsic linear gain constants or a stability proof.

Fixed-tape directions are physically useful in 35/36 states at both amplitudes.
Feedback's own directions improve only 26/36 in its own execution mode, despite
large predicted responses. For those own-feedback cells, mean model versus
physical directional response is 75.13 versus 3.76 at 0.0001 rad, and 26.80
versus 4.57 at 0.001 rad. Fixed-tape means are 34.47 versus 16.05 and 34.30
versus 16.02. Direction quality, response magnitude and finite-difference scale
must remain separate measurements.

This supports investigating the modeled observation-feedback gradient path and
finite actor step, rather than assuming that every local dynamics action
direction is wrong. It does not identify one mechanism or establish that
removing physical feedback would improve control. The next controlled ablation
should **keep the full forward controller unchanged**, and compare actor
parameter directions with and without backpropagation through modeled
observation/EMA feedback before attempting further training.

## Model derivative checks and limits

The preliminary run stopped at a feedback direction whose central difference
at 1e-6 differed from autodiff by approximately 1.4%. Before complete collection,
the protocol was revised uniformly to retain 1e-6 and also report 1e-7/1e-8 for
every direction/execution pair. No state or physical outcome is omitted because
of a failed local model check. The incomplete `g1-reference-feedback-response`
directory is excluded; the complete source is its `-scales` directory.

Of 144 direction/execution projections, 135/140/142 pass at the three decreasing
scales. The two unverified smallest-scale projections are both FIFO own-feedback:
seed 1, high joint-sine, offset 50; and seed 2, stand, offset zero. At 1e-8,
autodiff versus finite differences are 1186.62 versus 1148.13 and 3716.35 versus
3921.12, respectively. Their large scale dependence remains unresolved; these
are not reported as verified derivatives. Physical finite-response data remain
valid, and both flagged conditions remain in the 36-condition tables.

Small-scale model autodiff agreement is distinct from physical derivative
accuracy. A smaller nominal perturbation also does not guarantee a smaller
closed-loop realized control response relative to that perturbation. No motion
generalization, complete quality gate, checkpoint selection or adoption follows
from the tables. Larger motion sources and independent evaluation remain open.

## Evidence and verification

The [verified report](../output/research/g1-reference-feedback-response.json)
contains **648 episodes /20,736 transitions**: 576 new counterfactual branches
/18,432 transitions, 36 new feedback baselines /1,152, and 36 reused open-tape
baselines /1,152. Reused baselines are not independent new collection. These
are response measurements at known states, not new source motions.

Independent export checks source and checkpoint hashes, copied full snapshots,
original causal controller memory, complete branch control laws, previous-action
history, continuity, rewards and terminal/truncation semantics. Every archive
passes native MotionDataset reading. MoonBit independently recomputes H8/H32
discounted returns, response summaries and realized control RMS ratios.
Maximum applied-action reconstruction error is 6.47e-14 rad, reward error
2.09e-17 and observation error 2.23e-15. File/data validation passing does not
turn the two failed derivative checks into passes.

The raw report SHA-256 is
`a2f5a9665311ef69e606016d04b1a79f91ab97e73dfa41b74b23083d49a71890`.
The complete numerical provider takes 129.66 s of local CPU wall time, excluding
native verification and the preliminary stopped run. Four focused numerical
tests pass for whole-tape derivatives, common feasibility masking, exact repeat
of restored physical feedback and zero-injection agreement with the training
imagination formula within its original float32 discount precision. Five native
motion-learning tests pass. `moon info` and scoped script formatting complete
without new public MoonBit interface changes; existing warnings remain.

## Reproduce

Use a fresh output directory and the frozen first-action study:

```sh
moon run --target native scripts/probe_g1_reference_feedback_response.mbtx /Users/kq/Workspace/moonrobo /Users/kq/Workspace/moonrobo/target/learning/g1-reference-action-response-interior /Users/kq/Workspace/moonrobo/target/learning/g1-reference-feedback-response-scales
moon run --target native scripts/report_g1_reference_feedback_response.mbtx /Users/kq/Workspace/moonrobo /Users/kq/Workspace/moonrobo/target/learning/g1-reference-feedback-response-scales /Users/kq/Workspace/moonrobo/output/research/g1-reference-feedback-response.json
target/learning-venv/bin/python -m unittest discover -s providers/motion_learning -p test_reference_feedback_response.py
```

The [complete phase plan](SUPERMIMIC_PHASE_PLAN.md) remains active. This local
research artifact does not change the default controller, platform registry,
hardware authority, outstanding motion-library scope or full quality criteria.

The subsequent [parameter-gradient route study](G1_REFERENCE_GRADIENT_ROUTE.md)
keeps the full forward controller exactly equal while detaching only policy
input edges during backpropagation. The surrogate improves local full-return
directions for anchor models, but not uniformly over FIFO, and every anchor
probe still falls. Its 162 paired archives validate. The next step is the
matched final-cycle training ablation and the full 27-cell evaluation.
