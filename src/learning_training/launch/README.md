# Native core workflow adapter

`cmd` accepts a reviewed provider descriptor followed by the original subcommand/options. A descriptor such as `policy.py` is an explicit dispatch key; its contents are never executed. Missing/duplicate/unsupported options and unknown descriptors fail. No interpreter discovery, Python fallback, SDK launch or automatic test execution exists.

The shared script entry is `scripts/run_native_learning.mbtx REPO src/learning_training/launch/cmd PROVIDER_DESCRIPTOR [ARGS...]`. It runs MoonBit natively with the repository as cwd and forwards stdout/stderr. Physical calls require `--library PATH` or `MOONROBO_MUJOCO_LIBRARY`; the original `--scene` remains explicit. Existing native build products used by dataset/registry scripts remain native prerequisites.

| Descriptor | Actual implementation |
| --- | --- |
| `dynamics.py` | `learning_training.run_dynamics`: real fit, normalization, selection, metrics, gradient probe, selected/latest save/reload |
| `policy.py fit` | `learning_training/physics.run_policy`, including independent model-training artifact validation, optional compatible policy replay, actual model/actor/critic updates and paired snapshots |
| `policy.py collect` | `collect_checkpoint`: actual runtime rollout, selected split, applied action noise, unique checkpoint-bound episodes, dataset and report |
| `policy.py evaluate` | `evaluate_checkpoint`: actual baseline/candidate physics, body validation, experiment/config/checkpoint binding, complete trial groups |
| `ppo.py` | `run_ppo` with separate collection/evaluation experiment and warm-start inputs |
| `behavior_cloning.py`, `dataset_aggregation.py` | `run_supervised`: original point labels / real privileged teacher labels, separate applied controls and final physics |
| `counterfactual.py`, `dynamic_refit.py` | `run_counterfactual` / `run_refit` with native artifact and reset/control contracts |
| `cpu_physics.py` | Actual `learning_physics/cli`; structured native child command, no shell or Python |
| `model_probe.py`, `critic_probe.py`, `actor_update_probe.py`, `paired_model_probe.py`, `dynamic_refit_probe.py`, `replay_direction_probe.py`, `teacher_step_verification.py` | Corresponding actual functions in `learning_probes/study`; no separately invented report |
| `compare_dynamics.py` | `learning_comparison.run` with shared initial prediction scale |

The 30 changed core entry scripts have their **complete original bytes** in `scripts/python_reference/` and immutable SHA receipts in `core-sources.json`. The additional report-only dynamic-refit filename migration is archived in `core-report-sources.json`. Original Python remains unchanged. New checkpoint outputs and script-declared payload names use `.moon.json`; explicit old Torch `.pt` inputs use the restricted existing loader. The adapter resolves an absent native/legacy input suffix to an existing counterpart. This is file-format compatibility, never an interpreter fallback.

Checkpoint copy operations call the explicit native command `checkpoint-copy SOURCE DESTINATION.moon.json residual-dynamics|g1-actor`. Exact existing inputs take precedence over suffix fallback. Native JSON is validated and copied byte for byte. Torch ZIP is decoded and converted through the restricted numeric checkpoint loader; its bytes are never renamed as JSON. Conversion writes a `.source.json` receipt with both source and destination SHA values and keeps the original bytes in a real `.pt` companion, so historical copied reports can still reference their original artifact. This inference conversion does not restore optimizer/RNG state and does not imply the converted file has the original SHA. Invalid formats/kinds fail before destination creation. Complete legacy workflow/report parity is still assessed by the preserved scripts and original sources.

Final policy/PPO/cloning/aggregation evaluation explicitly passes case scope `all`, matching the original `policy.evaluate_physics(split=None)`: the three canonical case IDs times three final seeds produce nine trials. Validation model selection still explicitly uses `validation`, and callers passing `test` to the library evaluator retain test-only behavior. Reports keep flat counted summaries for study ranking and nested `{summary,trials}` groups for checkpoint replay/score verification. No final qualification thresholds were loosened.

Original automatic unittest steps in policy/PPO orchestration now record that testing is deferred. They do not report a fake pass and do not launch replacement tests. A new real-runtime regression test source checks nine all-case trials versus three validation-only trials, but was not executed.

Three additional deferred regression sources cover exact native byte copies and exact-path priority, actual `.pt` suffix resolution with malformed Torch rejection before output, and unsupported copy kinds/destinations. Probe, refinement and calibration output directory creation accepts pre-existing wrapper-created directories, matching the original `exist_ok=True` behavior.

Only filesystem editing/archival automation and static checks ran in this migration. All 30 core script sources passed `moon check` before final schema refinements; the adapter passed scoped checking before another concurrently authored package temporarily blocked dependency checks. Final coordinated checks are recorded by the workspace audit. No workflow, test, simulator, training, probe or exporter was executed. Float64/RNG/reduction and native report/checkpoint distinctions remain documented in the parent `MIGRATION.md`; native routing does not establish Python numerical equivalence.
