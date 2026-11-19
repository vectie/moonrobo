# Reference action and feedback response migration

All original Python sources remain available. This package is a parallel native
implementation. Its production API and CLI pass `moon check --target native`.
No test, training, MuJoCo step, hardware operation, or diagnostic study was run.

| Source under `providers/motion_learning/` | Parallel implementation |
| --- | --- |
| `reference_action_response.py` | `action.mbt`, `branches.mbt`, `helpers.mbt`, `export.mbt`: full source/report/SHA traversal, exact solver-control replay, target precision conversion, first-control AD gradient, feasible coordinates and RMS direction, finite-difference gate, paired physical branches, NPZ/report persistence, and independent export reconstruction. |
| `reference_feedback_response.py` | `feedback.mbt`, `branches.mbt`: full saved controller input restoration, open-tape/causal-feedback model rollout with reverse AD, full-tape feasible direction shared by all baselines, crossed direction/execution modes, multiple epsilon checks, physical curves, frozen learned-tensor guards, NPZ/report persistence. |
| `reference_feedback_response_export.py` | `export.mbt`: full source ancestry and input SHA checks, causal memory verification, direction shape/RMS gate, independent action-law and observer reconstruction, reward/observation/fall/boundary checks, and per-record dataset export stream. |
| `test_reference_action_response.py` | Four pending cases in `response_wbtest.mbt`: only-first-control clipping, saturated coordinates, exact solver restoration after another branch, first-control AD versus centered finite difference. |
| `test_reference_feedback_response.py` | Four pending cases in `response_wbtest.mbt`: zero feedback perturbation versus existing imagination, full-tape gradients in both modes, common interior mask, exact controller/solver restoration after another branch. |

CLI commands (deferred until execution is permitted):

```sh
moon run src/learning_reference_directions/cli --target native -- action --source SOURCE_STUDY --output ACTION_STUDY --scene SCENE.xml --library LIBMUJOCO
moon run src/learning_reference_directions/cli --target native -- feedback --source ACTION_STUDY --output FEEDBACK_STUDY --scene SCENE.xml --library LIBMUJOCO
moon run src/learning_reference_directions/cli --target native -- export-action --study ACTION_STUDY --scene SCENE.xml --library LIBMUJOCO
moon run src/learning_reference_directions/cli --target native -- export-feedback --study FEEDBACK_STUDY --scene SCENE.xml --library LIBMUJOCO
```

The two study commands consume the original charter at `OUTPUT/config.json`.
They write `report.json` and the original `physics/`, `snapshots/` or `inputs/`,
and `directions/` archive structure. Export commands emit one verified JSON record
per line. Actor/model loading reuses the shared restricted Torch ZIP importer or
native checkpoints; no Python process or pickle global is executed.

Every original scientific gate remains enforced: source hashes, complete-window
availability, source replay precision, exact restored branch continuity, finite
nonzero gradients, feasible interior/RMS constraints, action finite differences,
frozen learned state, feedback law reconstruction, and independent reward/fall/
observation/boundary checks. Feedback finite differences remain reported checks,
as in the source, rather than becoming an additional qualification criterion.

Compatibility limits to verify later:

- The shared numerical backend uses Double. It does not reproduce every
  intermediate Float32 rounding in the original schedule/geometry setup; strict
  legacy reconstruction tolerances may correctly reject a discrepancy. Reference
  reward targets explicitly retain the source's Float32-then-Float64 conversion.
- Old Float32 source archives retain the exact Float32 replay assertion. Native
  Float64 source archives use exact Float64 replay and declare their dtype;
  `exact_float32_source_replay` is true only for Float32 inputs.
- The shared NPZ writer currently writes deterministic, uncompressed Float64
  arrays, including numeric 0/1 termination flags. Numeric values and shapes are
  preserved; archive bytes and flag dtypes differ from NumPy's compressed output.
- `provider_sha256` hashes the actual corresponding MoonBit driver source when
  available from the checkout, or `MOONROBO_SOURCE_ROOT`; it is null if the binary
  is deployed without that source. Provider elapsed time uses millisecond clocks.

Pending native tests require `MOONROBO_MUJOCO_LIBRARY` and optionally
`MOONROBO_MUJOCO_SCENE`. Their fixtures collect a real G1 stand trajectory and
exercise the actual MuJoCo integration-state API. They were type checked only.
No original production driver or export path in these three assigned files is
left as a placeholder; numerical equivalence and native execution remain unverified.
