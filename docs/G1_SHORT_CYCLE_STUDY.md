# G1 Short Model/Policy Alternation

Updated: 2026-10-23. This follows the [actor-update study](G1_ACTOR_UPDATE_STUDY.md).
Online physical recollection and world-model correction now run between short
actor segments. One seed gains survival with worse tracking; every final trial
still falls. This implements another part of SM-3's learning loop without
satisfying its stable-control gate.

## Frozen Comparison

Both cells start from the three selected `actor-lr-standard` actors/critics,
the augmented counterfactual replay and its invariant world-model seed zero.
The initial actor/critic weights are identical across cells; optimizers restart.
Actors use 200 updates, batch 64, learning rate 0.0003, 32 imagined steps and
the same reward, bounded residual and terminal critic bootstrap as before.
Actor starting states continue to come from the initial replay: the earlier
direction probe did not establish an advantage for recent-state actor sampling.

Both methods collect six constant-goal training cases before actor updates
1/6/11/…/196. Each collection runs to a true fall or ten-second limit, with no
added action noise. Reset seeds are `1600 + 10000 * policy_seed + refresh_index`.
Critics fit physical-return labels for 40 steps per refresh, batch 512: 40
refreshes and 1600 critic optimizer steps per seed. Reference-family ownership,
fall termination and time-limit tail handling remain unchanged.

- `cycle-fixed` keeps world-model weights fixed throughout training.
- `cycle-adaptive` also performs 20 world-model Adam updates per refresh,
  learning rate 0.0003: 800 updates per seed. Each batch contains 32 uniform
  initial-replay windows and 32 recent physical windows. Recent replay retains
  at most 8192 complete eight-step windows and never crosses an episode,
  timing gap or preceding termination/truncation.

The adaptive model is cloned separately for each policy seed. Its input/output
normalization remains exactly the initial training normalization, enabling
comparison on a common scale. Model minibatch sampling uses its own seeded
generator, so extra model fitting does not itself consume the actor/critic
random stream. World-model weights are frozen during each actor update;
action derivatives still pass through the model. Optimizer state persists
within this process, without claiming exact restart support.

Validation seeds 30–32 select actor/critic/model triples at updates
0/1/5/10/20/50/100/150/200. The initial physical collection/model fit happens
before validation update zero, so an unchanged actor can be paired with model
round one. A selected model is the snapshot at that actor checkpoint, not the
latest model after all 40 refreshes. Actor files and reports record selected
and latest model digests explicitly.

Fresh final seeds 8100–8102 never select weights. The gate remains zero falls
in all nine ten-second-maximum stand/sway/wave trials and mean joint RMSE
at most 0.15 rad. These conditions differ from the preceding study's final
seeds; comparisons below independently re-score incoming actors on the same
new conditions.

## Actual Control Results

| Method / seed | Selected update | Incoming → selected survival (s) | Incoming → selected RMSE (rad) | Falls / trials |
| --- | ---: | --- | --- | ---: |
| Fixed / 0 | 0 | 2.4156 → 2.4156 | 0.15072 → 0.15072 | 9 / 9 |
| Fixed / 1 | 0 | 2.3467 → 2.3467 | 0.09396 → 0.09396 | 9 / 9 |
| Fixed / 2 | 1 | 1.9822 → 1.9533 | 0.16311 → 0.16274 | 9 / 9 |
| Adaptive / 0 | 0 | 2.4156 → 2.4156 | 0.15072 → 0.15072 | 9 / 9 |
| Adaptive / 1 | 0 | 2.3467 → 2.3467 | 0.09396 → 0.09396 | 9 / 9 |
| Adaptive / 2 | 50 | 1.9822 → 2.2133 | 0.16311 → 0.17508 | 9 / 9 |

Adaptive seed two outlasts both its incoming actor and the fixed-model
selection, with worse tracking. The other two seeds retain the incoming actor.
Fixed seed two illustrates validation/test disagreement: its validation-selected
update lowers fresh-test survival slightly. There are 27 final trials per cell,
all ending in falls, and no qualified candidate. Incoming actors retained in
both cells are the same controllers, not independent successful replications.

The [complete report](../output/research/g1-short-cycle-study.json) preserves
all validation outcomes, physical collection counts, paired model diagnostics,
incoming/selected metrics and MoonData references. Latest rejected actors and
models remain available. Training-loop time is approximately 9.94/11.17/11.00 s
for fixed and 13.45/13.21/15.85 s for adaptive on this CPU. These measurements
include physical refreshes and validation after update zero, but exclude the
initial actor validation, final testing, model diagnostics, serialization and
process/data loading. They are not complete end-to-end time-to-quality results.
The extra model optimizer work and changed collected trajectories also prevent
a matched-cost efficiency claim.

Each cell collects 720 actual training episodes across its three policy seeds.
Fixed records 45,675 transitions; adaptive records 51,883. All 1440 episodes
end in falls, with no time-limit bootstrap tails in this run. These are
training data, separate from the 54 final control trials, and remain preserved
in the compressed per-seed physical records.

## Model Diagnostics And Limits

The unchanged 934 validation and 916 test windows score the selected adaptive
model snapshots only after actor selection. Their normalization matches the
initial model. Eight-step normalized state MSE is:

| Model | Validation | Test | Selected model round |
| --- | ---: | ---: | ---: |
| Initial shared model | 0.14306 | 0.26736 | Before adaptation |
| Adaptive / 0 | 0.14392 | 0.26726 | 1 |
| Adaptive / 1 | 0.13822 | 0.26171 | 1 |
| Adaptive / 2 | 0.12494 | 0.24686 | 10 |

All selected models beat state persistence, reload identically and pass the
frozen-weight autodiff/finite-difference check. Seed two improves average
held-out prediction while still failing control. Its after-two-second test
MSE worsens from 0.18211 to 0.19609 on only three overlapping windows. There
are just eight late validation windows; neither sparse tail set establishes
robust coverage. Numerical derivative consistency is not agreement with
physical derivatives, and eight-step prediction is not a 32-step closed-loop
control guarantee. No held-out episodes enter online fitting.

## Reproduction And Platform Evidence

```sh
moon run scripts/fit_g1_short_cycle.mbtx /absolute/path/to/moonrobo /absolute/path/to/moonrobo/target/learning/g1-counterfactual-study/augmented /absolute/path/to/moonrobo/target/learning/g1-actor-step-study/actor-lr-standard/policy /absolute/path/to/moonrobo/target/learning/g1-short-cycle-study
moon run scripts/score_g1_short_cycle.mbtx /absolute/path/to/moonrobo /absolute/path/to/moonrobo/target/learning/g1-short-cycle-study /absolute/path/to/moonrobo/target/learning/g1-actor-step-study/actor-lr-standard/policy /absolute/path/to/moonrobo/target/learning/experiment-book/moondata /absolute/path/to/moonrobo/output/research/g1-short-cycle-study.json
```

The charter and both configurations are frozen before training; numerical
provider sources are copied into the study directory before execution. The
two IDs above register through the existing MoonData experiment path and
read-only cockpit. Adaptive runs add optional latest-world-model payloads;
selected models and full compressed physical training datasets remain ordinary
checksummed payloads. The policy report distinguishes the shared initial-model
digest from each seed's selected/latest adapted model digests. No new service,
workbench flow or physical permission is introduced.

Nineteen numerical tests pass, including episode/gap/end-boundary handling,
held-out rejection, bounded replay, frozen normalization, independent sampling
and preserved action derivatives. All 885 native tests pass. The existing
binary registry regression also checks that optional latest model bytes remain
readable after removing the original run. General hardening remains deferred.
Both imported sources pass complete MoonData validation with zero findings.
`moon check` and `moon info` complete with zero errors; scoped `moon fmt` passes.
No public MoonBit interface changes are introduced by the optional payloads.

Local disk pressure was reduced by losslessly archiving the old generated
`g1-policy-round-3/train-batch.json` as `train-batch.json.gz`. Its source dataset,
weights and reports remain intact. The active augmented input stays available
as JSON; use `gzip -d` before an older workflow requiring the archived path.

The [paired gradient study](G1_PAIRED_GRADIENT_STUDY.md) now compares these
selected model/critic snapshots in restored physical origins through actual
fall, beyond the short critic-bootstrapped window. Removing the tail improves
one seed's local direction, while a fixed model/critic training comparison
selects no new actors. More frequent fitting alone has not yielded stable
control. Motion/history representation, successful-state coverage,
long-horizon derivative error and critic boundary gradients remain open
explanations; these results do not isolate one cause. Stable control, matched
PPO efficiency, complete phase acceptance and E1/hardware qualification remain
unfinished.
