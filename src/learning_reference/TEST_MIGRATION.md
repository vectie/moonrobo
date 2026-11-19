# Reference test source mapping

All original Python test files remain unchanged. **No test has been executed.**
The tables identify translated contracts, not passing scientific results.
Native `moon check` checks every test body without invoking it.

Paths below are relative to `src/learning_reference/` unless another package is
named. Existing focused tests remain alongside the more complete contract tests.
There are 31 reference tests, 2 route tests, 4 root tests and 8 direction tests.

## Original tests and MoonBit counterparts

| Original source / test method | Pending MoonBit test source and contract |
|---|---|
| `test_reference_task.py::test_physics_body_alignment_batched_geometry_and_memory_gradients` | `reference_task_contract_wbtest.mbt`: `original task real G1 FK batched nesting observer transport and memory gradients`; real G1 random-joint-sines seed 58, full EMA/gyro/gravity observer versus carried graph, nested 2×3 geometry/single equality, real body alignment reward 0.06, no falls, error/observer equality, finite state gradients and nonzero detached-memory final-observation gradient. |
| `test_reference_actor.py::test_causal_runner_matches_supervised_inputs_and_round_trip` | `reference_actor_contract_wbtest.mbt`: `original actor causal runner checkpoint and teacher label independence`; real G1 seed 41, history/future 10, nonzero decoder output with zero observation columns, causal runner/supervised outputs, native checkpoint bit-exact outputs/static geometry/physical flag, post-load observation-column gradients, changed teacher labels leave all inputs unchanged. |
| `test_reference_actor.py::test_feedback_is_relative_and_preserves_input_gradients` | Existing `reference_test.mbt::relative feedback has zero common feature response` and `reference_gradient_test.mbt::actor Tape gradients reach learned decoder and input feedback`, plus `reference_actor_contract_wbtest.mbt::original actor feedback coefficients stay outside learned parameter vector`; common-mode cancellation, 0.001 feature→0.016 ankle action, finite/nonzero input gradients, coefficients excluded from learned parameters and finite-difference agreement. |
| `test_reference_learning.py::test_imagination_has_finite_actor_gradients_through_frozen_model_and_memory` | `reference_imagination_contract_wbtest.mbt::original learning imagination freezes world model and critic while actor receives gradient`; horizon 4, 2 origins, 8 active steps, finite/nonzero actor parameter gradients and unchanged model/critic tensors. |
| `test_reference_learning.py::test_policy_input_stop_preserves_forward_and_plant_gradient_but_blocks_feature_edge` | `reference_imagination_contract_wbtest.mbt::original learning stop policy inputs cuts observer edge but retains plant BPTT`; exact full/stop forward and active-count equality, both finite/nonzero parameter and initial-state gradients, full feature gradient nonzero, stopped feature gradient zero, parameter gradients differ. Actual Tape-bound inputs are captured via optional `initial_graph`. |
| `test_reference_learning.py::test_behavior_loader_reconstructs_a_parameter_probe_from_its_frozen_base` | `reference_collection_contract_wbtest.mbt::original learning behavior loader applies named direction to frozen base only`; saved SHA-paired base plus named linearly spaced direction×0.002, exact reconstructed weights, fixed buffers preserved, original actor unchanged. |
| `test_reference_learning.py::test_finite_gae_does_not_bootstrap_across_reference_end` | `reference_test.mbt::finite returns and GAE never bootstrap across reset`; all three normalized GAE elements, terminal reset mask and finite returns. |
| `test_reference_learning.py::test_prefix_only_removes_tail_without_extending_the_finite_reference` | `reference_imagination_contract_wbtest.mbt::original learning prefix ignores unused critic and stops bootstrap at reference end`; horizons 4/20, zero tail equals no tail, unused large critic cannot change prefix, constant-two value contributes exactly discounted tail before end and zero after end, active steps finite. |
| `test_reference_learning.py::test_actual_actor_updates_respect_the_calibrated_step_bound` | `reference_imagination_contract_wbtest.mbt::original learning calibrated actor updates remain nonzero below requested logit cap`; two actual Adam actor updates, each 0<applied RMS≤0.0001, actor changes, no critic tail and model frozen. |
| `test_reference_learning.py::test_model_windows_do_not_cross_resets_and_collection_records_actual_actions` | `reference_collection_contract_wbtest.mbt::original learning actual action collection archive roundtrip and middle-origin memory`, existing replay-window test and anchor contract; real noisy collection with checked applied actions, exactly one done, all native fields bit-exact through JSON and original NPZ causal restore, offset 3 retains origin/history, imagination ends at reference length, and retained windows stay inside episodes. |
| `test_reference_learning.py::test_actor_origin_modes_cover_only_the_intended_physical_states` | `reference_last_cycle_contract_wbtest.mbt::original learning actor origin sampler covers resets or complete trajectory exclusively`; exact reset and trajectory candidate pools plus 1024 deferred native draws covering each pool. |
| `test_reference_learning.py::test_extension_reuses_only_shared_and_selected_baseline_evidence` | `reference_registry_contract_wbtest.mbt::original learning reused baseline archive includes only shared and requested method episodes`; exact shared/selected evidence inclusion and other-method exclusion. |
| `test_reference_learning.py::test_extension_reconstruction_checks_actor_model_and_value_tensors` | `reference_collection_contract_wbtest.mbt::original learning reconstructed cycle checks actor model and value then rejects mutation`; independently saved and SHA-checked actor/model/value, positive equality gate, then model bias mutation explicitly rejected. |
| `test_reference_learning.py::test_initial_anchor_keeps_first_three_fits_then_replaces_only_recent_capacity` | `reference_collection_contract_wbtest.mbt::original learning first three anchor fits match FIFO parameters draws and later pool counts`; actual first-three model fits have equal draw SHA and tensors, original FIFO/anchor retained-window lists, reset-safe windows, cloned RNG predicts next two minibatches and their SHA/anchor counts, six recent windows. |
| `test_reference_last_cycle.py::test_windows_include_last_prefall_window_without_short_or_duplicate_windows` | `reference_last_cycle_contract_wbtest.mbt::original last cycle window boundary examples and short prediction fields`; all four original boundary examples; additional existing preview/window test. |
| `test_reference_last_cycle.py::test_return_prefix_stops_at_terminal_and_full_return_keeps_its_last_reward` | `reference_last_cycle_contract_wbtest.mbt::original last cycle discounted returns keep all observed short prefix rewards`; both original reward/gamma/horizon examples and observed counts. |
| `test_reference_last_cycle.py::test_open_loop_errors_weight_last_batch_and_have_declared_joint_units` | `reference_test.mbt::prediction metrics include last window and declared joint units`; all 259 windows including offset 258, analytic 2.5/71 state MSE and sqrt(2.5/29) joint radians, persistence/orientation zero. `reference_last_cycle_contract_wbtest.mbt` additionally checks every absent metric for one-transition short input. |
| `test_reference_registry_export.py::test_learning_comparison_uses_same_seed_trained_baseline_and_prior_for_its_own_entry` | `reference_registry_contract_wbtest.mbt::original registry baseline selects configured method within matching seed`; separate seed 0/1 runs, configured baseline, own-entry zero prior and default prefix-only method; existing registry tests retain arithmetic summary and role strings. |
| `test_reference_registry_export.py::test_short_physics_record_keeps_later_reference_and_uses_elapsed_clock` | `reference_registry_contract_wbtest.mbt::original registry truncated replay retains full planned suffix and archived states`; true G1 seed17, origin4/count6, six observed versus16 planned frames, relative0.02/0.32 clocks and absolute0.08 origin, real pose/joint alignment below1e-12, unchanged numeric archive. |
| `test_reference_final_route_training.py::test_fork_repeats_same_adam_update_and_sampler_without_aliasing` | `../learning_reference_routes/fork_wbtest.mbt`: existing sampler/Adam test now checks weight mutation isolation; new `original final route warmed actor Adam and RNG fork repeat next update without aliases` exercises actual `fork_actor_optimizer`, warmed Adam, identical next update/draws/tensors/moments/state and separate actor/moment/RNG mutations. |
| `test_reference_action_response.py::test_only_first_action_changes_and_clipping_matches_runtime` | `../learning_reference_directions/response_wbtest.mbt::first action changes alone and matches real runtime clipping`. |
| `test_reference_action_response.py::test_gradient_direction_excludes_saturated_coordinates_for_both_amplitudes` | `../learning_reference_directions/response_wbtest.mbt::first action gradient direction excludes saturated coordinates`. |
| `test_reference_action_response.py::test_full_solver_restore_gives_identical_physics_after_other_branch` | `../learning_reference_directions/response_wbtest.mbt::full solver snapshot restores identical physical branch after intervention`. |
| `test_reference_action_response.py::test_first_action_autograd_matches_model_finite_difference` | `../learning_reference_directions/response_wbtest.mbt::first action analytic gradient matches model finite difference`. |
| `test_reference_feedback_response.py::test_zero_feedback_perturbation_matches_existing_training_imagination` | `../learning_reference_directions/response_wbtest.mbt::zero feedback perturbation matches training imagination`. |
| `test_reference_feedback_response.py::test_complete_tape_gradients_match_finite_differences_in_both_modes` | `../learning_reference_directions/response_wbtest.mbt::complete tape analytic gradients match finite difference in both modes`. |
| `test_reference_feedback_response.py::test_common_mask_checks_all_baselines_and_normalizes_the_whole_tape` | `../learning_reference_directions/response_wbtest.mbt::common feasible mask intersects all baselines over whole tape`. |
| `test_reference_feedback_response.py::test_feedback_physics_restores_memory_and_solver_after_another_branch` | `../learning_reference_directions/response_wbtest.mbt::feedback branch restores controller memory and solver after intervention`. |

## Additional root algorithm contracts

There are no corresponding original `test_reference_root_*.py` files. The four
new `../learning_reference_roots/root_contract_wbtest.mbt` tests cover:

- Identical initial tensors for paired free/root-integrated models, exact
  trapezoid root position, and its state/velocity reverse-mode edges.
- Horizontal translation equivariance without changing velocities.
- Episode-local first origins/discounted physical returns, component RMS and
  central-secant consistency used by decomposition.
- Root diagnostic H8/H32 window counts and analytic root position/velocity units.

## Dependency and numerical boundaries

- Real-physics contract tests require `MOONROBO_MUJOCO_LIBRARY`; default scene is
  the original repository `target/mujoco_menagerie/unitree_g1/scene_mjx.xml`.
  `MOONROBO_G1_SCENE` may explicitly override it. Missing dependencies fail with a
  clear message; no fake pass/skip is substituted. Pure replay/metric/root/fork
  tests have no MuJoCo runtime dependency.
- Scalar Tape gradients have no persistent Torch `Parameter.grad` field. Frozen
  parameters are verified by unchanged model/critic tensors and actor-only
  optimizer inputs. A detached feature has numeric gradient zero rather than
  Torch's absent `.grad`; the exact edge behavior is asserted directly.
- Tensor leading dimensions become nested arrays and per-row graph calls. The
  task test retains 2×3 batch nesting/single equality rather than asserting a
  Torch-specific tensor shape object.
- Native checkpoint tests write the new explicit JSON format and numeric NPZ.
  Restricted original Torch readers are production code, but real legacy `.pt`
  fixture interoperability still needs the deferred original-archive comparison.
  No executable pickle, Torch `.pt` writer or old optimizer-resume equivalence is
  claimed.
- Native Double/xorshift32 fixtures preserve the scientific contracts and
  original tolerances; they do not reproduce Torch Float32/NumPy seed samples.
  None of these newly authored expected results is claimed experimentally passed.

After the machine is free, the deferred native entry points are
`moon test src/learning_reference --target native`,
`moon test src/learning_reference_routes --target native`,
`moon test src/learning_reference_roots --target native` and
`moon test src/learning_reference_directions --target native`, with the declared
MuJoCo fixture dependencies configured. Run the retained Python suite and
original-archive comparison separately before claiming old/new numerical parity.
