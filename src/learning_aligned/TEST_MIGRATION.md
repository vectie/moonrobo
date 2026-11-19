# Aligned test-source audit (execution deferred)

The original nine Python sources contain 54 test methods. Every method now has
an explicit source/fixture route in [the full audit](../learning_differential/AUDIT.md).
Native block counts differ from original-method counts: 27 additional named
fixture entries coexist with direct CPU/real-MuJoCo and nine Isaac protocol
counterparts. A source route is not a passing original-upstream comparison.
No test, training, simulator, source oracle or random benchmark was executed.

The six sources under `aligned/` are mapped in `MIGRATION.md`. The three tests
in their parent directory are audited individually below.

| Preserved parent source / method | Native source and contract | Status / limits |
| --- | --- | --- |
| `test_aligned_data.py::test_resampling_velocity_goals_and_end_bins` | `data_mdp_wbtest.mbt`: 31/61 frames → 51/101, unit root velocity, 730-wide goals, clipped previews, 3 bins, no terminal resets, full 32-step reset horizon | Authored/typechecked |
| `::test_duplicate_bin_update_is_order_independent_and_checkpoint_exact` | Duplicate completions commute, expected bin returns/counts/difficulty ranking; sampler + caller-owned native RNG snapshot restores identical draws | Authored/typechecked; native RNG differs from Torch |
| `::test_timeout_bootstrap_and_real_terminal` | Nonterminal bootstrap gives bin returns 0.04; terminal gives 0.03 | Authored/typechecked |
| `::test_manifest_hash_verification_and_split_identity` | Async temporary numeric CSV + manifest, evaluation split identity, newline tampering rejected by SHA | Authored/typechecked; no fixture writes performed yet |
| `::test_reference_only_export_skips_fk_without_changing_goal_features` | Deliberately invalid FK tree cannot be touched when body cache disabled; all goal features equal full load | Authored/typechecked |
| `::test_all_40_acquired_sources_match_frozen_catalog` | Async real acquired manifest revision, split identity, every SHA/row count/quaternion norm, 40 clips and 264705 rows | Authored/typechecked; real data prerequisite, not read by test execution |
| `::test_real_clip_reference_states_and_goals_against_smc` | Actual motion/resampling candidate plus separate ATen original math and strict three-clip fixture adapter | Tool/source authored and typechecked; actual executed-SMC fixtures missing, native Double versus Float32 exact gates remain unresolved |
| `::test_reset_mixture_and_unique_return_updates_match_actual_smc_method` | Actual sampler batch-draw seam using real ATen multinomial/uniform, complete state/RNG binding and independently transcribed original reset method | Tool/source authored; no RNG/oracle samples or original executed-Python fixture generated |
| `::test_terminal_only_bins_are_explicit_upstream_bug_fix` | Actual corrected candidate bins versus independent old sampler counterexample, original predicates and strict fixture route | Both source branches authored; no sampling or original executed-SMC fixture run |
| `test_aligned_mdp.py::test_observable_input_resolves_translation_and_heading_ambiguity` | `data_mdp_wbtest.mbt`: three exact dimensions/prefixes, paper/SMC XY ambiguity, observable displacement and heading | Authored/typechecked |
| `::test_default_pose_scaled_action_has_no_reference_or_ankle_override` | Default+per-joint scale output and analytic tape pullback, strictly positive all 29 scales | Authored/typechecked |
| `::test_relative_termination_allows_matching_low_and_sideways_reference` | Matched low/sideways reference accepted, relative 0.26 m failure, finite nonzero survival pullback at 0.24 m | Authored/typechecked |
| `::test_all_reward_terms_and_paper_scales` | Perfect 0.1, zero orientation errors, explicit root shift equation, velocity penalties, action smoothness and joint-limit value | Authored/typechecked |
| `::test_fk_pose_velocity_and_gradient_against_mujoco` | `physics/physics_wbtest.mbt`: compiled topology FK versus real MuJoCo world poses, Jacobian×qvel linear velocity, native angular velocity; reverse-mode joint gradient versus real MuJoCo finite differences; state round trip | Authored/typechecked; real scene/library required |
| `::test_rotation_distance_gradient_and_vertical_heading` | Zero loss and finite derivative, tiny angle exact loss/gradient, orthogonal vertical yaw | Authored/typechecked |
| `test_aligned_mdp_differential.py::test_head_values_and_gradients_match_smc_away_from_rotation_singularities` | Actual SUT head/pullback adapter, separately transcribed ATen original equations, bound noise draw/state and full fixture gate | Original executed-Python fixtures and strict numerical comparison remain deferred |
| `::test_observation_modes_have_exact_upstream_prefix` | Actual modes/prefixes/dimensions versus independent original math; original-method fixture entry | No executed upstream fixture or passing value comparison |
| `::test_fk_matches_actual_upstream_for_all_tracked_bodies` | Actual all-tracked-body FK, independent ATen original FK, real-MuJoCo test source and strict fixture adapter | Original executed-SMC fixture and real execution remain deferred |
| `::test_matrix_quaternion_values_and_pullback_match_upstream` | Actual production quaternion graph pullback versus independent ATen branches/autograd and exact original fixture gate | No oracle sample or original executed-Python fixture generated |
| `::test_documented_rotation_fixes_remove_upstream_floor_and_vertical_collapse` | Actual corrected angle/yaw plus separate old-equation floor/zero-determinant reference and original predicates | Source authored/typechecked; neither branch executed |

Real physics prerequisites are documented in `MIGRATION.md`. The new
`cmd/reference_differential` CLI and 27 fixture entries are documented in
`../learning_differential/README.md`; its independent C++ exporter cannot label
results as executed upstream Python. Missing fixtures fail explicitly.
`gpu_protocol/isaac_contracts_wbtest.mbt` contains eight production-protocol
counterparts and `gpu_native/availability_wbtest.mbt` the ninth loader case,
all typechecked but unexecuted. Pinned SDK/CUDA/APIC compilation and real GPU
execution remain separate requirements. No numerical-parity result is claimed.
