# G1 Balance Channels And Teacher Memory Interventions

Updated: 2026-10-23. This follows the [disturbance initialization study](G1_DISTURBANCE_INITIALIZATION.md).
Replacing the four ankle outputs with privileged teacher feedback lets all
18 canonical actor-condition cells complete ten seconds, versus eight falls
for the unchanged learned actors. A full teacher with ten error frames also
completes those conditions; removing its velocity memory fails every one.
These are causal simulation diagnostics, not newly qualified learned policies.

## Frozen Actors And Control Changes

The parents are the three selected H10/F10 actors from
`target/learning/g1-temporal-disturbance/disturbed/policy`. Weights and
normalization remain unchanged throughout. The exact archived privileged
BalanceTeacher source and selected parameters are hash-checked. No model,
policy, critic or parameter search is trained in this experiment.

Eight variants are fixed before running:

| Mode | Applied control |
| --- | --- |
| `student` | Original learned actor, without added exploration noise |
| `ankle` | Teacher replaces left/right ankle pitch and roll; actor controls the other 25 joints |
| `ankle_waist` | Teacher replaces those four plus waist pitch |
| `lower` | Teacher replaces twelve hip/knee/ankle channels |
| `teacher` | Full original teacher on all 29 joints |
| `teacher_no_memory` | Full teacher with no retained error frames; filtered velocity is zero |
| `teacher_h10` | Full teacher with its filter recomputed from the latest ten error frames |
| `teacher_h50` | Full teacher with its filter recomputed from the latest fifty error frames |

Teacher and actor both receive the actual trajectory's observation and current
goal once per control step. The actor's history includes the previously applied
hybrid action. It does not follow an unrelated prerecorded student trajectory.
Each teacher instance resets at every episode. Scalar errors from all teacher
variants are also measured as shadows on the same visited physical states.
Only the declared mode chooses the applied control.

The teacher's EMA uses world-horizontal COM-minus-support error differences,
with retention 0.8 and new-difference weight 0.2. A window of N error frames
has N−1 finite differences and zero filter state at its oldest retained frame.
Thus H10 retains nine differences; H50 retains forty-nine. A one-frame window
preserves COM, bias, joint damping and limits, while removing filtered velocity.
The window wrappers do not change the original teacher implementation.

For each actor/mode, nine train-family cases run at reset
`6500 + 10000 * policy_seed`, followed by stand/sway/wave at reset seeds
9700 and 9701. Every episode has a ten-second cap and the existing fall
thresholds. These canonical motions are a development diagnostic suite, not
new source-family generalization or the full nine-trial qualification suite.

There are 24 cells and 360 recorded episodes with 147,557 transitions: 216 train-family and 144
canonical-development episodes. Another 36 direct canonical repeats compare
the student and full teacher with their shadow-instrumented counterparts;
their physical transition arrays match exactly. They are verification work,
separate from the 360 recorded probe episodes. No episodes fit weights.

## Closed-Loop Outcomes

| Mode | Canonical falls / 18 actor-condition cells |
| --- | ---: |
| Student | 8 |
| Four ankle channels | 0 |
| Ankle plus waist pitch | 1 |
| Twelve lower-body channels | 2 |
| Full teacher | 0 |
| Teacher without velocity memory | 18 |
| Teacher with ten error frames | 0 |
| Teacher with fifty error frames | 0 |

Teacher-only modes ignore actor identity. Their eighteen cells therefore
repeat the same six unique case/reset conditions for three unused actor
parents. The reporter checks identical physical step hashes for those repeats;
they must not be counted as eighteen independent teacher trials. Hybrid modes
still depend on each actor. All conditions are small and correlated; this is
not a reliability estimate or statistical significance test.

Adding more teacher channels is not uniformly better. One ankle-plus-waist
cell falls; two lower-body cells fall close to the time cap. Four-ankle
replacement supports this narrow causal conclusion: at these conditions,
replacing learned ankle feedback suffices to remove observed canonical falls.
It does not identify a universally optimal joint partition or establish that
other channels are irrelevant. Train-family failures remain even with the
full teacher, so its own coverage is also limited.

The finite-memory comparison establishes that velocity feedback matters for
this teacher, while ten error frames suffice for these canonical conditions.
It does not prove that the neural actor can reproduce the same feedback from
its H10 proprioception. Teacher error frames still contain privileged COM and
foot-support geometry; they are not the actor's observation frames. Longer
memory alone is therefore not the first supported remedy for the current
student failure.

## Same-State Error Diagnostics And Next Step

The [comparison report](../output/research/g1-balance-intervention-study.json)
pools action differences on the unchanged students' physical trajectories,
separately for train and canonical conditions. It reports student/full-teacher
and 1/10/50-frame/full-teacher action RMSE for ankle, ankle-plus-waist, lower,
other and all joints. Pooling weights each observed physical state equally.
These shadow errors compare the same states; the intervention outcome table
instead measures each changed controller's own resulting trajectories.

| Same-state action RMSE against full teacher | Train / 7233 states (rad) | Canonical / 6563 states (rad) |
| --- | ---: | ---: |
| Student, four ankle channels | 0.11564 | 0.09700 |
| Student, other channels excluding ankle/waist pitch | 0.00224 | 0.00069 |
| No-memory teacher, ankle channels | 0.09739 | 0.08637 |
| H10 teacher, ankle channels | 0.01433 | 0.01163 |
| H50 teacher, ankle channels | 0.00000239 | 0.00000135 |

The large student/full-teacher ankle discrepancy remains on identical observed
states, so it is not solely an artifact of comparing two controllers' different
rollouts. Values include pre-fall states and are correlated within episodes;
they locate the current error without proving a unique learning remedy.

The complete source log also retains per-episode/per-joint shadow errors and
pre-step samples every 0.1 seconds plus the last pre-step sample: root height,
uprightness, body-relative COM error, full/H10 filtered velocity and ankle/waist
commands. Full physical state/action transitions remain in the canonical
dataset, including final next states. A sampled pre-step trace must not be
interpreted as an extra physical step or a complete measurement stream.

The next bounded implementation should first verify whether body-relative
COM/support features can be reconstructed from available joint positions,
projected gravity and known robot geometry. A causal velocity estimate then
needs its own comparison against the privileged signal. Only verified
observation-derived features should enter a new learned ankle-feedback study.
This tests the information/representation gap before another increase in
history, data volume or update count. It does not authorize an oracle-based
hardware runner or replace the learned-control acceptance gate.

The subsequent [observation-feature study](G1_OBSERVATION_BALANCE_FEATURES.md)
now validates exported differentiable FK against native poses and recorded
states. Gravity/gyro transport greatly reduces average velocity error, with
rare large errors retained. Observation-derived fixed ankle feedback closely
matches the privileged H10 comparator at new resets; both still fail six of
27 canonical actor-condition cells. No new learned policy is qualified.

## Evidence And Reproduction

The completed source directory is `target/learning/g1-balance-intervention`.
It stores the frozen charter, provider sources, parent/teacher digests, scalar
report and a SHA-256-bound `intervention-physics.jsonl.gz` with all 24 datasets,
trials and sparse measurements. Actor state/normalization integrity and direct
canonical baseline equivalence are verified by the numerical worker.

The reporter natively parses every dataset, checking all 360 episode identities,
trial/transition counts, timing, termination labels and physical trace binding.
The native reader validates the entire dataset before selecting the `train`
split's endpoint output, so validation covers canonical validation/test episodes
as well. Runtime trial IDs gain a policy/mode/scope suffix in the dataset; the
reporter checks that exact binding rather than assuming the raw IDs are equal.
These mixed datasets preserve train/validation/test family membership. They
must not be bulk-loaded as training data merely because the probe itself has
no optimizer.

The probe does not register a trained candidate, write new weights, select a
variant for deployment or update physical authority. Its raw diagnostics remain
local research evidence; previously registered parent policies remain unchanged.
No generic artifact framework or new public MoonBit API is introduced.

```sh
moon run scripts/probe_g1_balance_intervention.mbtx /absolute/path/to/moonrobo /absolute/path/to/moonrobo/target/learning/g1-temporal-disturbance /absolute/path/to/moonrobo/target/learning/g1-temporal-input-study /absolute/path/to/moonrobo/target/learning/g1-balance-intervention-new
moon run --target native scripts/report_g1_balance_intervention.mbtx /absolute/path/to/moonrobo /absolute/path/to/moonrobo/target/learning/g1-balance-intervention-new /absolute/path/to/moonrobo/output/research/g1-balance-intervention-study-new.json
```

Use a fresh probe directory. The pinned CPU environment, G1 model and built
native numeric reader are prerequisites. Forty-two numerical tests pass,
including finite-window EMA/reset and selective-action substitution checks;
five native motion-data tests pass. Scientific evidence additionally comes
from the actual closed-loop rollouts and native source parsing.
`moon info`, scoped script formatting and interface review complete; this
diagnostic introduces no public MoonBit API changes.

To make room, completed early policy-feedback/round-2/round-3/warm-native
validation/test batch JSON files were losslessly archived as `.json.gz`.
Weights, reports and registered BlobStore evidence remain intact. Restore an
old raw path with `gzip -d` before a workflow that still requires it. Stable
learned all-case control, matched efficiency, full workbench/E1 and physical
qualification remain unfinished.
