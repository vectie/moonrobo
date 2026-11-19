# Actor Parameter Directions With Unchanged Forward Feedback

Updated: 2026-10-23. Status: all twelve direction cells and 162 paired physical
archives independently verified. This is a parameter-direction experiment,
not a newly trained or qualified policy.

The [control-tape/feedback study](G1_REFERENCE_FEEDBACK_RESPONSE.md) finds useful
open-loop action directions but substantial feedback amplification. Its two
execution modes have different forward trajectories. This study makes the
more controlled comparison: keep the complete forward controller unchanged
and change only one backward edge into the policy.

## Frozen comparison

The [charter](../examples/learning/g1-reference-gradient-route.json) binds the
six-cycle learning source, the cycle-5 physical baselines and the preceding
feedback diagnostic. Both FIFO and initial-anchor models, all three seeds,
and all prescribed signs and amplitudes are retained.

For each saved cycle-5 actor and its frozen cycle-6 world model:

- Restore the actual cycle-6 collection over all nine references and all three
  origins. Sample 256 current physical transitions with seed `44100 + seed`,
  retaining complete causal history, EMA, phase and remaining duration. A second
  256-transition batch with seed `44200 + seed` is used only for calibration.
- Compute an H32 no-tail actor gradient through the full modeled controller.
  Compute a second direction with history and actual balance features detached
  **only at the actor input edge**. Both routes retain plant-state BPTT, direct
  actor parameter dependence, the actual forward history/EMA evolution, and the
  previous-action reward derivative. No physical feedback is disabled.
- Require exactly equal forward objective values and active imagined-step
  counts at the same base weights. This holds in all six pairs. Normalize each
  raw parameter direction to unit L2; no Adam step or momentum is used here.
- Calibrate each sign on the fixed calibration inputs to raw latent-mean
  **logit RMS 0.001 or 0.005**, within 0.1% relative tolerance. These are
  dimensionless policy-output changes, not the radian action-tape amplitudes
  in the previous study. Calibration observes no physical return.
- Run each perturbed actor in actual CPU MuJoCo on normal-friction stand,
  pose-offset and high joint-sine references from origin zero, requesting the
  full thirty seconds. Reuse the eighteen original cycle-5 baselines. Both
  signs, both amplitudes and every failure remain in the report.

The stopped-input direction is a **surrogate/semi-gradient**, not the true
derivative of the unchanged closed-loop scalar. Full-objective and surrogate
gradient projections are therefore recorded separately. Agreement between its
own projection and a finite difference of the full controller is not asserted.
This changes an actor parameter vector, unlike the earlier independent action
injections, but does not reproduce the original Adam update or its moments.

## Results

Each positive-direction row below combines three seeds times three known
reference cases: nine trials, not nine new source motions. Return change is
relative to that same seed's cycle-5 baseline, discounted with gamma 0.99 through
the actual episode. It is not a fixed-duration counterfactual after a fall.
All negative-direction results are retained in the verified report.

| Model replay | Gradient route | Logit RMS | Full-return gains /9 | Mean full-return change | Mean survival s | Falls /9 |
| --- | --- | --- | --- | --- | --- | --- |
| FIFO | Full | 0.001 | 8 | +0.19304 | 11.564 | 8 |
| FIFO | Stop policy inputs | 0.001 | 8 | +0.05427 | 10.744 | 8 |
| FIFO | Full | 0.005 | 9 | +0.41585 | 12.158 | 8 |
| FIFO | Stop policy inputs | 0.005 | 9 | +0.38124 | 11.889 | 8 |
| Initial anchor | Full | 0.001 | 5 | −0.00921 | 7.980 | 9 |
| Initial anchor | Stop policy inputs | 0.001 | 8 | +0.02161 | 8.060 | 9 |
| Initial anchor | Full | 0.005 | 3 | −0.02200 | 7.753 | 9 |
| Initial anchor | Stop policy inputs | 0.005 | 9 | +0.13270 | 8.069 | 9 |

Within the anchor models, the stopped-input positive direction improves mean
full return in all three seeds at both amplitudes. At 0.005, per-seed mean
changes are +0.07742/+0.12427/+0.19642, versus
−0.01672/−0.00448/−0.04480 for full gradients. All anchor trials still fall.
For FIFO, full gradients have larger pooled mean full-return gains at both
amplitudes; the stopped-input route is not a uniformly better recipe.

Short-horizon reward and full return also differ. At 0.005, anchor stopped-input
directions improve the actual H32 prefix in 7/9 trials and full return in 9/9,
while full directions improve 3/9 in each. Negative directions mostly lose
full return, but anchor full-gradient negative steps can improve the pooled
full return slightly; the complete evidence is not reduced to a selected sign.

The forward-equal gradient cosine similarities show substantial route changes:

| Model replay | Seed 0 | Seed 1 | Seed 2 |
| --- | --- | --- | --- |
| FIFO | 0.96305 | 0.33248 | −0.08981 |
| Initial anchor | −0.26566 | 0.20859 | 0.11592 |

An opposite or weakly aligned semi-gradient is expected to differ from the full
controller derivative; that alone is not an autodiff failure. The physical
results support a controlled training comparison, not adoption of the surrogate.
The cohort contains only three known origin-zero conditions. It does not test
the complete 27-cell quality gate, unseen motions, or sustained improvement over
multiple updates. Neither higher return nor the one surviving FIFO condition
establishes quality qualification.

## Next learning experiment

Test the route change in the actual final training cycle with the original
12 updates, origin sampler and 0.005 local logit cap. Reuse the same saved
world models and physical batches. Reconstruct the actor optimizer operations
through cycle 5, checking saved actor weights at every cycle, then fork only
the cycle-6 backward route with identical sampler/optimizer starting state.
First verify that replaying the full route reproduces the original final actor.
Original optimizer snapshots are unavailable, so reconstruction must not be
described as independently verified exact restart state.

Retain both replay methods and all seeds, and evaluate the complete unchanged
27-cell suite. No new model/value fit is needed to isolate the actor-route
intervention; neither no-tail objective calls its value model. This moves from
local directions to a measured learning result without adding an unrelated
scheduler, storage migration or recovery framework. Broader motion acquisition
and independent evaluation remain required parts of the full plan.

## Evidence and implementation

The [verified report](../output/research/g1-reference-gradient-route.json)
contains **162 episodes /74,888 transitions**: 144 new /66,642 and eighteen
reused cycle-5 baselines /8,246. Original source controls are not new fitting
labels. Source files, direction vectors, base checkpoints and coefficients
remain bound to their digests and actor parameter order.

Independent reloads reconstruct each perturbed actor from its frozen base and
direction, then check causal features, means, applied actions, noise law,
rewards, fall semantics and quality reconstruction. All archives pass native
MotionDataset reading. MoonBit recomputes prefix/full returns, checks calibration,
and verifies paired forward values, active counts and both origin batches.
Maximum feature error is 1.61e-6, mean-logit error 2.98e-7, control error
0.00001419 rad and quality reconstruction difference 4.77e-9. Reward
reconstruction is exact. Arrays remain float32; original quality scalars are
from float64 physics.

The raw report SHA-256 is
`6d0f191b85bef8963ceaa88e64b156f47dbf876d6d70fcffa0617a83d8e856e4`.
Numerical provider wall time is 238.80 s on local CPU, excluding native
verification and inherited data/model learning. No cost-to-target or GPU-hours
claim follows.

`imagined_objective` adds the optional `actor_feedback_gradient` route; its
default remains `full`. The physical controller is unchanged. The existing
numeric exporter now reconstructs parameter-direction behavior and caches
distinct coefficients separately. Eleven focused learning tests and four
feedback-response tests pass, including forward equality, blocked feature
gradients with retained plant/parameter gradients, and exact parameter-probe
reload. Five native motion-learning tests pass. `moon info` and scoped script
formatting complete without new public MoonBit interface changes.

## Reproduce

Use a fresh output directory and the frozen feedback study:

```sh
moon run --target native scripts/probe_g1_reference_gradient_route.mbtx /Users/kq/Workspace/moonrobo /Users/kq/Workspace/moonrobo/target/learning/g1-reference-feedback-response-scales /Users/kq/Workspace/moonrobo/target/learning/g1-reference-gradient-route
moon run --target native scripts/report_g1_reference_gradient_route.mbtx /Users/kq/Workspace/moonrobo /Users/kq/Workspace/moonrobo/target/learning/g1-reference-gradient-route /Users/kq/Workspace/moonrobo/output/research/g1-reference-gradient-route.json
target/learning-venv/bin/python -m unittest discover -s providers/motion_learning -p test_reference_learning.py
```

This local research artifact does not replace registered results or grant a
policy/hardware release. The complete [phase plan](SUPERMIMIC_PHASE_PLAN.md)
remains active.
