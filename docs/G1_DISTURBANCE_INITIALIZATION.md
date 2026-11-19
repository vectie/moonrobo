# G1 Teacher Supervision Under Student Action Disturbance

Updated: 2026-10-23. This follows the [temporal PPO and noise study](G1_TEMPORAL_PPO_STUDY.md).
Two supervised initialization workflows now compare clean student collection
with small latent-action disturbance. Three seeds per workflow start from the
same original H10/F10 preview actors. Disturbed collection selects updated
actors in all three seeds, while clean collection selects one. On independent
train-family trials at latent noise 0.005, falls drop from 22/27 incoming to
13/27 disturbed versus 18/27 clean. None passes
the final nine-trial, ten-second control gate. This is initialization research,
not a world-model or PPO policy improvement.

## Controlled Training Change

Both arms use the same incoming supervised preview checkpoints, train-only
normalization, original 36 teacher episodes, teacher implementation, network
architecture, action-space imitation loss, sampling seeds and optimizer budget.
The privileged BalanceTeacher is recreated for every student episode and
queried at each actual student state. Its 29 joint-action labels are stored
separately from the student's actual applied controls. Teacher state is not
an actor input or a proposed hardware sensing interface.

`clean` uses zero latent noise; `disturbed` uses standard deviation 0.005.
Noise is sampled before the existing tanh/residual/servo transform. Both arms
draw from the same per-case seeded stream, including the zero-noise arm.
Each episode has its own stream so a different preceding fall time cannot
shift later cases' random numbers. After weights or trajectories diverge,
this is a comparison of complete data/learning workflows rather than identical
state-by-state samples with one changed scalar.

Each seed receives four rounds, 18 complete train-family student episodes
per round, and 750 supervised Adam updates per round. Batch size is 128,
learning rate 0.0003 and gradient clipping norm 1. Half a batch comes from
the shared original teacher points; half comes from the latest 30,000
student-state points and their separately queried teacher labels. Existing
action loss and architecture remain unchanged. No critic or world model is fit.

Training cases are stand, independent pose goals and independently phased
joint sinusoids, each at friction 1.0/0.8/0.6. No canonical sway or wave episodes
fit weights. Reset seeds are `6000 + 10000 * policy_seed + 2 * round_index`
and the following integer. Noise streams start at
`11000 + 10000 * policy_seed + 100 * round_index`, offset by case/episode.
All incoming weights, teacher source and data hashes are retained.

The clean arm collects 55,700 actual transitions across 216 episodes, with
175 falls. The disturbed arm collects 54,440 across 216 episodes, with 173
falls. These are 110,140 new transitions and 432 new training episodes in
total, separate from the reused 16,909 teacher transitions. Both arms perform
3000 updates per seed. Different actual transition counts and host load mean
this is not a matched wall-clock or sample-efficiency claim.

## Selection And Independent Evaluation

The earlier selection used only held-out sway. This study freezes a broader
selection suite before training: nine train-family episodes with latent noise
0.005 at reset `6200 + 10000 * seed`, plus three held-out sway episodes at
validation seeds 30–32. These twelve trials rank checkpoints by fewer falls,
then longer mean survival, then lower mean joint RMSE. Every trial has equal
weight. Rounds 0–4 are eligible, including the incoming actor.

The fixed train-family selection audit never provides teacher labels or
optimizer inputs. It validates behavior under the training distribution;
it is not a held-out source-family generalization test. Initial selection
scores and incoming final/audit metrics agree between the two arms.

Final canonical evaluation uses fresh seeds 9600–9602 and stand/sway/wave,
nine ten-second trials. Independent train-family audits use another reset,
`6300 + 10000 * seed`, and coupled noise streams starting at
`13000 + 10000 * seed`, for latent standard deviations 0/0.005/0.05. Both
incoming and selected policies are checked. These later audit trajectories
are collected after selection and never fit or select weights.

| Arm / seed | Selected round | Final survival (s) | Final joint RMSE (rad) | Falls / 9 |
| --- | ---: | ---: | ---: | ---: |
| Clean / 0 | 0 | 7.2467 | 0.04944 | 6 |
| Clean / 1 | 1 | 7.6067 | 0.04610 | 3 |
| Clean / 2 | 0 | 7.3178 | 0.04792 | 3 |
| Disturbed / 0 | 2 | 6.8667 | 0.04905 | 6 |
| Disturbed / 1 | 1 | 7.4911 | 0.04659 | 3 |
| Disturbed / 2 | 1 | 7.4178 | 0.04721 | 3 |

Updating more seeds does not establish better final control. The disturbed
seed-zero actor regresses in canonical survival, while seed two improves.
Neither workflow achieves zero falls and mean RMSE ≤0.15 rad across all nine
trials; no longer-duration qualification follow-up is triggered. The canonical
motions remain a repeatedly inspected development suite, not a broad unseen
motion benchmark. No physical-robot execution is involved.

Independent audits give each actor nine train-family cases at one fresh reset;
the aggregate has 27 trials per arm/noise level. The incoming policies and
conditions are identical between arms:

| Audit latent std | Incoming survival (s) / falls | Clean selected survival (s) / falls | Disturbed selected survival (s) / falls |
| --- | --- | --- | --- |
| 0 | 6.8607 / 16 | 7.2667 / 12 | 7.8015 / 10 |
| 0.005 | 5.2696 / 22 | 6.1593 / 18 | 7.2030 / 13 |
| 0.05 | 2.4919 / 27 | 3.1059 / 27 | 3.4148 / 27 |

Disturbed supervision improves limited independent train-family robustness
relative to incoming actors and this clean-training control. Large-noise
episodes still all fall. These small, correlated actor/reset conditions do
not support a reliability estimate or broad motion-generalization claim.
Across six runs, 324 separate incoming/selected audit episodes are retained
in addition to training. No audit labels or transitions fit weights.

The selected disturbed actors are useful parents for a subsequent bounded
learning study, but more disturbed states alone do not establish stable control.
The next investigation should connect the remaining closed-loop failures to
teacher/student action errors in balance joints and the teacher's stateful
signals, before another increase in data or update budget. The reports retain
per-joint applied-versus-teacher RMSE on actual collected states; this is not
an independent action-prediction score because it includes collection noise
and each arm visits different states.

The subsequent [balance-channel intervention](G1_BALANCE_INTERVENTION.md)
replaces declared student channels with teacher feedback while keeping weights
fixed. Four ankle replacements complete the diagnostic canonical cells; the
full teacher also succeeds with ten error frames but fails without velocity
memory. These privileged interventions narrow the next feature/feedback study;
they do not qualify the learned actors or establish sensor-only equivalence.

## Evidence And Platform Integration

The [derived comparison](../output/research/g1-temporal-disturbance-study.json)
contains selection histories, independent audit outcomes, original/final control,
per-case falls, actual data counts, payload hashes and native validation results.
The completed study is `target/learning/g1-temporal-disturbance`.

All 24 training chunks and 36 separate audit chunks are parsed with the
canonical native MoonBit dataset reader. Although its output samples endpoints,
the reader validates every transition before sampling. Training chunks also
check episode identities, train-family membership, teacher-label and latent
lengths, and zero online/offline input alignment error. The numerical collector
checks each stored history/goal/preview against captured online inputs and
reconstructs every actual action from its saved latent sample with zero error.
Teacher labels are never substituted for the applied actions in those datasets.

`temporal-disturbance-clean` and `temporal-disturbance-disturbed` register in
MoonData with the distinct `moonrobo.g1-temporal-disturbance-fit.v1` producer
format. Each seals selected/latest temporal actors, canonical physics traces,
full student-training logs (`learning-supervised-physics`) and separate
independent audit logs (`learning-disturbance-audit`). The fixed compressed
collection payload represents only the first seed's first training batch;
the complete collection is in the per-seed logs. No dynamics report, critic
calibration or dummy world-model weights are attached.

The existing read-only host API/cockpit can inspect canonical final physics
and compare per-seed summaries. Noise audits remain sealed evidence refs,
without pretending they are the canonical trace returned by that route.
Registration and simulator qualification do not grant physical authority.

```sh
moon run scripts/fit_g1_temporal_disturbance.mbtx /absolute/path/to/moonrobo /absolute/path/to/moonrobo/target/learning/g1-temporal-input-study /absolute/path/to/moonrobo/target/learning/g1-temporal-disturbance-new
moon run --target native scripts/report_g1_temporal_disturbance.mbtx /absolute/path/to/moonrobo /absolute/path/to/moonrobo/target/learning/g1-temporal-disturbance-new /absolute/path/to/moonrobo/target/learning/disturbance-new-book/moondata /absolute/path/to/moonrobo/output/research/g1-temporal-disturbance-study-new.json
```

Use fresh study directories and, when reusing the reporter's fixed example IDs,
a fresh MoonData root. The pinned CPU environment, G1 model and built native
dataset/registry executables are prerequisites. The original teacher dataset
must be available at the declared raw source path. MoonBit scripts freeze
providers/configurations and own orchestration; numerical fitting remains in
the provider. No generic job framework, deployment runner or hardware path is
added. Stable all-case control, matched PPO efficiency and full phase/workbench/
E1 qualification remain incomplete.

Verification: 40 numerical tests, seven MoonData registration tests and three
host-projection tests pass. The new numerical regression checks teacher memory
reset, label/action separation, noisy previous-action history and split rejection.
The registry regression reopens training/audit bytes after removing the source.
All 60 actual data chunks pass native parsing, and full MoonData validation
has zero findings. `moon info`, scoped formatting and interface review complete;
no public MoonBit API is added by this producer extension.
