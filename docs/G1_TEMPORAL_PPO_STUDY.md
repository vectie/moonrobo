# G1 Temporal PPO And Exploration Calibration

Updated: 2026-10-23. This follows the [replay-distribution study](G1_REPLAY_DISTRIBUTION_STUDY.md).
Actual MuJoCo PPO now trains from the same incoming preview actors and initial
finite-task value networks as the model-based temporal studies. Three seeds
complete their fixed ten-collection budget. None passes the nine-trial,
ten-second gate. A separate train-only calibration finds that exploration
noise worsens incoming control, while even noise-free incoming actors fail
many training cases. Neither algorithm has established stable all-case control.

## Shared Interface And Actual Physical Objective

The original supervised H10/F10 preview actors come from
`target/learning/g1-temporal-input-study/preview/policy`. The value networks
come from `g1-temporal-value-study/preview-value-on/policy`; only the critic
fitted at actor update zero is used, alongside the original supervised actor.
Its stored parent hash and `critic_actor_update=0` are checked. A value
checkpoint's selected actor is not substituted for that incoming actor.

Actor and value normalization remain fixed. The actor sees causal observations
and known future joint commands, without privileged state or friction. The
critic uses the existing privileged physical state, H10 observations, eleven
current/future references, context and remaining original task time. No new
world model is loaded or queried to produce transitions, rewards, returns or
policy gradients. Value normalization inherits earlier world-model statistics;
this is not training from scratch without previous data or models.

The actor samples a Gaussian with fixed standard deviation 0.05 in pre-tanh
latent space. The same bounded residual/servo transform yields actual applied
joint setpoints. PPO uses the saved latent sample's likelihood rather than
assigning a Gaussian density to the clipped actuator target. Deterministic
evaluation uses the latent mean. The refactored `latent_mean` adds no parameters
and preserves existing checkpoint/action conventions.

Rewards are recomputed from actual simulator states using the existing joint
tracking, uprightness, height and smoothness objective. Canonical dataset
`reward` remains its original tracking-only quantity; the logs separately retain
the full objective rewards. Targets are actual finite Monte Carlo returns,
with zero tail at a real fall or the original ten-second task end. There is
no continuing-task time-limit bootstrap or imagined-value target.

The clipped PPO surrogate weights each point by gamma to its episode step and
the product of preceding soft-continuation factors. This matches the model
study's finite objective rather than silently dropping its survival weighting.
An analytic two-step test verifies that the weighted score gradient equals
the exact expected-return gradient, including action-dependent continuation.
Advantages use the pre-update value baseline and positive scalar rescaling,
without centering. Simulator states and histories are detached inputs.

Each collection runs all nine train cases: stand, independent pose offsets
and independently phased joint sinusoids at friction 1.0/0.8/0.6. Canonical
sway/wave are not sampled for training. Reset seed is
`5600 + 10000 * policy_seed + collection_index`; ten collections yield 90
episodes per seed and at most 45,000 new control transitions. Failed episodes
remain included. These are simulation episodes, not physical robot trials.

Each iteration allows four shuffled minibatch epochs of size 256, actor Adam
learning rate 0.00001 and value Adam 0.001. Full-batch exact fixed-variance
Gaussian mean KL is checked after every actor step. Exceeding 0.02 ends actor
updates for that collection; the crossing step is retained. This is a stopping
criterion, not a strict trust-region cap or rollback. Value training still
completes its four epochs. Actual actor steps and KL overshoots remain visible.

## Control Results And Sampling Cost

Validation uses sway/reset seeds 30–32 and selects among iterations 0–10.
Fresh final seeds 9400–9402 evaluate stand/sway/wave, nine trials per actor.
The selected teacher-only model-based preview actors are independently
re-evaluated under these same final conditions. Their earlier 9200-series
scores are not treated as paired results. Repeated canonical development
motions do not establish broad unseen-motion generalization.

| PPO seed | Selected collection | Training transitions | Actor steps | Final survival (s) | Final RMSE (rad) | Falls / 9 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 0 | 10 | 11,737 | 36 | 7.3289 | 0.04935 | 6 |
| 1 | 10 | 10,107 | 25 | 6.3400 | 0.05251 | 8 |
| 2 | 2 | 9,602 | 23 | 7.3400 | 0.04744 | 3 |

The three runs use 31,446 actual transitions and 84 actor optimizer steps.
Critic steps are 204/176/164 and measured training seconds are
12.75/11.77/11.67 for seeds 0/1/2, with the timing scope described below.
All 270 stochastic training episodes fall before the ten-second cap. No
selected policy meets zero falls and mean RMSE ≤0.15 rad, so none receives
a longer-duration qualification follow-up. Selected and latest actor/value
pairs are both retained; the seed-two selected checkpoint is not its final one.

| Seed | Incoming survival (s) / falls | PPO survival (s) / falls | Prior teacher-model survival (s) / falls |
| --- | --- | --- | --- |
| 0 | 7.2467 / 6 | 7.3289 / 6 | 7.5422 / 3 |
| 1 | 6.4733 / 7 | 6.3400 / 8 | 7.1022 / 4 |
| 2 | 7.3356 / 3 | 7.3400 / 3 | 7.3356 / 3 |

Every cell has nine final trials. All three PPO candidates fail every wave
trial; seed one also loses standing and two sway trials. PPO does not show a
consistent improvement over its incoming actors or prior model-based policies.

The comparison report preserves incoming-policy and prior model-policy scores,
per-case failures, complete selection history, value errors and actual actor/
critic update counts. The methods have different training histories, sample
budgets and optimizer schedules. These results compare final behavior under
the same evaluation conditions; they do not estimate matched learning efficiency.
Shared teacher/supervised/value initialization costs remain inherited costs,
not newly collected PPO samples. Training seconds include collection, target
construction, updates, log writes and in-training validation, but exclude
incoming preparation and final evaluation.

## Training-Only Exploration Calibration

After observing the training falls, a separate no-learning experiment freezes
the incoming actors and first PPO training reset conditions. Each of three
actors receives standard deviations 0/0.005/0.01/0.05 on the same nine train
cases. Per-case random streams are coupled across amplitudes so a different
fall time cannot shift noise for the next case. These streams differ from the
full PPO run's single continuous stream; the calibration is not an exact replay
of its first collection. No validation/test results select an amplitude.

| Latent standard deviation | Episodes | Falls | Mean survival (s) |
| --- | ---: | ---: | ---: |
| 0 | 27 | 19 | 5.1348 |
| 0.005 | 27 | 22 | 4.4807 |
| 0.01 | 27 | 24 | 4.0770 |
| 0.05 | 27 | 26 | 2.7007 |

The 0.005 noise corresponds to about 0.00142–0.00146 rad setpoint RMS; 0.05
gives about 0.01398–0.01432 rad. These measure noisy versus mean actions at
the same visited observation, after actor tanh/clipping. They are not trajectory
distances from a separate deterministic rollout. Latent saturation is recorded
as a diagnostic, not inferred from a single maximum latent value.

One incoming actor fails all nine train cases even without noise. Smaller
exploration helps retain some trajectories but does not solve that starting
coverage gap. Counts use a limited, correlated set of actors/reset conditions,
not independent reliability estimates. All 108 diagnostic episodes and their
22,131 actual transitions are retained separately from PPO's training sample count.

The next bounded study should establish train-family coverage and tolerance
to exploration at initialization, then test repeated PPO improvement with a
declared exploration/step-size budget. Changing Gaussian scale also changes
likelihood sensitivity and KL stopping, so reducing noise alone is not an
isolated change in learning behavior. The existing teacher/student pipeline
can collect the needed actual disturbed states before adding new infrastructure.
Stable quality remains the prerequisite for a meaningful cost-to-target claim.

The subsequent [disturbance initialization study](G1_DISTURBANCE_INITIALIZATION.md)
now exercises that pipeline with clean/noisy collection at fixed supervised
update budgets. It selects more updated actors with disturbed collection, but
neither workflow qualifies on the final canonical suite. New independent noise
audits and all actual student controls remain separate from teacher labels.

## Stored Evidence And Reproduction

The completed run is `target/learning/g1-temporal-ppo-v3`; two earlier
preflight attempts stop before any updates because an absolute latent-output
tolerance was too strict. Every captured causal input agrees bit for bit;
single-row versus batched float32 matrix multiplication explains the small
latent differences. The final collector checks exact inputs and scale-aware
latent agreement, retaining the maximum numerical difference separately.
The preflight attempts do not contribute to the completed run's sample count.

The [derived report](../output/research/g1-temporal-ppo-study.json) binds full
compressed training records by SHA-256. Numerical verification recomputes every
saved episode's actual latent-to-setpoint mapping, causal previous action,
full objective rewards, finite returns and survival weights. Applied-action
reconstruction error is zero. The native MoonBit reader checks the complete
first-seed/first-batch representative dataset; it does not claim to parse all
three training logs. The collection's representative role is explicit.

MoonData registers `temporal-ppo-preview` with the distinct report format
`moonrobo.g1-temporal-ppo-fit.v1`, the representative collection, selected/latest
actor-value pairs, final physics traces and all three complete training logs
as `learning-ppo-physics` payloads. It has no dummy dynamics report or weights.
Existing model-based imports still require their dynamics report. The current
read-only API/cockpit opens the PPO experiment through the same summaries and
physics route. Noise calibration remains a separate local diagnostic with its
own hashed full physics log. Registration grants no physical execution authority.

```sh
moon run scripts/fit_g1_temporal_ppo.mbtx /absolute/path/to/moonrobo /absolute/path/to/moonrobo/target/learning/g1-temporal-input-study /absolute/path/to/moonrobo/target/learning/g1-temporal-value-study /absolute/path/to/moonrobo/target/learning/g1-temporal-ppo-new
moon run scripts/calibrate_g1_temporal_ppo_noise.mbtx /absolute/path/to/moonrobo /absolute/path/to/moonrobo/target/learning/g1-temporal-ppo-new /absolute/path/to/moonrobo/target/learning/g1-temporal-ppo-noise-new
moon run --target native scripts/report_g1_temporal_ppo.mbtx /absolute/path/to/moonrobo /absolute/path/to/moonrobo/target/learning/g1-temporal-ppo-new /absolute/path/to/moonrobo/target/learning/g1-teacher-value-study /absolute/path/to/moonrobo/target/learning/g1-temporal-ppo-noise-new /absolute/path/to/moonrobo/target/learning/temporal-ppo-new-book/moondata /absolute/path/to/moonrobo/output/research/g1-temporal-ppo-study-new.json
```

Use fresh training/calibration directories and a fresh MoonData root when
repeating the study with changed training inputs; the reporter's local example
ID is fixed. The registry CLI can separately import a run under a new ID.
The pinned CPU environment, G1 model and existing native dataset/registry
executables are prerequisites. Providers and charters are archived before
workers start. This adds SM-2/SM-3 and experiment-inspection evidence; complete
phase gates, matched efficiency, the full workbench, E1 and hardware release
remain unfinished.

Verification: 39 numerical tests, six MoonData registration tests and three
host-projection tests pass. The standalone-PPO regression proves binary training
logs and physics remain readable after removing the producer directory, without
any dynamics payload. `moon info`, scoped formatting and interface review pass;
this importer extension adds no public MoonBit API.
