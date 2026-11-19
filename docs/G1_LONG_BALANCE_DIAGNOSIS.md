# Long Balance Diagnosis And Training-Only Teacher Refit

Updated: 2026-10-23. The long-duration failures are not primarily a failure to
imitate the existing ankle controller: precise ankle substitution and the
complete original privileged teacher both still fall. A subsequent eight-cell
training-family search produces a stronger privileged teacher that completes
all 36 new thirty-second audit/canonical trials. Learned policies have not yet
received this improvement.

## Frozen Channel And Feature Diagnosis

The [configuration](../examples/learning/g1-balance-long-intervention.json)
freezes five parent-dependent modes, wave resets 9900/10000, and the three
joint-sine cases at reset `6600 + 10000 * parent_seed`. Each mode uses the same
three frozen full-memory composite policies. Complete teacher control runs the
two unique wave conditions once, not once per irrelevant actor parent, and all
nine unique sine conditions. There is no fitting or checkpoint selection.

The [verified report](../output/research/g1-balance-long-intervention-study.json)
retains 86 episodes and 40,834 actual transitions. All six previously recorded
learned wave episodes and all nine learned sine episodes/prefixes reproduce
exactly, despite the added shadow queries. Actor/head weights remain unchanged.

| Mode | Wave falls / trials | Wave survival (s) | Sine falls / trials | Sine survival (s) |
| --- | ---: | ---: | ---: | ---: |
| Learned full-memory ankle | 6 / 6 | 11.8800 | 9 / 9 | 7.7956 |
| Observation-derived fixed ankle | 6 / 6 | 11.8100 | 9 / 9 | 7.8933 |
| Exact privileged teacher ankle | 6 / 6 | 11.8200 | 9 / 9 | 7.9444 |
| Teacher ankle plus waist pitch | 6 / 6 | 11.7533 | 9 / 9 | 9.1822 |
| Teacher twelve lower-body channels | 6 / 6 | 10.8433 | 9 / 9 | 7.5400 |
| Complete original teacher | 2 / 2 | 11.4600 | 9 / 9 | 9.1022 |

Other channels remain the parent's outputs on each actual trajectory in the
partial substitutions. More teacher channels do not monotonically improve
control. A complete teacher failure removes the frozen parent from that trial,
but does not prove that a reference motion is physically infeasible.

On the learned wave trajectories, first-ten-second same-state ankle RMSE is
5.94e-5 rad for the learned head and 1.34e-5 rad for fixed observation-derived
feedback, against the privileged teacher. Transported-velocity RMSE is
4.13e-7 m/s. After ten seconds these errors increase near falls, but precise
oracle ankle control fails at almost the same mean time. Small average feature
errors are not a stability certificate, and approximation errors are not the
only remaining control problem.

The fraction of ankle command components at the ±0.3-rad residual cap rises
from 11.7% before ten seconds to 42.5% afterward on these learned wave states.
Both complete-teacher wave trials reach 50% after ten seconds. This describes
command saturation, not actuator torque saturation. It motivates a bounded
control-authority comparison; saturation alone would not prove causation.

## Train-Only Thirty-Second Parameter Search

The [search configuration](../examples/learning/g1-balance-teacher-long-fit.json)
is fixed before running eight combinations of residual bound 0.3/0.45 rad,
angle gain 0/1 and angular-rate gain 0/0.25. All other original teacher settings
remain unchanged: COM gain 16, filtered-velocity gain 32, pitch bias 0.2 rad,
waist share 0.25, joint damping 0.02 and hip share zero. These are existing
`BalanceTeacher` knobs, not a new state estimator or neural policy.

Each candidate runs the nine training cases at resets 6700/6701 for thirty
seconds. The predeclared ordering prefers fewer falls, then longer mean
survival, then lower mean joint RMSE. Canonical cases and new audit resets are
not evaluated until the selected teacher and search digest are written.

| Bound (rad) | Angle gain | Rate gain | Train falls / 18 | Mean survival (s) | Joint RMSE (rad) |
| --- | ---: | ---: | ---: | ---: | ---: |
| 0.30 | 0 | 0 | 9 | 19.7044 | 0.042760 |
| 0.30 | 0 | 0.25 | 9 | 19.8133 | 0.042664 |
| 0.30 | 1 | 0 | 15 | 11.7544 | 0.047527 |
| 0.30 | 1 | 0.25 | 15 | 11.9944 | 0.046947 |
| 0.45 | 0 | 0 | 0 | 30.0000 | 0.037502 |
| 0.45 | 0 | 0.25 | 0 | 30.0000 | 0.037526 |
| 0.45 | 1 | 0 | 0 | 30.0000 | 0.037426 |
| 0.45 | 1 | 0.25 | 0 | 30.0000 | 0.037410 |

The winner is cell seven: bound 0.45, angle gain 1 and rate gain 0.25. All four
0.45 cells complete the training conditions; their tracking differences are
small. Only the preselected winner receives the independent comparison below.
This does not establish that angle/rate feedback is necessary outside training,
nor that 0.45 is an optimal or universally sufficient bound. The global bound
also affects the coupled waist correction, so this is not an isolated
four-ankle clamp ablation.

## Fresh Evaluation Of Original And Selected Teachers

New training-family audit resets are 6800–6802, giving 27 trials per teacher.
New canonical resets are 10100–10102, giving nine stand/sway/wave trials. Both
controllers run the same conditions after selection, with all 72 physical
episodes retained. The [verified teacher report](../output/research/g1-balance-teacher-long-study.json)
binds the complete selection table and evaluation archives.

| Scope / controller | Falls / trials | Mean survival (s) | Mean joint RMSE (rad) |
| --- | ---: | ---: | ---: |
| Training-family audit / original | 12 / 27 | 20.4289 | 0.042568 |
| Training-family audit / selected | 0 / 27 | 30.0000 | 0.036746 |
| Canonical / original | 3 / 9 | 23.7844 | 0.038908 |
| Canonical / selected | 0 / 9 | 30.0000 | 0.035995 |

The original teacher fails all nine sine audits, three pose-offset audits and
all three wave trials. The selected teacher completes every observed condition.
These are fresh resets of repeatedly studied procedural families, not a new
unseen-motion benchmark or hardware qualification. The teacher remains
privileged and handcrafted; no learned policy weights are updated or qualified.

The search runs 144 actual episodes and 164,940 transitions in 36.38 s of local
provider time. Every search trial's scalar score/counts are retained; search
states are not retained as a training corpus. Complete evaluation transitions
are retained separately: the 72 evaluation episodes contain 92,282 transitions.
Total search/evaluation/serialization time is 72.90 s.
These timings do not include previous teacher/parent development and do not
establish a learning-efficiency advantage.

## Artifacts And Next Work

Study directories are `target/learning/g1-balance-long-intervention` and
`target/learning/g1-balance-teacher-long-fit`. Both archive config, charter and
provider sources. The latter's `teacher.json` contains the train-selected
parameters and original teacher implementation hash; it does not overwrite
the old teacher or registered learned checkpoints. These remain local research
diagnostics rather than new learned-policy registrations.

All sixteen intervention datasets and all eight teacher-evaluation datasets
pass the native reader across all splits. The teacher verifier independently
checks the eight-cell grid, all 144 training-only selection trials and the
selection ranking. Forty-eight provider tests pass. Source/model provenance
and action semantics remain tied to the pinned G1 CPU setup.

```sh
moon run --target native scripts/probe_g1_balance_long_intervention.mbtx REPO FIT_STUDY LONG_STUDY FRESH_DIAGNOSIS
moon run --target native scripts/report_g1_balance_long_intervention.mbtx REPO DIAGNOSIS OUTPUT_JSON
moon run --target native scripts/fit_g1_balance_teacher_long.mbtx REPO FIT_STUDY FRESH_TEACHER_STUDY
moon run --target native scripts/report_g1_balance_teacher_long.mbtx REPO TEACHER_STUDY OUTPUT_JSON
```

The subsequent [sustained distillation](G1_SUSTAINED_BALANCE_DISTILLATION.md)
collects fresh training trajectories and compares range, pose/rate and waist
variants. Its selected four-ankle 0.45-rad law completes all 54 final thirty-second
learner checks without explicit pose/rate or waist replacement. Earlier
audit/canonical records remain excluded from fitting. Later world-model/PPO
comparisons must share the revised action mapping and initializer.
Long learned-policy control, matched world-model/PPO refinement, workbench, E1
and hardware phases remain unfinished.
