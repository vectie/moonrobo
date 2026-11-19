# Parallel reference-provider migration

All Python sources and tests are retained. The MoonBit tree runs alongside them;
none of these entry points starts Python. Only static checking/formatting and
interface generation have run. Training, simulation, regression tests and
old/new numeric comparisons remain deferred at the user's request.

## Entry points implemented in this package

Run from the repository root with `moon run --target native COMMAND -- ARGS`.
The `Config` record in each simple command is its exact configuration schema.

| Command | Arguments / behavior |
|---|---|
| `cmd/reference_initialize` | `CONFIG.json`: standalone native supervised fit/checkpoint/fit report |
| `cmd/reference_initialize` | `study CONFIG QUALITY REFERENCES FEEDBACK LIBRARY SCENE OUTPUT PROVIDER_SOURCE`: original multi-seed fixed-final-update study, including reference-only observation-weight gradient mask and full physical quality suite; FEEDBACK accepts original numeric Torch `.pt` or normalized native JSON |
| `cmd/reference_train` | `CONFIG.json`: standalone multiple-cycle native collection/critic/model/actor training |
| `cmd/reference_train` | `study CONFIG QUALITY ACTOR REFERENCES LIBRARY SCENE OUTPUT PROVIDER_SOURCE [REUSE_STUDY]`: original matched methods/common collection/diagnostics/quality protocol with baseline reuse and strict reconstruction checks before extensions |
| `cmd/reference_export` | `ACTOR ACTOR_SHA COLLECTION COLLECTION_SHA REFERENCES OUTPUT`: native collection/checkpoint numeric export with reward/observation/continuity checks |
| `cmd/reference_registry_export` | `initialization STUDY REFERENCES VERIFICATION LIBRARY SCENE OUTPUT PROVIDER_SOURCE`: original verified initialization-report to platform registry conversion |
| `cmd/reference_registry_export` | `learning STUDY METHOD VERIFICATION LIBRARY SCENE OUTPUT PROVIDER_SOURCE`: original verified learning-report to platform registry conversion |
| `cmd/reference_diagnostics` | `consistency STUDY PROVIDER_SOURCE`: original held-out world-model integration diagnostic |
| `cmd/reference_diagnostics` | `probe STUDY METHOD OFFSET`: full controller/value-tail autodiff versus finite-difference probe |
| `cmd/reference_diagnostics` | `last-cycle SOURCE OUTPUT LIBRARY SCENE PROVIDER_SOURCE`: frozen before/after actor comparison with shared world model and restored physical memory |
| `cmd/reference_diagnostics` | `initialization-export STUDY REFERENCES LIBRARY SCENE`: independently verify original initializer/physics artifacts and stream original typed JSONL datasets |
| `cmd/reference_diagnostics` | `learning-export STUDY LIBRARY SCENE`: verify behavior, causal features, actions, reward, fall masks, archive precision/continuity, quality reconstruction and matched/replay protocol; stream original typed datasets |

Legacy stochastic verification uses the optional native ATen CPU RNG adapter
selected by `MOONROBO_TORCH_RNG_ADAPTER`. It preserves actual `at::randn` float32
and `at::randint` draws rather than substituting the native training RNG. Without
that adapter, stochastic legacy verification fails explicitly. No adapter has
been built or sampled in this migration turn. See `../learning_torch_rng/README.md`
when available for its build instructions and version requirements.

## Source ownership and coverage

This table records implementations, not successful runtime verification.
Neighbor packages `learning_reference_directions`, `learning_reference_routes`
and `learning_reference_roots` own the indicated research drivers and their own
handoff/check status; they reuse this package's public model/task/IO APIs.

| Original Python file | MoonBit implementation |
|---|---|
| `reference_actor.py` | `reference_actor`, `reference_autodiff`, `reference_constructors`, `reference_schedule`, `reference_io`, `reference_torch`: encoders/decoder, bounded relative feedback, causal runner, numeric Torch/native loaders and checkpoint writing |
| `reference_task.py` | `reference_task`, `reference_geometry_graph`, `reference_schedule`, `reference_imagination`: FK, next-state reward/fall/error, gravity/gyro transport, full EMA memory, reference schedule and value network, with complete Tape gradients |
| `reference_initialization.py` | `reference_initialization`, `reference_initialization_study`, `reference_physical_group`: supervised training points, normalization, seeded fits, source-label residual bound, reference-only weight/gradient mask, fixed final save/reload, all requested physical origins and quality/pooled summary |
| `reference_learning.py` | `reference_learning`, `reference_cycle`, `reference_imagination`, `reference_matched_collection`, `reference_collection`: actual physics collection, causal archive restoration, finite returns/GAE, FIFO/initial-anchor model windows, critic/model BPTT fit, full/stop-policy-input imagined objective, capped model actor updates, PPO clipping/visitation/KL stop |
| `reference_learning_study.py` | `reference_learning_study`, `reference_study_support`: original shared initial evaluation, per-seed common-first/held-out diagnostic collections, common critic prior, prefix/replay/PPO methods, pre-fit PPO advantages, source baseline reuse/selection, source-cycle reconstruction guards, final quality suite, cost/progress/provenance report |
| `reference_learning_probe.py` | `reference_probe_study`: fixed final artifact selection, restored offset/history/EMA, float64 decoder-bias direction check through frozen world model and optional physical-return value tail |
| `reference_last_cycle.py` | `reference_last_cycle_study`, `reference_evaluation`, `reference_diagnostics`: frozen checkpoint/hash selection, training-origin predictions, restored paired physics/memory comparison, finite prefix/full returns and correctly weighted final-window prediction metrics |
| `reference_model_consistency.py` | `reference_consistency_study`: original per-seed held-out exclusion, archive/model hashes, joint/root trapezoid residual RMSE/ratio and original report schema |
| `reference_initialization_export.py` | `reference_initialization_export`: original model provenance/reference-only weight checks, archive continuity/reference hashes, independent true MuJoCo pose/reward/tracking metric reconstruction and typed dataset stream |
| `reference_learning_export.py` | `reference_learning_export`, `reference_export_protocols`, `reference_behavior`: source behavior/direction reconstruction, strict archive/feature/action/noise/reward/fall/quality checks, common-fit equality, extension reconstruction, anchor pool/draw SHA and actor-origin draw/age verification. Final-route actor-update-state verification is owned by `learning_reference_routes` and must be invoked before final-route streaming |
| `reference_registry_export.py` | `reference_registry`, `reference_registry_initialization`, registry CLI: original verification gates, original report/NPZ hashes, actual MuJoCo pose/contact reconstruction, original per-seed policy/registry schemas and representative gzip dataset |
| `reference_learning_registry_export.py` | `reference_registry_learning`, `reference_evaluation`, registry CLI: original method/seed baseline selection, trace cache, summaries/protocol/training accounting, original per-seed policy/registry schemas and representative gzip dataset |
| `reference_action_response.py` | Owned by `learning_reference_directions`; shared feasible directions, first-action tape perturbation, reward/task graph and source loaders are implemented here |
| `reference_feedback_response.py` | Owned by `learning_reference_directions`; shared full causal controller-memory graph and intersected feasible complete-tape directions are implemented here |
| `reference_feedback_response_export.py` | Owned by `learning_reference_directions`; uses shared source loaders, behavior/task/observer and typed dataset APIs |
| `reference_gradient_route.py` | Owned by `learning_reference_routes`; shared full/stop-policy-input objective, exact parameter ordering and iterative fixed-input raw-logit RMS calibration are implemented here |
| `reference_final_route_training.py` | Owned by `learning_reference_routes`; shared native exact actor/Adam/RNG fork, source loaders and state/optimizer/generator digests are implemented here |
| `reference_tail_directions.py` | Owned by `learning_reference_routes`; shared explicit prefix-only/no-tail objective, parameter gradient graph and physical group API are implemented here |
| `reference_root_integration.py` | Owned by `learning_reference_roots`; root-integrated/free dynamics loaders, matched fitting APIs and differentiable task/controller are implemented here and in `learning_training` |
| `reference_root_decomposition.py` | Owned by `learning_reference_roots`; shared full/prefix objective, finite-difference and central-secant helpers are implemented here |
| `reference_root_export.py` | Owned by `learning_reference_roots`; shared typed datasets, source behavior/direction reconstruction and full causal task/controller APIs are implemented here |

## Numeric / format boundaries that remain to verify

- New training uses scalar Double reverse-mode Tape computations and an explicit
  xorshift32/Box-Muller generator. It does not claim Torch float32 execution,
  minibatch/gradient equivalence or seed equivalence. The optional ATen adapter
  verifies original RNG streams; it does not change this numeric backend.
- Original numeric Torch ZIP/pickle checkpoints are read using the restricted
  data decoder in `learning_artifacts`; unknown globals are rejected without
  running pickle code. Actor/value/world-model/root-integrated/feedback/direction
  weights are imported with original shapes and parameter ordering. Actual old
  checkpoint coverage and accuracy still require deferred fixtures.
- Newly written checkpoints use the explicit MoonBit JSON checkpoint format.
  They are not Torch pickle files. Original `.pt` metadata references remain
  unchanged in old-report registry exports. Native report exports identify the
  native checkpoint format and filenames separately.
- Native training can save actor/model/critic/replay/all Adam moments/RNG/cycle
  and configuration using `ReferenceTrainingState`. The standalone train CLI
  writes that state, but no resume CLI mode is claimed.
- Reusing original stochastic archives requires the declared optional ATen RNG
  adapter. Float32 model/observer differences may still cause original strict
  alignment or reconstruction gates to fail. Those gates are retained and no
  unexecuted validation is represented as passed.
- Native MuJoCo linking/library discovery, archive output consumption, complete
  original report compatibility, all strict source gates and training outcomes
  remain runtime work. No generated policy is automatically release-qualified.

## Deferred tests

There are now **31 pending tests in this package**, **2 in
`learning_reference_routes`**, **4 in `learning_reference_roots`** and **8 in
`learning_reference_directions`**. The 28 original cases in all eight
`test_reference*.py` files have explicit MoonBit test-source counterparts; the
additional cases isolate native representation contracts and root diagnostics.
The exact case-by-case mapping, dependency requirements and representation
boundaries are recorded in [TEST_MIGRATION.md](TEST_MIGRATION.md).

The real G1 fixture requires `MOONROBO_MUJOCO_LIBRARY` and the original
`target/mujoco_menagerie/unitree_g1/scene_mjx.xml` (or explicit
`MOONROBO_G1_SCENE`). Missing dependencies raise an error; they never silently
skip or pass. `imagined_objective` has one optional `initial_graph` observation
callback, allowing tests to inspect the actual initial state/feature Tape edges
and prove the stopped policy-input edge is cut while plant BPTT remains. Default
training behavior is unchanged.

Only native type checking and formatting/interface generation were performed.
No test body, random fixture generation, training or simulation was executed.
