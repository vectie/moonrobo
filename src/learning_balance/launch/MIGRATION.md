# Native balance and temporal workflow launchers

The historical workflow launchers are preserved byte for byte in
`scripts/python_reference/`. Their original SHA256 values are bound by
`temporal-balance-sources.json` (38 files) and
`replay-directions-sources.json` (one additional file). Those copies are the
explicit Python reference route for later paired retesting. Python provider
sources are unchanged.

Current workflow scripts call `scripts/run_native_learning.mbtx`, which runs
reviewed MoonBit executables with literal argument arrays and the repository as
working directory. A historical `.py` name passed to `learning_balance/launch`
is an inert dispatch descriptor, never an executable filename. Unknown
providers fail. There is no interpreter discovery or implicit Python fallback.
Native simulation requires `--library` or `MOONROBO_MUJOCO_LIBRARY`; scene paths
retain the original workflow argument. New checkpoints use `.moon.json`.
Existing `.pt` model inputs are read only by the restricted native Torch
state-dictionary importer. Four workflow model-copy loops use
`learning_training/launch/cmd checkpoint-copy`: conversion is real and records
source identity, rather than renaming pickle bytes to JSON filenames.

## Dispatch and actual implementations

| Historical provider descriptor | Native implementation |
| --- | --- |
| balance_teacher.py diagnose/fit/evaluate/collect/develop | learning_balance/teacher_study.run |
| balance_teacher_long_fit.py | learning_balance/teacher_study.run_long |
| learned_balance_study.py, learned_balance_long.py | learning_studies.run_learned_study/run_learned_long |
| sustained_balance_study.py | learning_studies.run_sustained |
| sustained_balance_verify.py | learning_balance/verification.run |
| balance_intervention.py, balance_long_intervention.py | learning_balance/intervention.run/run_long |
| balance_feature_study.py | learning_balance/feature_study.run |
| temporal_training.py collect-teacher/fit/evaluate | learning_temporal/physics.run_supervised_study |
| temporal_disturbance.py | learning_temporal/physics.run_disturbance_study |
| temporal_ppo.py | learning_temporal/physics.run_ppo_study |
| temporal_refinement.py, temporal_value_training.py | learning_refinement.run_refinement/run_value_training |
| temporal_ppo_noise.py | learning_calibration.calibrate_noise |
| temporal_ppo_verification.py | learning_calibration/verification.verify |
| temporal_probe.py, replay_direction_probe.py | learning_probes/study.run_temporal_probe/run_replay_direction |
| policy.py, dynamics.py, cpu_physics.py, compare_dynamics.py, teacher_step_verification.py | learning_training/launch/cmd reviewed native dispatch |

The new temporal supervised driver retains train-only teacher data, zero-adapter
checks on both recorded inputs and actual validation closed-loop traces,
per-reset reference schedules, separate teacher labels, mixed old/recent
batches, validation-only selection including zero, latest/selected save and
reload, independent test evaluation and position-controller baseline.
Disturbance retains independent per-case/reset noise streams, held-out-family
rejection, fixed training audit plus validation selection, independent final
noise audits and all real physics records. PPO retains separate declared
noise/optimizer seeds, finite per-episode physical returns, causal input and
behavior-latent reconstruction checks, actual reward/continuation/visitation
logs, full-batch KL stopping, paired actor/value selection and reload, and
frozen normalization checks. Fall thresholds are explicit through collection.
Every dynamic dataset retains the actual reference offset/schedule. Reading
legacy data uses those stored arrays and never substitutes native RNG output.
Actor checkpoints carry the true parent model_ref/base_config, standard
initialization provenance and the actual selected/latest update number;
missing model identity is rejected rather than skipping model binding.
PPO loads `initial-value-seed-N.moon.json` paired with the exact incoming
supervised actor SHA; a selected-output value checkpoint is never substituted.

Teacher JSON now identifies `provider_source` and `source_language=moonbit`;
studies hash that actual source. Native reports bind their implementation to
its actual MoonBit source, independently of archived Python snapshots. Export
registration uses the export metadata's actual `provider_snapshot`, retaining
the old `.py` snapshot gate only for legacy metadata.

## Original workflow file mapping

All filenames below are under `scripts/`; unchanged pure MoonBit workflow
steps still retain their original report/coverage/numerical assertions.

| Original workflow | Current path |
| --- | --- |
| fit_g1_balance_teacher.mbtx | native teacher phases |
| collect_g1_balance_teacher.mbtx | native teacher evaluation/collection and native CPU baseline |
| fit_g1_balance_teacher_long.mbtx | native long teacher fit |
| fit_g1_temporal_inputs.mbtx | native teacher collection and supervised temporal fitting |
| fit_g1_temporal_disturbance.mbtx | native clean/disturbed studies |
| fit_g1_temporal_ppo.mbtx | native actual-physics PPO study |
| fit_g1_temporal_value.mbtx | native finite-value refinement; validated model copies |
| fit_g1_teacher_value.mbtx | native teacher-direction value refinement; validated model copies |
| refine_g1_temporal_inputs.mbtx | native refinement; validated model copies |
| calibrate_g1_temporal_ppo_noise.mbtx | native noise calibration |
| probe_g1_temporal_inputs.mbtx | native temporal probe |
| probe_g1_replay_directions.mbtx | native replay-direction probe |
| probe_g1_balance_intervention.mbtx | native intervention |
| probe_g1_balance_long_intervention.mbtx | native long intervention |
| verify_g1_balance_features.mbtx | native feature verification/control |
| verify_g1_learned_balance_long.mbtx | native long learned evaluation |
| fit_g1_learned_balance.mbtx | native learned study |
| fit_g1_sustained_balance.mbtx | native sustained study |
| fit_g1_sustained_policy.mbtx | native dynamics/base-policy fitting; validated model copies |
| verify_g1_sustained_policy.mbtx | native model comparison and policy evaluation |
| report_g1_temporal_inputs.mbtx | MoonBit report plus native base-policy evaluation |
| report_g1_temporal_ppo.mbtx | MoonBit report plus native numerical verification/evaluation |
| report_g1_teacher_value.mbtx | MoonBit report plus native teacher-step/evaluation |
| report_g1_teacher_initialization.mbtx | MoonBit report plus native policy evaluation |
| report_g1_temporal_value.mbtx | MoonBit report; canonical native checkpoint paths |
| report_g1_temporal_disturbance.mbtx | MoonBit report; actual native source identity |
| register_g1_learned_balance.mbtx | MoonBit registration; actual provider snapshot identity |
| register_g1_sustained_balance.mbtx | MoonBit registration; actual provider snapshot identity |
| build_g1_sustained_replay.mbtx | existing MoonBit replay-data builder |
| verify_g1_balance_views.mbtx | existing MoonBit view verification |
| score_g1_temporal_probe.mbtx | existing MoonBit probe scoring |
| export_g1_learned_balance.mbtx | delegated aligned-agent native exporter/registry adapter |
| export_g1_sustained_balance.mbtx | delegated aligned-agent native exporter/registry adapter |
| report_g1_learned_balance.mbtx | delegated aligned-agent native report adapter |
| report_g1_sustained_balance.mbtx | delegated aligned-agent native report adapter |
| report_g1_balance_teacher_long.mbtx | delegated aligned-agent native report adapter |
| report_g1_balance_intervention.mbtx | delegated aligned-agent native report adapter |
| report_g1_balance_long_intervention.mbtx | delegated aligned-agent native report adapter |
| report_g1_balance_features.mbtx | delegated aligned-agent native report adapter |

## Verification boundary

Only source archival/transformation and static compilation/format/interface
checks have been performed. No tests, simulation, training, noise calibration,
SDK execution, export or registry import was run. Float64 MoonBit arithmetic
and xorshift32/Box–Muller streams differ from PyTorch Float32/RNG. Checkpoint
reload and zero-adapter checks are runtime contracts in the translated code,
not evidence that they have already executed. Original fixed numerical report
gates remain; a future native run that differs must fail visibly, and those
gates have not been relaxed to manufacture parity.
