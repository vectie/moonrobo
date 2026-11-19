# G1 Reference Critic-Tail Training Comparison

Updated: 2026-10-23. Status: three-seed training and native verification
completed. All six final policies fail the unchanged quality gate.

The [physical direction comparison](G1_REFERENCE_TAIL_DIRECTIONS.md) found useful
small prefix-only directions but no qualified controller. This experiment
tests actual collection, model/value fitting and repeated actor optimization,
followed by the original full-reference quality gate. It is an SM-3 learning
experiment; successful quality/cost and the complete platform gates remain open.

## Frozen protocol

The [charter](../examples/learning/g1-reference-tail-training.json) compares
`model-based` (with physical-return critic tail) and `prefix-only` on the same
free residual dynamics architecture. Neither arm inherits the previous model,
critic or parameter directions. Both use the identical nonpassing zero-output
actor with its declared inherited feedback and normalization. The three seeds
control new physics/optimization randomness, not different incoming actors.

Each of three cycles collects all nine clips from 0/10/20-second origins,
producing 27 episodes per cycle. This removes the preceding sequential-origin
curriculum. The first collection is shared within a seed and charged to each
standalone learner. Later collections follow each arm's own policy. Noise has
the same raw-logit standard deviation 0.03, with a distinct seeded stream per
origin. All state transitions for fitting come from new own-policy physics;
source controls are not learning labels. Reference motion and integration
snapshots remain commands/reset setup.

Both arms fit the same eight-step world model for 900 updates and the same
physical-return critic for 128 updates per cycle, then perform twelve H32 actor
Adam steps. Prefix-only omits the critic call inside actor imagination. Its
critic is still fitted/stored, with cost reported, to keep this comparison's
fitting budget controlled. Actor history, causal EMA memory, reference phase,
fall handling and finite-end semantics are otherwise identical.

Actor imagination samples uniformly with replacement from those 27 reset
states, rather than from every collected physical state. The prefix arm
therefore directly optimizes at most 0.64 seconds after each reset. Later
physical states train dynamics/value, but are not direct actor rollout origins.
This coverage limit remains relevant even when the scalar model fit improves.

Each proposed actor parameter step is rescaled if its raw-logit RMS change
exceeds 0.005 on 256 fixed current-cycle history samples. Adam moments retain
the original gradients. This local step cap does not bound all future outputs,
physical actions or total accumulated policy change. Proposed/applied RMS and
parameter scaling are recorded for every update in both arms.

Nine extra origin-zero diagnostic episodes, three per seed, never enter model,
critic or actor fitting. Every final-cycle actor is independently reloaded and
evaluated at all 27 clip/origin cells, completing the remaining 30/20/10 seconds
to qualify. The unchanged per-trial limits are joint RMSE ≤0.03 rad, body/root
position RMSE ≤0.05 m, root orientation RMSE ≤0.1 rad and zero falls. There is
no checkpoint/seed selection or intermediate quality check.

Within this pair, critic-tail use is the algorithm difference. Both arms also
share larger collection/model-fitting budgets, interleaved reset coverage and
the step cap compared with historical MBRL/PPO studies. Results must not be
attributed to tail removal alone by comparison with those older protocols.
PPO-specific fields retained in the base configuration are unused here.

The 603 new physical records are 27 initial, 81 shared first collection,
9 held-out model diagnostics, 324 exclusive later training and 162 final tests.
Each standalone learner is charged 81 training episodes; actual common data
are collected/stored once. Known training-family coverage does not establish
unseen-motion generalization, hardware qualification or complete SuperMimic
reproduction.

## Actual training results

The shared incoming policy falls in all 27 cells, averaging 5.62815 seconds.
Every learner performs 36 actor, 2700 model and 384 critic optimizer steps.
All final-cycle checkpoints are evaluated without selecting an earlier update.

| Method | Seed | Falls / 27 | Mean survival s | Pooled joint RMSE rad | Body RMSE m | Root position RMSE m |
| --- | --- | --- | --- | --- | --- | --- |
| With tail | 0 | 27 | 5.964 | 0.04884 | 0.14115 | 0.14883 |
| Prefix only | 0 | 27 | 3.472 | 0.05458 | 0.18956 | 0.19913 |
| With tail | 1 | 27 | 2.117 | 0.18053 | 0.24029 | 0.23437 |
| Prefix only | 1 | 27 | 5.230 | 0.03559 | 0.14298 | 0.14920 |
| With tail | 2 | 27 | 5.619 | 0.05413 | 0.14329 | 0.15193 |
| Prefix only | 2 | 27 | 5.592 | 0.04079 | 0.13834 | 0.14518 |

Prefix-only wins the paired survival comparison for seed 1, loses for seed 0
and is close for seed 2. Its local direction advantage has not become
consistent trained control. All 162 final trials fall, so every quality gate
and successful cost-to-target remains unachieved. Pooled errors are weighted
by recorded steps through fall; qualification still checks each trial's
completion and limits separately.

The step cap activates on 19 of 216 actor steps, all in with-tail seed 1.
The largest proposed RMS is 0.0349992; the largest applied RMS over all arms
is 0.00498476. Other arms never hit the cap. These bounded individual steps
do not establish bounded accumulated policy error or physical stability.

This training comparison also differs from the preceding local probes:
models fit all reset phases, directions use sampled reset minibatches and Adam,
and policies receive repeated updates/recollection. The probes used frozen
models fit to origin-zero data and a single normalized gradient direction.
The new results therefore do not isolate why that local advantage fails to
persist. Nor do they prove that the 0.64-second actor coverage limit alone
causes the failures. A next actor-state distribution experiment should test
recorded mid-trajectory origins while preserving causal history/EMA and the
same quality gate, rather than assuming tail removal is sufficient.

## Verification and cost

All **603 episodes / 141,351 actual transitions** pass numerical reconstruction
and the native MotionDataset reader. There are 405 unique training episodes /
93,164 transitions, with the first 81 / 19,415 shared across arms. Charging
those shared records to each standalone learner yields 486 logical training
episodes / 112,579 transitions; they are not independent extra collection.
Initial, diagnostic and final physics are kept separate.

Independent checkpoint loading confirms bit-identical first model and value
fits within every seed pair. Both saved seed-0 final actors pass a float64
directional finite-difference check through H32 controller memory: absolute
errors 2.11e-9 with tail and 3.26e-9 without. This is implementation-gradient
consistency, not physical Jacobian accuracy. Frozen model/value tensors stay
unchanged during the checks.

Maximum reconstruction errors are 1.97e-6 for causal features, 5.37e-7 for raw
actor means and 0.00003055 rad for applied controls, below the declared limits.
Reward reconstruction is exact; reconstructed quality differs from original
scalar metrics by at most 5.23e-9. Archives are float32 and original quality
scalars use float64 MuJoCo; bit-exact float64 trajectory storage is not claimed.

Provider time is 668.04 local CPU seconds, preceded by 1.31 seconds of setup.
Native verification and historical reference/feedback/normalization development
are outside that interval. Per-arm collection, model/critic/actor fitting,
diagnostics, serialization and evaluation costs remain in the report. Every
`cost_to_target.status` is `not-reached`, with no exact first crossing measured.

- [Verified full report](../output/research/g1-reference-tail-training.json)
- [Compact costs/step/phase summary](../output/research/g1-reference-tail-training-summary.json)
- [Training implementation](../providers/motion_learning/reference_learning_study.py)
- [Actor update and imagination](../providers/motion_learning/reference_learning.py)
- [Training orchestration](../scripts/fit_g1_reference_learning.mbtx)
- [Verification orchestration](../scripts/report_g1_reference_learning.mbtx)

The study directory `target/learning/g1-reference-tail-training` preserves
incoming and cycle actor/model/value checkpoints, all physical archives,
frozen numerical sources, charter and independent checks. Source report SHA-256:
`d8ee1744319036e904f6add749cb3e8aed78b8b7cd9426c1d83169bb373d3664`.
These new study artifacts have not yet been registered in MoonData. No default
policy/algorithm is changed and no hardware authority is granted. Full workbench,
broader motion coverage, successful matched learning efficiency and remaining
[phase gates](SUPERMIMIC_PHASE_PLAN.md) stay open.

The subsequent [actor-state origin comparison](G1_REFERENCE_STATE_ORIGINS.md)
now reuses this prefix baseline and changes only the actor's sampling pool to
current-cycle physical states. All three new seed means improve. Seed 2
completes three remaining-ten-second pose conditions; two pass per-trial
quality limits, but its other 25 cells fail. All 603 paired records validate,
with 243 explicitly new. The [learning platform integration](G1_REFERENCE_LEARNING_PLATFORM.md)
now registers that paired study and this study's reused prefix baseline; the
with-tail arm remains separate research evidence. No full-policy quality gate
is completed.
