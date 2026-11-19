# G1 Sustained-State Collection And Teacher Initialization

Updated: 2026-10-23. This follows [paired-gradient diagnostics](G1_PAIRED_GRADIENT_STUDY.md).
A handcrafted simulator controller now completes the canonical ten-second
suite and supplies sustained training states. Supervised initialization plus
student-state labeling improves learned actors: the best completes six of
nine fresh trials, with three wave failures. No learned candidate passes the
existing all-nine gate, and this is not a world-model learning result.

## Diagnose And Build A Sampling Controller

The original fixed-position baseline falls at 1.24 seconds. In a training-only
standing diagnostic, by 0.6 seconds its COM is 0.0688 m ahead of the foot-site
midpoint and ankle position error is about -0.204 rad. Hip, knee and waist
errors also show substantial load deflection. These are measurements on the
unchanged pinned Menagerie G1 scene, not modified servo gains or gravity.

The [feedback provider](../providers/motion_learning/balance_teacher.py) uses
the actual simulated COM, foot sites, root orientation, angular velocity and
joint velocity. It modifies position setpoints through the same ±0.3 rad
per-joint residual cap and actuator clipping at the same 20 ms control period.
It has privileged simulator access and a filtered COM-error velocity; it is
not the deployed neural actor or an implementation for physical hardware.

All parameter fitting uses six standing/constant-pose train cases at friction
1.0/0.8/0.6 and seeds 2100/2101. Seven successive bounded development grids
contain 225 candidates in total, each scored on twelve trials. All intermediate
results and configurations are retained in the [combined report](../output/research/g1-teacher-initialization-study.json).

| Development family | Candidates | Selected falls / 12 | Mean survival (s) | Mean joint RMSE (rad) |
| --- | ---: | ---: | ---: | ---: |
| Weak ankle feedback | 54 | 12 | 1.4400 | 0.07437 |
| Stronger COM correction | 27 | 9 | 4.0683 | 0.05369 |
| More COM-velocity damping | 27 | 3 | 8.1583 | 0.03245 |
| Hip assistance | 54 | 6 | 6.1367 | 0.06103 |
| Waist assistance | 18 | 3 | 8.7217 | 0.04026 |
| Waist without static ankle bias | 27 | 3 | 8.2400 | 0.03377 |
| Quasistatic support compensation | 18 | 3 | 7.9850 | 0.01671 |

The remaining ankle-only pose failures hit the positive ankle residual cap
from about 0.2 seconds, while COM continues to drift forward. A stronger
feedback gain alone cannot increase that bounded command. Waist assistance
adds an opposite pitch correction to move the upper body back. The selected
family minimizes falls, then maximizes survival, then minimizes tracking error
on development only. Its parameters are COM gain 16, filtered velocity gain
32, ankle pitch bias 0.2 rad, waist share 0.25 and extra joint-velocity damping
0.02. Hip assistance is zero. It still fails three development pose trials.

The unused support-compensation variant computes a quasistatic vertical
support assumption using foot-point Jacobians and simulator bias forces, then
converts estimated joint torque into bounded servo offsets. It applies no
external support or model changes. Jacobian semantics follow the pinned
[MuJoCo 3.3.7 API](https://mujoco.readthedocs.io/en/3.3.7/APIreference/APIfunctions.html#mj-jac);
the support allocation is our controller assumption. A numerical regression
checks free-base force/moment balance on a small articulated model without
altering its applied external forces. The selected waist controller does not
use this variant.

## Frozen Evaluation And Actual Training Data

Earlier fit workflows held evaluation/collection until all twelve development
trials survived. None reached that condition. A separate collection charter,
written before opening independent seeds, explicitly accepts partial teacher
success to obtain training data and preserves all failures. This does not
satisfy the earlier development gate. The final teacher was selected entirely
from training conditions, without tuning against independent results.

On canonical stand/sway/wave cases at fresh seeds 8300–8302, that frozen
teacher completes all nine ten-second trials: zero falls, mean joint RMSE
0.03629 rad. The original fixed-position baseline on exactly those conditions
falls 9/9 at 1.24 seconds with pooled RMSE 0.09708 rad. This is a measured
canonical sampling baseline; its separate pose-offset development failures
remain, and no broad physical-control qualification is claimed.

Train-only recollection uses seeds 2200–2203 on all six train cases. It records
24 episodes and 10,221 actual transitions, including 7,821 at or after two
seconds. Fifteen episodes reach the ten-second limit; nine end in actual falls.
Mean survival is 8.5175 s and mean joint RMSE 0.04166 rad. Every episode remains
in the raw dataset, with actual teacher controls and original source-family
ownership. The teacher digest is included in episode identities.

The native MoonBit reader validates the data and materializes point batches:
10,221 train, 1,500 validation and 1,500 test rows. Only recollected train
episodes feed the train batch; validation/test rows come from their separate
canonical teacher evaluation families. These length-one batches are inputs
for supervised initialization, not eight-step autoregressive model windows.
The [data report](../output/research/g1-balance-teacher-data.json) retains their
digests, teacher binding, counts and the paired fixed-position baseline.

## Behavioral Cloning Does Not Transfer By Action Error Alone

The [cloning provider](../providers/motion_learning/behavior_cloning.py) trains
the existing two-layer 128-wide actor on recorded observations, goals and
actual teacher actions. No privileged COM/foot values enter its inference
inputs. All 24 train episodes, including failures, are used. Each minibatch is
half uniform points and half points from the first two seconds of episodes.

Three seeds each run 3000 Adam updates, batch 256, learning rate 0.001, with
the same bounded action head. Physical validation seeds 30–32 select among
updates 0/100/500/1000/2000/3000; final seeds 8400–8402 never select weights.
Every seed selects update 3000. Training action RMSE is only
0.00114/0.00128/0.00133 rad, yet fresh physical trials all fall. Mean survival
is 2.1600/2.1156/2.8956 s. Fitting recorded teacher actions closely is not
evidence of maintaining the teacher's closed-loop distribution.

## Label Student-Visited States

The [dataset-aggregation provider](../providers/motion_learning/dataset_aggregation.py)
starts from those selected cloning actors. Ten rounds each run twelve actual
student-controlled train episodes, querying the exact archived teacher at
each pre-action state. The recorded `applied_action` always remains the
student's real command. Counterfactual `teacher_action_targets` are a separate
array in explicit episode/step order, never substituted into physics records.

Each round performs 1000 supervised updates, batch 256, learning rate 0.0003,
half initial teacher points and half accumulated student-state labels. Recent
labels retain at most 50,000 points per seed. Actor normalization is frozen;
optimizer state continues within the process. Reset seeds are
`2400 + 10000 * policy_seed + 2 * round_index`, plus the following seed.
Only train reference families are collected. Teacher implementation bytes
must match the fitted provider digest; the selected teacher's archived source
is copied into the run rather than silently using a later controller variant.

Validation physics seeds 30–32 select after rounds 0–10. Selected rounds are
7/7/4. Final seeds 8500–8502 never choose weights. Independent incoming-actor
scoring on these exact final conditions yields:

| Seed | Incoming → selected survival (s) | Incoming → selected RMSE (rad) | Falls / 9 | Selected case outcomes |
| --- | --- | --- | ---: | --- |
| 0 | 2.1400 → 4.8311 | 0.07005 → 0.05799 | 9 | Stand, sway and wave each fall 3/3 |
| 1 | 2.1333 → 6.7422 | 0.07002 → 0.05027 | 7 | Two sway trials reach ten seconds |
| 2 | 2.9511 → 7.3644 | 0.06578 → 0.04713 | 3 | Stand and sway each reach ten seconds 3/3; wave falls 3/3 |

Across three selected actors, eight of 27 final trials complete ten seconds.
The existing learned-control gate remains zero falls over all nine trials and
mean RMSE ≤0.15 rad. Every seed remains unqualified. Ten-second successes have
not been checked at longer duration or on hardware.

Aggregation records 360 actual training episodes, 93,453 transitions and 279
falls; the other 81 reach the time limit. Per-seed counts are
30,915/28,046/34,492 transitions and 100/98/81 falls. All actual transitions,
teacher targets and generating policy-state digests remain in three compressed
JSONL files, with gzip integrity and hashes verified. Selected/latest actor
weights and all final physical traces remain available. Model-format reload
checks pass. The retained critic has zero output and is explicitly untrained;
it needs physical-return calibration before a future critic-based policy fit.

## Reproduce And Continue The Learning Plan

```sh
moon run scripts/fit_g1_balance_teacher.mbtx /absolute/path/to/moonrobo /absolute/path/to/moonrobo/examples/learning/g1-balance-teacher-waist-fit.json /absolute/path/to/moonrobo/target/learning/g1-balance-waist-teacher
moon run scripts/collect_g1_balance_teacher.mbtx /absolute/path/to/moonrobo /absolute/path/to/moonrobo/target/learning/g1-balance-waist-teacher /absolute/path/to/moonrobo/target/learning/g1-balance-teacher-data /absolute/path/to/moonrobo/output/research/g1-balance-teacher-data.json
moon run scripts/fit_g1_behavior_cloning.mbtx /absolute/path/to/moonrobo /absolute/path/to/moonrobo/target/learning/g1-balance-teacher-data /absolute/path/to/moonrobo/target/learning/g1-teacher-bc
moon run scripts/fit_g1_dataset_aggregation.mbtx /absolute/path/to/moonrobo /absolute/path/to/moonrobo/target/learning/g1-balance-teacher-data /absolute/path/to/moonrobo/target/learning/g1-teacher-bc /absolute/path/to/moonrobo/target/learning/g1-teacher-aggregation
moon run scripts/report_g1_teacher_initialization.mbtx /absolute/path/to/moonrobo /absolute/path/to/moonrobo/output/research/g1-balance-teacher-data.json /absolute/path/to/moonrobo/target/learning/g1-teacher-bc /absolute/path/to/moonrobo/target/learning/g1-teacher-aggregation /absolute/path/to/moonrobo/output/research/g1-teacher-initialization-study.json
```

Use fresh output directories. The full seven-family development comparison
is data-dependent; rerunning just the final waist grid reproduces that fixed
grid, not the history of selecting it. Raw numerical sources/configurations
are archived before every run. The [combined report](../output/research/g1-teacher-initialization-study.json)
retains all 225 development candidates and supervised-training results.

Twenty-three numerical tests pass, including feedback signs and bounds,
episode reset, support-force calculation and separation of counterfactual
teacher targets from actual student actions. All 885 native tests pass. This
turn adds numerical providers and `.mbtx` orchestration; no public MoonBit
interface or hardware path changes are introduced.

These initialization artifacts use distinct report formats and remain local
research evidence; they are not inserted into the existing world-model-run
registry as if dynamics had been trained or used here. SuperMimic-style
world-model improvement, matched PPO efficiency, the complete workbench and
E1 qualification remain incomplete. All physical-execution flags remain false.

The [sustained-model study](G1_SUSTAINED_MODEL_STUDY.md) now uses those actual
transitions for a refit and physical-critic actor comparison. It improves global
common-scale prediction while worsening sparse late prediction; new-model
refinement selects no updated actor. Teacher target arrays stay excluded from
dynamics action inputs. Production hardening remains deferred. For disk space,
the old generated batches in `g1-policy-round-2`,
`g1-policy-loop-current` and `g1-policy-loop` were losslessly archived as
`train-batch.json.gz`; original datasets/reports/weights remain intact.
Restore an old batch with `gzip -d` before workflows requiring its JSON path.
