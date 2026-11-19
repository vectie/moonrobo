# Native learned-balance studies

Parallel counterparts of `providers/motion_learning/learned_balance_study.py` and `learned_balance_long.py`. Python remains unchanged. Both drivers and their dependencies have passed `moon check`; neither driver, test suite, training nor MuJoCo experiment has been executed in this session.

The `learned` command verifies the intervention log SHA against its report, filters allowed source modes/scope/split/case ownership, checks episode/trial identity and reset boundaries, restores each training state in real MuJoCo, and generates privileged native teacher targets. It computes causal observation features separately per episode/window, fits a shared ankle OLS head per configured window, embeds each frozen temporal parent in a complete portable checkpoint, checks reload and unchanged weights, and performs physical comparisons on canonical and train-audit scopes. Each rollout also compares online/offline features and ankle controls and checks that feedback leaves every non-ankle parent output unchanged. Reports, training-source ownership, experiment/charter, full gzip evaluation data and checkpoint hashes are saved.

The `long` command verifies the original evaluation log hash, loads the frozen bundles, runs the declared longer conditions, and requires a repeated reset trajectory to match every original step field exactly except `truncated`. It rejects missing prefixes, shortened trajectories or changed controls/state and records checked prefix counts.

```sh
moon run src/learning_studies/cmd -- learned MUJOCO_LIBRARY SCENE CONFIG COLLECTION EXPERIMENT TEACHER_JSON INTERVENTION_DIRECTORY POLICIES_DIRECTORY OUTPUT
moon run src/learning_studies/cmd -- long MUJOCO_LIBRARY SCENE CONFIG STUDY_DIRECTORY OUTPUT
```

Inputs use original JSON configuration keys and existing dataset/episode/trial formats. Incoming parent/head paths prefer MoonBit `.moon.json` and fall back to original `.pt`, using the newly implemented restricted safe TorchZIP temporal/balance adapter. These imports have been type checked but not compared against actual original checkpoints in this session. The study writes complete MoonBit balance policy bundles. Run from the repository root; output parent directories must exist. Fitted teacher provenance currently checks the preserved `providers/motion_learning/balance_teacher.py` digest. That proves source identity for provenance, not Python/MoonBit teacher parity.

Remaining differences: float64 throughout, a portable RNG rather than NumPy PCG64/Torch RNG, native OLS QR rather than Torch least squares, versioned MoonBit report schemas, and pooled summaries without the original per-case breakdown. Source/provider audit fields are less exhaustive than the Python reports. The implementation currently accepts `gravity_gyro` transport, matching complete native balance-policy bundle conventions; other transports are explicitly rejected. Long-prefix agreement and learning quality remain unverified until machine time is available.

## Sustained train-only study

`providers/motion_learning/sustained_balance_study.py` is implemented by `sustained.mbt` and `sustained_rollout.mbt`:

```sh
moon run src/learning_studies/cmd -- sustained MUJOCO_LIBRARY SCENE CONFIG ORIGINAL_BALANCE_STUDY TEACHER_STUDY OUTPUT
```

The driver verifies fitted-teacher source/search hashes; collects fresh teacher rollouts on training cases/resets only; archives the complete role-tagged teacher corpus; fits the two range/pose-rate ankle+waist representations; emits every configured variant for every frozen parent; verifies checkpoint/head/parent round trips; evaluates all variants on training-family selection conditions; chooses globally by falls, survival, RMSE and active-coefficient count; saves `selected.json` before any final canonical/audit rollout; then evaluates the chosen policies and privileged teacher reference on separate declared final conditions. Online/offline feature/action agreement and unchanged parent output channels are checked on each physical policy episode. All training, selection and final datasets, roles, hashes and summaries are saved.

The independent `sustained_balance_verify.py` counterpart is owned by `src/learning_balance/verification`: it reconstructs features and refits every saved head from the archived train corpus, checks exact coefficients/normalization and validates the frozen variant controls. Its execution is deferred along with all experiments. The study writes `config.json`, `charter.json`, the original study link, `.moon.json` policy bundles and corpus/report fields needed by that verifier.

Sustained report differences: pooled summaries currently omit per-case breakdown and fit summaries omit the original action-error subreports. RNG/precision/checkpoint differences above apply. No release or hardware qualification is inferred.
