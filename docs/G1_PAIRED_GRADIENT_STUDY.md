# G1 Paired Model And Critic-Tail Directions

Updated: 2026-10-23. This follows [short-cycle adaptation](G1_SHORT_CYCLE_STUDY.md).
A selected model can improve short-window prediction while giving harmful
actor directions. Removing the critic tail improves one seed's local physical
direction, but a subsequent six-run training comparison selects no new actor.
Stable control remains unfinished.

## Same Actors, Critics And Restored Origins

The [probe](../providers/motion_learning/paired_model_probe.py) holds each
selected `cycle-adaptive` actor/critic fixed while comparing the shared initial
world model against that actor's paired selected adapted model. The adapted
file digest must match the actor checkpoint's recorded pairing. This compares
the models on identical actors, critics, replay samples and physical states;
it does not compare different controllers' trajectories as if they were paired.

The [frozen configuration](../examples/learning/g1-paired-model-probe.json)
uses six constant-goal training cases, reset seeds 1950/1951 and requested
origins at 0/0.5/1/1.5/2 seconds. There are 36 parent episodes and 159 available
origins: 53/54/52 by policy seed. The other 21 requested origins do not exist
because the parent ended. These correlated states are not 159 independent
reset trials. Validation/test reference families are excluded.

A fixed 64-window uniform replay batch per seed produces one fresh Adam step,
learning rate 0.0003, with the training loss divisor and gradient clipping.
Each model generates two parameter deltas: terminal actor critic bootstrap on
or off. This changes only its actor-objective contribution. The physical
window score always uses the same saved critic for comparison. The probe does
not reproduce the optimizer state or random minibatch of a prior training step.

Multipliers -1/-0.1/-0.01/0/0.01/0.1/1 apply each saved parameter delta.
For every candidate, full MuJoCo integration state, previous applied action,
friction and constant goal are restored. The unchanged closed-loop actor
reproduces the original 32-step-or-shorter recorded window exactly: maximum
state/action restoration error zero. The probe reports three separate scores:

- Actual 32-step-window discounted reward, with analytic soft continuation.
- That physical window plus the same learned critic's boundary value.
- Actual reward until physical fall or 500 steps from the origin, with no
  critic tail. Every baseline and perturbation in this run ends in a fall,
  so none of these full-rollout returns is cut off by the ten-second cap.

The last score exposes effects beyond the 0.64-second window; it remains
the existing discounted soft-continuation reward, not an undiscounted survival
metric. Model predictions use those same physical origins even though the
direction is fitted on replay. All parameter deltas, integration origins,
omissions and individual outcomes remain in the local run.

## Window Improvement Can Conceal Full-Return Loss

At full positive step size, actual changes for the adapted models are:

| Seed / direction tail | Predicted window + critic change | Physical window reward change | Physical full-return change | Origins improving full return |
| --- | ---: | ---: | ---: | ---: |
| 0 / on | +4.2346 | +0.6393 | -1.8777 | 33 / 53 |
| 0 / off | +4.7027 | +0.7972 | -2.0486 | 33 / 53 |
| 1 / on | -1.2780 | +0.1461 | -2.5072 | 16 / 54 |
| 1 / off | +0.8250 | +0.0541 | -1.1852 | 27 / 54 |
| 2 / on | +0.6300 | -0.3035 | -1.3227 | 13 / 52 |
| 2 / off | +0.0155 | +0.5291 | +2.3355 | 40 / 52 |

Seed one's negative predicted recent objective change with the tail is scored
on physical origins, a different distribution from the replay batch used to
fit that direction.
For seed zero, most origins improve full reward while its mean falls: a
favorable fraction is not evidence of a favorable average or all-state gain.

Seed two's adapted model with critic bootstrap gives the clearest mismatch:
predicted recent bootstrapped objective improves, while physical window and
full return worsen. Its initial-model direction with the same actor/critic
instead gains full return by +0.6818. Removing the tail from the adapted-model
direction gains +2.3355 and about 1.40 remaining physics steps on average,
but all 52 perturbed full rollouts still fall.

The [centered report](../output/research/g1-paired-model-centered.json) computes
`(score(+s) - score(-s))/(2*s)` for s=0.01/0.1/1. These are directional finite
differences along the saved Adam parameter delta, not a complete physical
gradient; s is not an action angle. For adapted seed two, full-return slopes
are negative at all three scales with the tail (-8.1974/-1.4469/-0.8950),
positive without it (+11.7145/+3.7659/+2.7867). The same critic-bootstrapped
physical window score without a direction tail is negative at the smallest
scale despite that positive full-return slope. Boundary estimates are therefore
not interchangeable with measured continuation.

Scale dependence remains elsewhere: seed zero has a positive centered
full-return slope at s=0.1 with the tail, despite a negative full positive
step. Initial-model seed two's full-return slope changes sign between s=0.01
and 0.1. No globally smooth or universally correct gradient is established.
The [summary](../output/research/g1-paired-model-probe-summary.json) retains
all 84 model/tail/scale rows and all artifact bindings.

## Training Test Of The Local Observation

The follow-up freezes each selected adaptive actor/critic/model triple and
compares `paired-tail-on` against `paired-tail-off`. Only the terminal critic
contribution to actor optimization differs. There are 200 actor updates per
seed with the same replay, batch 64, learning rate 0.0003 and 32-step horizon.
The new optional `critic_training_source: "frozen"` fits neither critic nor
world model and performs no extra physical training collection. Actual checks
confirm that both networks' weights remain unchanged throughout training;
the actor still differentiates through them. Existing imagined-GAE and
physics-return modes retain their update paths.

Each seed runs against its own paired world model. The aggregate policy
report records initial model digests by seed rather than claiming a shared
model digest. Per-seed trainer reports retain their provider digest locally.
The inherited dynamics report describes the incoming fit; it does not claim
new model fitting. Selected and latest incoming model weights remain sealed.

Validation seeds 30–32 select at updates 0/1/5/10/20/50/100/150/200. Every one
of the six runs selects update zero. Fresh final seeds 8200–8202 are unused
for selection; both methods therefore evaluate the same incoming actors:

| Seed | Mean survival (s) | Joint RMSE (rad) | Falls / trials |
| --- | ---: | ---: | ---: |
| 0 | 2.3800 | 0.15142 | 9 / 9 |
| 1 | 2.4400 | 0.09434 | 9 / 9 |
| 2 | 2.2200 | 0.17539 | 9 / 9 |

Independent incoming re-scoring reproduces the selected trajectories exactly.
These are three unchanged controllers evaluated twice, not six independently
learned successes. None reaches the existing gate of zero falls in nine
ten-second trials and mean RMSE at most 0.15 rad. The [training report](../output/research/g1-paired-tail-study.json)
retains all validation checkpoints and actual fresh outcomes. This experiment
does not justify changing the default actor objective or attributing the
entire failure to the critic boundary. A local training-state improvement has
not transferred into sustained validation control.

## Reproduction And Platform Evidence

```sh
moon run scripts/probe_g1_paired_model.mbtx /absolute/path/to/moonrobo /absolute/path/to/moonrobo/target/learning/g1-counterfactual-study/augmented /absolute/path/to/moonrobo/target/learning/g1-short-cycle-study/cycle-adaptive /absolute/path/to/moonrobo/target/learning/g1-paired-model-probe /absolute/path/to/moonrobo/output/research/g1-paired-model-probe-summary.json
moon run scripts/score_g1_paired_model.mbtx /absolute/path/to/moonrobo/output/research/g1-paired-model-probe-summary.json /absolute/path/to/moonrobo/output/research/g1-paired-model-centered.json
moon run scripts/fit_g1_paired_tail.mbtx /absolute/path/to/moonrobo /absolute/path/to/moonrobo/target/learning/g1-counterfactual-study/augmented /absolute/path/to/moonrobo/target/learning/g1-short-cycle-study/cycle-adaptive /absolute/path/to/moonrobo/target/learning/g1-paired-tail-study
moon run scripts/score_g1_paired_tail.mbtx /absolute/path/to/moonrobo /absolute/path/to/moonrobo/target/learning/g1-paired-tail-study /absolute/path/to/moonrobo/target/learning/g1-short-cycle-study/cycle-adaptive /absolute/path/to/moonrobo/target/learning/experiment-book/moondata /absolute/path/to/moonrobo/output/research/g1-paired-tail-study.json
```

Both training IDs above use the existing MoonData experiment import and
read-only cockpit, preserving selected/latest actors, paired model weights,
incoming dataset, reports and failures. The physical direction probe remains
a separate local research artifact with training-batch/checkpoint digests; no new
registry type, job service or UI flow is added. All physical execution flags
remain false. Nineteen numerical tests pass, including a synthetic example
whose actor direction reverses when the critic boundary is removed and whose
window/tail prediction decomposition stays separate.
All 885 native tests pass. Both imported experiments pass complete MoonData
validation with zero findings; checksums bind each frozen model to its per-seed
trainer report. No public MoonBit API changes are introduced.

The [teacher-initialization study](G1_TEACHER_INITIALIZATION.md) now adds
sustained successful physical trajectories: a handcrafted teacher completes
9/9 canonical ten-second trials, and student-state labeling improves the best
learned actor to six ten-second completions in nine trials. That actor still
fails every wave case. Successful-state coverage is therefore productive local
progress, without establishing it as the sole cause or a completed solution.
Matched efficiency, the wider learning/workbench gates and E1 qualification
remain open. General deployment hardening remains deferred.
