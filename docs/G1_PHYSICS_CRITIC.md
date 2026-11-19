# G1 Physics-Return Critic Calibration

Updated: 2026-10-23. This follows the [counterfactual study](G1_COUNTERFACTUAL_STUDY.md).
Actual MuJoCo returns now supervise an optional critic-training method. Value
calibration improves on independent reset conditions, but no updated actor is
selected and every final ten-second-maximum trial still falls.

## Frozen Comparison

Both methods use the augmented counterfactual training batch, its invariant
world model seed zero, the same three incoming selected actors/critics and
weights-only initialization. Actor normalization is retained, optimizers reset,
and both world model and critic mask absolute horizontal root coordinates.
Each method performs 200 actor updates with batch 64, a 32-step model rollout,
terminal critic bootstrap, the same reward and ±0.3 rad action residual.

The `critic-imagined` control retains the original imagined-state GAE fitting:
two epochs and four minibatches per actor update. `critic-physics` instead
collects fresh physical episodes and fits their soft-return targets before
actor updates 1/21/41/…/181. Each refresh has 160 supervised optimizer steps
with replacement, minibatch 512. Both methods therefore have 1600 critic
optimizer steps per seed. This also changes target sampling and update timing,
and adds physical collection cost; it does not isolate the effect of labels
alone or establish matched end-to-end learning efficiency.

All configurations and the charter are written before training. Validation
uses seeds 30–32 at actor updates 0/50/100/150/200, with update zero eligible.
Final scoring uses fresh seeds 780–782 on canonical stand/sway/wave cases.
Qualification remains zero falls over nine ten-second trials and mean joint
RMSE ≤0.15 rad. No model-return score or final test result selects weights.

## Actual Physics Targets

Only the six training cases are collected: standing and constant pose offsets
at friction 1.0/0.8/0.6. There is no added exploration noise. Reset seeds are
`900 + 10000 * training_seed + refresh_index`; validation/test reference families
are excluded. Each episode starts at the normal reset and runs until an actual
fall or the ten-second cap. The actor changes between refreshes; targets remain
from the last refresh for up to 19 subsequent actor updates.

For recorded reward `r`, analytic continuation `c`, discount γ=0.99 and a true
termination flag `d`, targets satisfy `G[t] = r[t] + γ*c[t]*(1-d[t])*G[t+1]`.
Rewards are recomputed from actual next states, actual applied actions, previous
actions and goals using the full actor reward. They are not the dataset's
tracking-only reward field. A fall has a zero tail. A time-limit truncation
uses the critic's pre-fit last-state value and is explicitly counted, avoiding
a false failure label. All 180 episodes in this run actually fall, so every
recorded target has an uncensored zero tail.

| Training seed | Refreshes | Episodes | Physical transitions | Falls | Critic optimizer steps |
| --- | ---: | ---: | ---: | ---: | ---: |
| 0 | 10 | 60 | 3675 | 60 | 1600 |
| 1 | 10 | 60 | 4344 | 60 | 1600 |
| 2 | 10 | 60 | 3857 | 60 | 1600 |

Each gzip JSONL record binds the actor update, actual actor tensor/buffer digest,
reset seed, complete physical transition dataset, per-transition target and
episode tail values. The policy report retains compressed-byte digests, sample
counts, timing and within-batch fit errors before/after calibration. Those fit
errors are training diagnostics, not independent validation.

## Independent Value And Control Results

The [probe protocol](../examples/learning/g1-physics-critic-probe.json) uses reset
seeds 790–792, absent from training, with starts at 0/1.0/1.5/2.0 seconds where
the selected actor is still alive. Both methods select the incoming actor at
update zero for every seed. Their physical probe returns are checked to be
exactly identical, allowing a paired value-function comparison:

| Seed | Recorded states | Imagined-source selected critic MAE | Physics-source selected critic MAE |
| --- | ---: | ---: | ---: |
| 0 | 28 | 70.5719 | 2.7527 |
| 1 | 36 | 16.9984 | 9.5803 |
| 2 | 30 | 53.4284 | 8.4273 |

MAE compares predicted value with recorded discounted soft physical return.
All probe source episodes fall; no unknown tail is treated as zero. The
physics-source selected critic is its initial calibration, because no subsequent
actor checkpoint wins selection. Thus this demonstrates better value estimates
for the incoming actors, not successful later policy learning. Horizontal-shift
value changes stay exactly zero.

Both methods have the same final selected-actor outcomes:

| Seed | Mean survival (s) | Mean joint RMSE (rad) | Falls / trials |
| --- | ---: | ---: | ---: |
| 0 | 1.9333 | 0.14194 | 9 / 9 |
| 1 | 2.2756 | 0.09373 | 9 / 9 |
| 2 | 1.9489 | 0.16309 | 9 / 9 |

No candidate qualifies. Six training runs select three unchanged incoming
controllers; they are not six independently improved controllers. Latest
weights are retained even though rejected. The probe also scores latest critics
on selected-actor trajectories; those rows are off-policy diagnostics, not
calibration errors for the latest actors' own behavior. Better scalar values
do not prove correct value gradients or useful model-based actor gradients.

Reported per-seed training time is about 5.3 s for imagined GAE and 6.4–6.6 s
for physical targets on this CPU. Physical timing includes initial calibration
and compressed logging. Input JSON loading and final scoring are outside those
figures. Full cost-to-target remains undefined because neither method reaches
the target. The [verification summary](../output/research/g1-physics-critic-verification.json)
preserves every seed, physical sample totals, independent critic scores and
registered evidence references.

## Run And Platform Evidence

Use the environment and model assets from [CPU physics](G1_CPU_PHYSICS.md),
then run from the repository root with fresh output paths/experiment IDs:

```sh
moon run --target native scripts/fit_g1_physics_critic.mbtx /absolute/path/to/moonrobo /absolute/path/to/moonrobo/target/learning/g1-counterfactual-study/augmented /absolute/path/to/moonrobo/target/learning/g1-counterfactual-study/branch-new-invariant/policy /absolute/path/to/moonrobo/target/learning/g1-physics-critic-study
moon run --target native scripts/probe_g1_critic.mbtx /absolute/path/to/moonrobo /absolute/path/to/moonrobo/target/learning/g1-physics-critic-study/critic-physics/policy /absolute/path/to/moonrobo/target/learning/g1-physics-critic-study/physics-probe /absolute/path/to/moonrobo/examples/learning/g1-physics-critic-probe.json
moon run --target native scripts/probe_g1_critic.mbtx /absolute/path/to/moonrobo /absolute/path/to/moonrobo/target/learning/g1-physics-critic-study/critic-imagined/policy /absolute/path/to/moonrobo/target/learning/g1-physics-critic-study/imagined-probe /absolute/path/to/moonrobo/examples/learning/g1-physics-critic-probe.json
moon build cmd/learning_experiment --target native
moon run --target native scripts/verify_g1_physics_critic.mbtx /absolute/path/to/moonrobo /absolute/path/to/moonrobo/target/learning/g1-physics-critic-study /absolute/path/to/moonrobo/target/learning/experiment-book/moondata /absolute/path/to/moonrobo/output/research/g1-physics-critic-verification.json
```

MoonData registers `critic-imagined` and `critic-physics` with all three failed
candidates. The latter also seals each `policy/critic-physics-seed-N.jsonl.gz`
as a binary `learning-critic-physics` payload. Native checksums match the
producer's recorded compressed digests, all gzip streams pass integrity checks,
and full root validation has zero findings. The registry regression verifies
these bytes remain available after removing the original run. There is no new
catalog, job service, hardware action or physical authority.

Verification: 16 numerical tests and all 885 native repository tests pass.
The return test distinguishes an actual terminal zero tail from a truncated
bootstrap tail. Existing input-gradient, actor reload and frozen-world-model
checks pass for every training seed. Old configurations retain imagined GAE
and require no physics log. Public MoonBit package interfaces are unchanged.

The subsequent [actor-update study](G1_ACTOR_UPDATE_STUDY.md) now compares
actual parameter directions in restored physics, replay/recent-state batches,
two step sizes and earlier selection points. One early candidate improves
survival, with worse tracking and every final trial still falling. The current
critic also omits the actor's previous-action
input, so its scalar calibration is not a proof of a fully Markov value model.
Stable control, broader motions, matched efficiency and full phase acceptance
remain outstanding; production hardening stays deferred.
