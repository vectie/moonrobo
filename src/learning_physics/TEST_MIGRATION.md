# Assigned Python test contracts

Static audit completed against the original test files. Every row below has a
MoonBit test body. Only native type checking was performed; no test or fixture
was executed. Production code remains frozen; changes are test source and
`moon.pkg` test imports/target selection.

Paths in the Python column are relative to `providers/motion_learning/`.

| Python test | MoonBit file and test | Covered contract |
| --- | --- | --- |
| `test_pose_goals.py::test_seeded_offsets_repeat_and_cover_joint_group_bounds` | `src/learning_physics/pose_goals_test.mbt` — `pose offsets repeat by seed and cover every joint group bound` | Same seed gives equal offsets; all four coordinates stay within .04/.08/.12/.12; every coordinate spans more than .01 over 12 seeds. The test supplies the same declared ChaCha8/SHA256 stream law as the native CLI; equality to NumPy PCG64 is not asserted. |
| `test_pose_goals.py::test_invalid_amplitudes_are_not_silently_used` | same — `invalid pose amplitudes are rejected` | NaN waist amplitude raises instead of producing offsets. |
| `test_model_probe.py::test_absent_late_windows_do_not_report_zero_error_or_success` | `src/learning_probes/probes_test.mbt` — `missing failure-tail evidence remains null` | Both model labels return zero snapshot count and null MSE, sign agreement and ascent fractions for missing late evidence. |
| `test_model_probe.py::test_zero_gradient_excluded_from_ascent_denominator` | same — `zero gradient excluded from ascent denominator` | Two snapshots, one valid ascent; epsilon success fractions 0/1; finite-difference scale agreement 0; the late group contains one snapshot. |
| `test_critic_probe.py::test_hard_and_soft_returns_at_a_physical_fall` | same — `physics hard and soft returns include complete reward and zero tail` | Both return arrays use independently calculated final reward `2+exp(-(.5/.15)^2)` and first continuation, with actual zero tail. Expected values do not reuse the reward/continuation implementation as their oracle. |
| `test_actor_update_probe.py::test_adam_ascent_zero_and_reversed_parameter_steps` | `src/learning_probes/actor_update_contract_test.mbt` — `actual Adam actor update preserves buffers and follows ascent with and without critic tail` | One .01 parameter, unused normalization buffer 2, additive state[7] dynamics, `20*state[7]` critic and four-step differentiated reward/continuation rollout. Positive gradient norm/delta; all -1/0/1 scaled return signs; zero identity; normalization and original parameter preserved; no-tail delta negative; predicted bootstrapped change positive and reward change negative; optional config flag remains absent. |
| `test_reference_action_response.py::test_only_first_action_changes_and_clipping_matches_runtime` | `src/learning_reference_directions/response_wbtest.mbt` — `first action changes alone and matches real runtime clipping` | Only control 0 changes, clipping equals actual runtime bounds, later controls and source arrays remain equal. |
| `test_reference_action_response.py::test_gradient_direction_excludes_saturated_coordinates_for_both_amplitudes` | same — `first action gradient direction excludes saturated coordinates` | Exactly 27 feasible coordinates, first two zero, whole-vector RMS 1, and all four signed small amplitudes stay strictly unclipped. |
| `test_reference_action_response.py::test_full_solver_restore_gives_identical_physics_after_other_branch` | same — `full solver snapshot restores identical physical branch after intervention` | Baseline/intervention/repeated baseline through real MuJoCo; every archived field equal, final truncation true, no falls. |
| `test_reference_action_response.py::test_first_action_autograd_matches_model_finite_difference` | same — `first action analytic gradient matches model finite difference` | Nonzero finite analytic gradient and centered directional finite difference agree to 1e-6 for the reference objective. |
| `test_reference_feedback_response.py::test_zero_feedback_perturbation_matches_existing_training_imagination` | same — `zero feedback perturbation matches training imagination` | Zero-tape closed-loop objective agrees with the actual existing full-feedback training imagination at the original Float32-relative tolerance. |
| `test_reference_feedback_response.py::test_complete_tape_gradients_match_finite_differences_in_both_modes` | same — `complete tape analytic gradients match finite difference in both modes` | Both execution modes have finite gradients, nonzero later-control gradient, and complete-tape AD/centered finite differences agree to 1e-6. |
| `test_reference_feedback_response.py::test_common_mask_checks_all_baselines_and_normalizes_the_whole_tape` | same — `common feasible mask intersects all baselines over whole tape` | Both baseline saturation masks, exactly 56 feasible coordinates, two excluded entries, whole-tape RMS 1 and signed perturbation feasibility. |
| `test_reference_feedback_response.py::test_feedback_physics_restores_memory_and_solver_after_another_branch` | same — `feedback branch restores controller memory and solver after intervention` | Real feedback baseline/intervention/repeated baseline preserves every archived field and truncates at the expected end. |

The toy actor test uses the production probe's callback-based parameter API and
the shared production `training.step_reward` reverse-AD implementation. Its toy
dynamics and critic are the original deliberately minimal test fixtures, not
substitute production simulation. Native reference test fixtures collect actual
MuJoCo states when eventually run; they require `MOONROBO_MUJOCO_LIBRARY` and
optionally `MOONROBO_MUJOCO_SCENE`. Their deterministic fixture RNG is native and
is not represented as a bitwise copy of the original Torch/NumPy seeded fixtures.
