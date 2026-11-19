# Original-method audit: source coverage and deferred differential evidence

This is the historical source-coverage inventory from initial migration.
Native execution status changed on 19 November 2026: the independent Float64
suite and native physics/data/protocol contracts now execute. See
[README.md](README.md) and [native validation](../../docs/NATIVE_TESTING.md).
The original-upstream execution requirements in this audit remain distinct;
historical statements about unrun native tests are not the current result.

This audit covers **9 retained Python test files, 54 original test methods**. Exactly **27 methods** have named entries in `contracts.mbt`: 9 data, 5 MDP differential, 4 learning differential and 9 Isaac protocol cases. The other 27 methods are native unit, evaluation, resume and MuJoCo contract tests; they are not silently counted as additional differential case IDs. Several native test blocks combine original methods, so test-block counts and original-method counts are different measures.

**No test, Python function, random fixture, training loop, simulator, SDK or differential oracle was executed for this migration. No passing original-upstream differential result is claimed.** Type checking, C/C++ syntax checking and source review are static evidence only.

The implementation paths below are relative to `src/learning_aligned/`, unless prefixed with `differential/` (meaning this `src/learning_differential/` package). Original paths are relative to `providers/motion_learning/`. Native tests are authored source and remain unexecuted. Read the implementation's generated interfaces for precise current API signatures.

## Evidence boundaries

- **Native source contract**: a test invokes the actual MoonBit production type/function and asserts the translated behavioral contract. This establishes source coverage, not that its assertions have passed.
- **Independent native comparison route**: a candidate adapter invokes actual MoonBit SUT code; a separate mathematical or ATen/LibTorch implementation supplies a reference. The latter is a separately authored translation of pinned source equations, not execution of the sibling Python functions.
- **Executed-upstream fixture**: an external producer must have actually executed the original Python functions and exported source-bound inputs/results. This task supplies a strict import/verification path but did not execute such a producer or produce such an artifact. A manifest label alone is not a numerical result.
- **SDK protocol source**: native callbacks/fixed device batches can test the original CPU protocol and mock behavior. This is separate from a genuine Isaac/Kit/Newton/PhysX/CUDA/USD adapter and its integration execution. The original nine Isaac tests themselves use CPU mocks; neither those mocks nor native protocol fixtures are GPU physics evidence.
- **Real MuJoCo source fixture**: the pending test uses real native MuJoCo, not substitute dynamics. Matching headers/library, acquired scene and motion data are execution prerequisites; they have not been exercised here.

The canonical learning backend uses Double arrays and `vectie/moonnum`. The original learning differential fixtures use Torch Float32. Candidate learning outputs truthfully retain `<f8>`; an ATen/upstream `<f4>` fixture fails the strict dtype gate. There is no dtype relabeling, cast-based pass or claim that native Float64 training reproduces Float32 Adam trajectories. Exact RNG identities require fixed draws/permutations or the explicitly supplied ATen RNG route; equal integer seeds on the native RNG do not establish Torch draw identity.

## Inventory

| Retained original file | Methods | Named differential contracts | Native source area |
| --- | ---: | ---: | --- |
| `test_aligned_data.py` | 9 | 9 | `data_mdp_wbtest.mbt`, motion/sampling; differential data adapters |
| `test_aligned_mdp.py` | 6 | 0 | `data_mdp_wbtest.mbt`, `physics/physics_wbtest.mbt` |
| `test_aligned_mdp_differential.py` | 5 | 5 | differential MDP adapters and native MDP/AD/FK |
| `aligned/test_aligned_learning.py` | 7 | 0 | `cpu_contracts_wbtest.mbt`, native learner/replay/export |
| `aligned/test_aligned_evaluation.py` | 9 | 0 | `aligned_wbtest.mbt`, `cpu_contracts_wbtest.mbt` |
| `aligned/test_aligned_resume.py` | 1 | 0 | `physics/physics_wbtest.mbt`, training/checkpoint |
| `aligned/test_aligned_physics.py` | 4 | 0 | `physics/physics_wbtest.mbt`, native physics environment |
| `aligned/test_smc_learning_differential.py` | 4 | 4 | differential architecture/learning/replay adapters |
| `aligned/test_aligned_isaac.py` | 9 | 9 | `gpu_protocol/`, strict captured-protocol schema |
| **Total** | **54** | **27** | |

## Data: 9 methods

| Original method in `test_aligned_data.py` | Case ID | Actual native SUT / test mapping | Evidence still missing |
| --- | --- | --- | --- |
| `test_resampling_velocity_goals_and_end_bins` | `data.resampling` | `MotionLibrary::new/future_frames/goal`, `ReturnBinSampler::sample`; `data_mdp_wbtest.mbt` test “parent data resampling velocity goals terminal bins and full horizon resets” | Native assertion execution; registered fixture can carry shape/range evidence, but no original executed fixture was created |
| `test_duplicate_bin_update_is_order_independent_and_checkpoint_exact` | `data.duplicates` | Sampler `update/probabilities/snapshot/restore`; “parent data duplicate bin completions commute and checkpoint draw stream is exact” | Native RNG snapshot equality is implemented; original Torch draws and original executed fixture remain deferred |
| `test_timeout_bootstrap_and_real_terminal` | `data.bootstrap` | Same sampler test separately checks nonterminal bootstrap `0.04` and terminal `0.03` | No execution; Float32 original tolerance is distinct from the tighter native unit assertion |
| `test_manifest_hash_verification_and_split_identity` | `data.manifest` | `load_motion_manifest`, actual temporary CSV bytes/SHA/split and tamper rejection in `data_mdp_wbtest.mbt` | Async test/fixture writes were not run |
| `test_reference_only_export_skips_fk_without_changing_goal_features` | `data.reference_only` | Actual `MotionLibrary::new(compute_body_features=false)` with deliberately unusable FK tree; same goals as full loading | Source contract exists; no original or native fixture execution |
| `test_all_40_acquired_sources_match_frozen_catalog` | `data.catalog40` | Actual `parse_motion_csv` and source-byte verification in “parent acquired catalog verifies all forty original sources and 264705 rows”; `differential/candidate_data.mbt::verify_catalog40` | Requires complete acquired manifest/40 CSV files; no catalog execution in this task. Catalog SHA validation alone is not SMC numerical execution |
| `test_real_clip_reference_states_and_goals_against_smc` | `data.real_clips` | `candidate_motion_fields` calls actual `MotionLibrary`; exports all listed states/local velocities/frame indices/goals. Separate native mathematical resampling/rotation oracle | The original method executes actual sibling SMC for three named real clips. That Python execution and trusted three-clip artifacts remain missing; one supplied raw-clip comparison is not a completed three-clip suite |
| `test_reset_mixture_and_unique_return_updates_match_actual_smc_method` | `data.reset_mixture` | Actual `ReturnBinSampler::sample/update`, optional explicit batched ATen draw callback in `candidate_reset_mixture`; native equation test also exists | Independently transcribed mixture and actual ATen RNG do not execute SMC's AST-extracted `TrackingSim.sample_frames`. Original-method fixture and equality result remain deferred |
| `test_terminal_only_bins_are_explicit_upstream_bug_fix` | `data.terminal_fix` | Actual corrected `MotionLibrary` reset bins and sampler; independent source-equation path preserves upstream terminal-only bin behavior | No execution of either branch; the contract intentionally records a documented difference rather than demanding equality of a bug and its fix |

The first five data cases have direct native unit test sources and strict fixture/capture contracts. Do not infer a per-case native mathematical producer or original Python fixture merely from their registration in `contracts.mbt`.

## Native MDP contracts: 6 methods

| Original method in `test_aligned_mdp.py` | Actual native SUT / test mapping | Boundary |
| --- | --- | --- |
| `test_observable_input_resolves_translation_and_heading_ambiguity` | `observation` modes; “parent MDP observation modes resolve translation and heading with exact prefixes” | Native contract source; no executed differential result |
| `test_default_pose_scaled_action_has_no_reference_or_ankle_override` | `action_to_setpoint`/pullback; “parent MDP scaled default action and its pullback have no reference override” | Native values/derivative source only |
| `test_relative_termination_allows_matching_low_and_sideways_reference` | `termination/soft_termination` and AD; “parent MDP reference-relative low sideways failure and survival derivatives” | Native contract source only |
| `test_all_reward_terms_and_paper_scales` | Actual reward terms, rate/limit penalties; “parent MDP reward scales errors smoothness and joint limits” | Native analytic source assertions; not an upstream oracle run |
| `test_fk_pose_velocity_and_gradient_against_mujoco` | Actual `Kinematics::forward` and reverse FK versus MuJoCo world poses, Jacobian velocities and native finite differences in “parent MDP FK poses velocities and joint pullbacks match real MuJoCo” | Real scene/library required; unexecuted |
| `test_rotation_distance_gradient_and_vertical_heading` | Actual SO(3) angle/pullback/yaw in “parent MDP rotation zero tiny-angle derivative and vertical heading fixes” | Corrected native-side contract source; no execution |

## MDP upstream differential: 5 methods

| Original method in `test_aligned_mdp_differential.py` | Case ID | Actual candidate implementation | Independent route and remaining evidence |
| --- | --- | --- | --- |
| `test_head_values_and_gradients_match_smc_away_from_rotation_singularities` | `mdp.heads` | `candidate_mdp("mdp_heads")` calls actual observation, reward, termination, critic features and `reward_pullback` | Separate ATen original equations plus fixed input uniforms; not imported SMC Python. Original Float64 fixture, source RNG/noise outputs and execution remain missing |
| `test_observation_modes_have_exact_upstream_prefix` | `mdp.observation_modes` | Actual Paper/Smc/Observable mode prefixes and dimensions | Native comparison can check exact prefixes against independent math; original sibling function was not executed |
| `test_fk_matches_actual_upstream_for_all_tracked_bodies` | `mdp.fk` | Actual `Kinematics::forward` using fixed source-bound topology/tracked indices | Separate FK math and real-MuJoCo unit source exist. Neither constitutes execution of original SMC `G1Kinematics.forward` |
| `test_matrix_quaternion_values_and_pullback_match_upstream` | `mdp.quaternion` | Actual `quaternion_pullback` for the five prescribed rotation vectors | Separate ATen rotation/autograd reference; original exact value/gradient fixture and comparison remain deferred |
| `test_documented_rotation_fixes_remove_upstream_floor_and_vertical_collapse` | `mdp.rotation_fixes` | Actual corrected angle/pullback and vertical yaw; upstream fields come from the separate old-equation oracle, never the corrected SUT | This is a correction contract: zero upstream derivative/floor and collapsed upstream heading are expected differences. No original upstream execution was performed |

## Native learner: 7 methods

| Original method in `aligned/test_aligned_learning.py` | Actual native SUT / test mapping | Boundary |
| --- | --- | --- |
| `test_gae_failure_and_timeout_do_not_mix` | `lambda_returns`; “source GAE failure timeout and soft-failure contracts” | Native hard/soft/time-limit arithmetic assertions only |
| `test_replay_short_windows_and_episode_boundary` | `ReplayBuffer::can_sample_windows/sample_windows/sample_starts`; “source replay warmup boundaries complete imagination and empty restore” | Native warmup/mask/history/clip-completion source |
| `test_replay_ring_resume_restores_windows` | Replay `snapshot/restore`, chronological ring and empty-state restore in the same test and `aligned_wbtest.mbt` | Native source; original Torch random draw equivalence is not implied |
| `test_frozen_critic_retains_state_gradient` | Actual Critic tape path and frozen parameter arrays; “source frozen critic retains input gradient without changing weights” | Source checks actual input gradients and unchanged weights; unexecuted |
| `test_full_8_step_fit_32_step_actor_and_imagined_critic` | Actual `Learner::fit_world_model/update_policy`, snapshots/Adam; “source eight-step model thirty-two-step actor and imagined critic update” | Native Double fixture uses native FK/MDP. Separate original FixtureMDP equality is the `learning.*` route below |
| `test_world_model_identity_has_finite_gradients` | Actual WorldModel/AD; “source zero-initialized world identity has finite state and action gradients” | Source assertion for state/action/parameter derivatives, unexecuted |
| `test_native_export_reorders_joints_and_rotates_world_angular_velocity` | Actual `mujoco_state`; “source export reorders joints and rotates world angular velocity” | Native compiled-address/permutation fixture source only |

## Evaluation: 9 methods

| Original method in `aligned/test_aligned_evaluation.py` | Native SUT / source test | Boundary |
| --- | --- | --- |
| `test_early_failure_keeps_unplayed_reference_in_denominator` | `summarize_evaluations`; `aligned_wbtest.mbt` “evaluation includes unplayed failed remainder in denominator” | Original denominator behavior represented; unexecuted |
| `test_negative_return_and_final_frame_termination_are_preserved` | “source negative final-frame failure and strict tracking stay distinct” | Negative return/final failure source assertions |
| `test_timeout_and_missing_clip_cannot_be_claimed_complete` | Same summary test checks incomplete timeout and missing clip | No completion claim from truncated evidence |
| `test_strict_tracking_is_distinct_from_paper_failure` | Same test separates strict RMSE gate and paper failure | Native report source; no benchmark result |
| `test_duplicate_and_nonfinite_results_rejected` | “source duplicate nonfinite and invalid evaluation results rejected” | Source rejects duplicate IDs, NaN and invalid step/strict data |
| `test_full_clip_driver_resets_histories_and_restores_policy_mode` | Actual `Learner::evaluate`; “source full-clip driver clears history across failure and subset evaluation” | MoonBit has no Torch mutable train/eval flag; evaluation is deterministic and does not update normalizers. History-isolation source exists |
| `test_subset_evaluation_does_not_claim_full_catalog` | Same driver test and summary reporting | Source tracks subset and full-catalog claims separately |
| `test_unused_gpu_replicas_count_as_compute_not_extra_trials` | “source evaluation subset replica and training environment contracts”; report replica accounting | Callback test records logical replica cost, not GPU execution |
| `test_training_environment_rejected` | Same test calls actual evaluation guard with `auto_reset=true` | Invalid training-view rejection source only |

## Resume and native physics: 5 methods

| Original file / method | Actual native SUT / test mapping | Prerequisite and status |
| --- | --- | --- |
| `aligned/test_aligned_resume.py::test_split_training_matches_uninterrupted` | `TrainingRunner`, full learner/replay/normalizer/Adam/history/RNG/integration snapshots; “source REAL split training matches uninterrupted learner replay history and RNG” | Real MuJoCo library/scene and motion rows. Source exists; no split or continuous run executed |
| `aligned/test_aligned_physics.py::test_four_substeps_and_original_motor_constants` | Actual native environment motor setup, four solver steps, gain/damping/armature/effort checks; matching test in `physics/physics_wbtest.mbt` | Real MuJoCo required; no native force/step execution |
| `aligned/test_aligned_physics.py::test_smc_context_is_fixed_per_environment_but_calibration_resets` | Actual fixed environment context, friction/COM and calibration reset; matching native physics test | Real MuJoCo source fixture only |
| `aligned/test_aligned_physics.py::test_episode_context_resamples_selected_environment_only` | Actual selected-environment resampling and integration restoration; matching native physics test | Real MuJoCo source fixture only |
| `aligned/test_aligned_physics.py::test_profiles_separate_paper_from_smc_and_experimental_observations` | Actual CPU scale/profile validation; “source CPU scale and SMC profile semantics remain explicitly separate” | Native profile contract; no paper-scale throughput or GPU claim |

## Upstream learner differential: 4 methods

| Original method in `aligned/test_smc_learning_differential.py` | Case ID | Actual MoonBit candidate route | Oracle / missing evidence |
| --- | --- | --- | --- |
| `test_default_architecture_parameter_shapes_match_upstream` | `learning.architecture` | `candidate_architecture` constructs actual default WorldModel/Policy/Critic and reads actual flattened parameter slots and normalizer shapes | `architecture_mathematical_oracle` independently encodes source constructor shapes/names. Original Torch meta-device constructors were not executed |
| `test_network_outputs_and_world_model_8step_adam_match` | `learning.world8` | `candidate_learning("network"/"world_update")` imports source-bound actual network/buffer state, calls real model forward and `WorldModel::fit_fixed` with actual Adam trace | `native/learning_oracle.cpp` independently translates original ATen forward/8-step training. Original Python imports/AST functions did not execute; strict Float32 versus Double state/optimizer parity is still unresolved |
| `test_32step_actor_and_gae_critic_updates_match_actual_smc_function` | `learning.policy32` | Actual `Learner::update_policy_fixed(FixtureHeads)`, frozen world/value, true actor and critic Adam updates, supplied exact two 64-entry critic permutations; actual raw/applied gradient hooks | Separate ATen translation preserves original FixtureMDP, critic normalization update, 32-step tail and GAE. No executed original `policy_update` fixture or passing equality result |
| `test_replay_same_windows_history_and_exact_ring_restore` | `learning.replay` | Actual `ReplayBuffer` sampling and snapshot/restore with fixed source-bound age/environment choices | Independent pinned age/ring equations in `replay_mathematical_oracle`; no imported SMC ReplayBuffer execution or proof of its Torch RNG draws |

Learning evidence includes every supplied post-update state tensor and per-parameter Adam `exp_avg`, `exp_avg_sq`, `step`; raw/applied gradients come from the actual SUT optimizer, not a parallel hand-derived gradient. A strict output-schema pass still requires all shape/dtype/value gates. Capturing a plausible scalar loss is not sufficient.

## Isaac protocol: 9 methods

| Original method in `aligned/test_aligned_isaac.py` | Case ID | Native production boundary / authored protocol source | Missing integration evidence |
| --- | --- | --- | --- |
| `test_pinned_physics_config_uses_four_five_millisecond_solver_steps` | `isaac.solver` | `gpu_protocol` solver configuration/adapter contract validates 0.02 control dt, four 0.005 solver steps and pinned solver settings | Original SDK config-object mock execution and real SDK adapter execution not performed |
| `test_gpu_joint_order_mismatch_is_rejected_before_raw_state_access` | `isaac.joint_order` | Batch adapter joint-order validation before raw buffer access | CPU protocol source can use a swapped-order callback; no USD/GPU articulation instantiated |
| `test_optional_backend_reports_missing_runtime_without_breaking_cpu_import` | `isaac.missing` | Explicit optional native backend availability/launch boundary | Missing-SDK/CUDA error source is not a functioning SDK adapter or launch result |
| `test_training_transition_preserves_pre_reset_state_and_timeout` | `isaac.transition` | Actual `TrackingProtocol::step`: pre-reset transition, next frame/time limit, target conversion, sampler completion and context output | Native CPU protocol test/captured original trace, not GPU dynamics evidence |
| `test_evaluation_view_disables_randomization_and_training_timeout` | `isaac.evaluation` | `for_evaluation/evaluation_reset/evaluation_step`; deterministic context, one measured replica, exhausted frame behavior | CPU callback protocol only; live SDK view and unused-replica compute not measured |
| `test_warm_resume_declares_refill_and_starts_new_episodes` | `isaac.resume` | `TrackingProtocol::snapshot/restore`; explicitly inexact physics resume, refill/reset and collision compatibility | No GPU state restoration or executed original mock fixture |
| `test_context_writes_physics_and_warm_resume_resamples_only_episode_offsets` | `isaac.context` | Callback writes for friction/COM/model-change flags and restored versus fresh offset channels | Callback trace source is not verified PhysX/Newton model mutation |
| `test_evaluation_passes_raw_action_without_collection_cap` | `isaac.raw_action` | Actual evaluation step passes raw action through physical setpoint scaling | No executed SDK actuator trace |
| `test_episode_context_resamples_only_selected_environment_and_updates_physics` | `isaac.episode_context` | Selected IDs, context ranges, friction/COM update IDs and resampling-mode restore guard | No real SDK context-write integration result |

The actual GPU adapter remains a distinct dependency. `gpu_protocol/isaac_contracts_wbtest.mbt` now contains eight original methods calling production `TrackingProtocol` with an explicit CPU contract-device fixture, and `gpu_native/availability_wbtest.mbt` covers the ninth with the real optional loader. These sources passed native type checking and were not executed; they are not a synthetic replacement physics solver. The 9 case IDs also allow strict verification of source-bound protocol captures; that registration does not mean captures were exported or verified in this task.

## Original tolerances and extra audit fields

The tuple below is `(absolute tolerance, relative tolerance)`. Exact integer/boolean/name/shape comparisons remain exact, and `compare_fixture` additionally requires identical declared dtype and shape. The fixture cannot supply its own looser numerical thresholds.

| Original assertion scope | Original gate | Native contract treatment |
| --- | --- | --- |
| Data resampled root velocity | `assert_close(atol=1e-5,rtol=0)` | `data.resampling/root_v`: `(1e-5,0)` |
| Data duplicate sampler `bin_G` and timeout/terminal bin return | `torch.testing.assert_close` default Float32: `(1e-5,1.3e-6)` | `data.duplicates/bin_G`, `data.bootstrap` preserve this threshold; duplicate-order equality is separately exact |
| Data duplicate sampler probability | Original only asserts `probabilities[1] > probabilities[2]` | Ranking is the original semantic gate. Any complete probability-array comparison is an additional diagnostic, not an original numerical tolerance |
| Real-clip states, indices and future frames | Explicit `(0,0)` | Exact; goals alone allow `(2e-6,2e-6)` |
| Reset mixture samples, historical weights and unique EMA update | Explicit `(0,0)` | Exact with declared fixed original draws; native seed equality alone cannot satisfy this gate |
| MDP observation/noise/termination/soft termination, mode prefixes, FK and quaternion value/pullback | Explicit `(0,0)` | Exact; no dtype-dependent default is substituted |
| MDP reward / individual terms / critic features and reward gradients | Explicit `(2e-9,0)` / `(1e-8,0)` / `(2e-8,0)` | Same field-specific gates |
| Corrected tiny-angle value and derivative | Explicit `(0,1e-6)` against `1e-10` and `2e-5` | Same correction gates; upstream zero derivative and vertical determinant remain exact predicates |
| Learning world8 forward, weights, clipped gradients and Adam state | `assert_state_close` helper explicitly defaults to `(0,0)` | Exact. These are not generic default `torch.testing.assert_close` tolerances |
| Learning world8 loss and last error | `assertAlmostEqual(...,places=7)` | Absolute `0.5e-7` decimal threshold; no relative tolerance |
| Learning policy32 loss/reward/gradient norm/survival | `assertAlmostEqual(...,places=6)` | Absolute `0.5e-6` decimal threshold; no relative tolerance |
| Learning policy32 network and Adam state | Same exact helper `(0,0)` | Exact. Per-minibatch raw/clipped gradient arrays are additional audit evidence; they were not all directly asserted by the original method |
| Learning replay selected fields / patched age/history draws / restored ring | Exact helper `(0,0)` | Exact; more state/RNG fields can be retained as additional audit evidence |
| Isaac transition target and returned joint-offset context; evaluation raw-action target | Original `torch.allclose` defaults `(1e-8,1e-5)` | `isaac.transition/target`, `isaac.transition/out.xi`, `isaac.raw_action/target` retain the original allclose threshold; other exact/predicate outputs remain separate |

Some source assertions are predicates rather than tensor equality: sampler range checks, probability ordering, “any terminal-only frame sampled,” error rejection, strict-tracking completeness and callback call counts. Captures must preserve those predicate outcomes. Recording full arrays provides useful additional diagnostics but does not replace the original predicate with an invented assertion. Likewise, the complete raw-gradient/RNG/optimizer output schema is deliberately stronger diagnostic coverage; it must not be described as a literal copy of every original assertion.

The decimal `assertAlmostEqual` thresholds above are represented as absolute comparison limits rather than re-executing Python's `round` implementation. IEEE half-way rounding at the exact boundary can differ; no measured result is reported at that boundary. This representation must not be used to claim byte-for-byte execution of unittest.

## Provenance and current tool routes

`protocol.mbt` binds a trusted `fixture.json` SHA, input/expected NPZ SHAs, original-test identity, producer identity, candidate-source identities, pinned upstream revision `a1508d42c9d1699a52e8233ab16d08c488441ab9`, CPU/device/thread metadata and before/after RNG digests. The acquired motion catalog separately pins revision `ce1572906efe6157840e8474d5a0d7aa87481e74`. Correct source identity and accepted provenance are necessary evidence; they do not establish that an unexecuted fixture has numerical agreement.

The differential CLI is authored and native typechecked at `cmd/reference_differential`, with `list`, `export`, `run` and `verify-capture` routes; its package README owns command usage. `export` selects an independently authored native oracle and must label it as independent mathematics/ATen. It must never label a C++ equation translation as `executed-upstream-python`. `run` invokes actual candidate adapters for supported cases; data unit/protocol cases can use direct native tests or a captured candidate path instead of a nonexistent numerical adapter. `verify-capture` verifies externally supplied complete captures against a trusted fixture; accepting that format is not the same as creating an original Python fixture. The 27 fixture-test entries explicitly fail on missing real fixtures; the 12 original executed-SMC comparisons require actual executed-upstream-Python evidence.

No original Python file has been removed. No Python subprocess, AST execution, source-oracle import, fallback fake result or SDK launch was introduced or run by this documentation audit. All execution, exact Float32 parity, real-data comparisons and SDK integration claims remain pending actual authorized runs.
