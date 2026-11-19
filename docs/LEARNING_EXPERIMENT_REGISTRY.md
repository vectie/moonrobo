# Learning Experiments In MoonData

Implemented: 2026-10-23. This is partial SM-1.4 and SM-4 progress: completed
local G1 training/feedback runs can be registered, reopened and compared through
the platform API. Registration preserves failed candidates. It does not turn
them into qualified skills.

## Register And Inspect

Run from the repository root. `RUN_DIR` is a completed output directory from
`scripts/fit_g1_policy.mbtx`, with `policy/`, `fit/` and `collection/` outputs.
`MOONDATA_ROOT` is the selected RoboBook's `moondata` directory; the local
research example uses `target/learning/experiment-book/moondata`.

The [temporal PPO producer](G1_TEMPORAL_PPO_STUDY.md) is also supported with
`moonrobo.g1-temporal-ppo-fit.v1`: it has `policy/` and `collection/`, without
a `fit/` directory. Each seed must supply its complete
`policy/ppo-physics-seed-N.jsonl.gz` training record. These are sealed as
`learning-ppo-physics`; no dynamics report or weights are fabricated. Existing
model-based producers continue to require `moonrobo.dynamics-fit.v1`.
Selected/latest PPO checkpoints contain their paired finite-task value network.

The [disturbance-supervision producer](G1_DISTURBANCE_INITIALIZATION.md) uses
`moonrobo.g1-temporal-disturbance-fit.v1`, also without a `fit/` directory.
It requires each seed's `disturbance-physics-seed-N.jsonl.gz` and
`disturbance-audit-seed-N.jsonl.gz` under `policy/`, sealed respectively as
`learning-supervised-physics` and `learning-disturbance-audit`. Teacher labels
remain separate from actual noisy applied actions. The audit records are
independent evidence; they are not included as fitted transitions. No critic
or dynamics payload is fabricated to register these supervised actors.

The [learned-balance producer](G1_BALANCE_PLATFORM_AND_DURATION.md) adds
`moonrobo.g1-learned-balance-fit.v1`, without a dynamics fit. It requires
`collection/balance-training.jsonl.gz` (all fitted episodes with separate labels),
`collection/training-sources.json`, `policy/balance-evaluation.jsonl.gz` (complete
recorded evaluation), and `policy/balance-study.json`. These seal respectively
as `learning-balance-training`, `learning-training-sources`,
`learning-balance-evaluation` and `learning-balance-study`. The representative
collection dataset is only the first training chunk. Each seed identifies an
inherited frozen parent, while one fitted head is shared across the arm.
Ten-second numeric passes and thirty-second failures register as separate
duration-scoped experiments; neither permits physical execution.

The [sustained distillation](G1_SUSTAINED_BALANCE_DISTILLATION.md) uses the same
producer contract with v2 composite checkpoint bytes. Optional
`policy/balance-selection.jsonl.gz` seals as `learning-balance-selection`,
preserving architecture-selection trajectories separately from fitted labels
and final evaluation. The `balance-sustained` source stores three selected
parents with one shared ankle law, all passing its thirty-second canonical
criterion. Its reported baseline is explicitly the privileged teacher, not the
old parent policy; nine unique teacher trials are reused for three comparisons.
Complete training-family audit records remain in the evaluation archive.
All three stored physics reports reopen through the unchanged API with the
declared thirty-second duration and physical execution false.

The [full-body reference producer](G1_REFERENCE_PLATFORM.md) uses
`moonrobo.g1-reference-policy-fit.v1` and seals original clips, every compact
physical record, source/quality/verification evidence and provider source,
without a dynamics fit. Its representative dataset is the first evaluated
episode, not the fitted corpus. `reference-joint-initialization` preserves all
three failed seed gates, while `reference-feedforward-initialization` records
three passing neural fits. Both retain the same 27-condition zero-output
baseline. Each source includes nine shared reference clips and108 numeric
physical episodes, linked by reference checksum and origin. The cockpit pairs
case/seed/origin and labels the remaining30/20/10-second scopes; reference root
curves continue through the planned end after a fall. All six stored reports
reopen through the same API. No released skill or hardware authority is added.

```sh
moon run cmd/learning_experiment --target native -- import MOONDATA_ROOT RUN_DIR EXPERIMENT_ID NOW_MS
moon run cmd/learning_experiment --target native -- list MOONDATA_ROOT
moon run cmd/learning_experiment --target native -- inspect MOONDATA_ROOT EXPERIMENT_ID
moon run cmd/moondata --target native -- validate MOONDATA_ROOT
```

Experiment IDs contain ASCII letters, digits, hyphens and underscores. Repeating
an import checks the original input bytes and returns the same summary and
import time. Changed bytes under the same ID are rejected; a new experiment
uses a new ID. Listing and inspection use stored MoonData references, so the
original run directory is no longer required for those reads.

## Stored Evidence

`src/moondata_learning` reuses the existing `DataSource`, catalog, validation
and SHA-256 BlobStore. Each experiment is a source with kind
`learning-experiment` and ID `learning-EXPERIMENT_ID`. Its references include:

- A `moonrobo.learning-experiment.v1` summary with per-seed selected update,
  baseline/candidate trial counts, falls, mean survival, joint RMSE, survival
  delta, producer qualification and selected checkpoint reference.
- Original policy and dynamics reports, preserving configurations, recorded
  digests, selection history, diagnostics and warm-start provenance.
- The merged transition dataset, selected/latest policy weights, per-seed
  baseline/candidate physics traces, and refitted dynamics weights.
- Optional per-seed gzip JSONL records from physics-supervised critic training,
  preserving actual transitions, targets, behavior-policy digests and tail values.
- Optional latest world-model weights from alternating training, alongside
  selected model snapshots and their actor/model digest pairing in the report.

Files are copied as bytes through the BlobStore; `.pt` files never pass through
a text importer. Identical content shares a blob. The source references cover
the stored payloads, allowing the existing root validator to check byte counts
and checksums without a new artifact catalog implementation.

For temporal PPO, `collection/dataset.json.gz` explicitly represents the first
seed's first training batch. All actual training episodes across seeds remain
in the required per-seed logs, with their role and counts in the policy report.
The representative dataset must not be reported as the full PPO collection.

When `collection/dataset.json` is absent, imports accept the fixed
`collection/dataset.json.gz` path as the same transition-dataset payload kind.
The original archive bytes and filename are retained. Registration does not
decompress or validate its dataset schema; the native materialization workflow
does that before training. Existing uncompressed runs are unchanged.

The ordering depends on the workflow: early feedback runs refit `fit/` after
actor training, while goal-refinement runs train the actor against the model
already stored in `fit/`. The original policy report's dynamics digest identifies
the actual model used. This first registry does not reconstruct
the entire cross-run training graph or archive external simulator assets,
provider source, optimizer state or materialized training batches.

## Read-Only Platform API

`GET /api/moondata/learning-experiments` reads the selected RoboBook's
`moondata` directory and returns:

```json
{
  "root": ".../moondata",
  "initialized": true,
  "experiments": [],
  "physical_execution_allowed": false
}
```

The real `experiments` array contains the registered summaries and their payload
references. Before initialization it is empty and `initialized` is false;
the read creates no files. An unreadable or corrupt registered summary returns
an error. The endpoint checks summary checksums; it does not rehash every large
payload on each request. Use MoonData validation for a complete payload check.

`producer_qualified` records the training provider's reported simulator result.
`physical_execution_allowed` is always false, even if the provider reports a
pass. Neither successful import nor catalog validation grants control authority.

`GET /api/moondata/learning-experiments/{experiment}/physics/{seed}` resolves
only the matching registered physics payload. The host checks its checksum and
returns a `moonrobo.learning-physics.v1` envelope with the experiment/seed,
original report, payload reference and `physical_execution_allowed: false`.
There is no arbitrary local-file download route.

Runs may also register `policy/qualification-followup.json` and the fixed
repeat/fresh/extended physics files beneath `candidate-followup/`. These remain
SHA-256 payloads owned by the same source. The physics envelope adds optional
`followup` and `evaluation_mode` fields. The route
`GET /api/moondata/learning-experiments/{experiment}/physics/{seed}/{mode}`
selects `repeat-two-second`, `fresh-two-second` or `fresh-ten-second`; the
three-segment physics route still selects the original report. Only registered
mode payloads can be read.

The envelope's optional `original_duration_s` comes from the sealed policy
report's experiment, with its checksum checked before reading. This supplies
the declared maximum duration even when every trial falls early. Old producer
reports without that metadata return null and remain readable.

## Cockpit Comparison And Trial Inspection

In the Rabbita cockpit, open **MoonData → Learning experiments**. The table
compares each selected policy with its reported baseline: survival, falls,
tracking RMSE, selected update and simulator qualification. Failed candidates
remain available for inspection. A read failure is shown as unavailable rather
than as an empty, successful experiment list.

Choose **Inspect trials** to load that candidate's registered physics report.
Select a case/evaluation seed, then use the observation slider, previous/next
buttons or **Last sample** to inspect the recorded trajectory. Root height and
root upright Z overlay the baseline and candidate on the same simulated-time
axis. The cursor reports their height, upright Z and contact count; the baseline
is matched by case, evaluation seed and optional reference origin, not report
array order. Its curve ends
at its own final observation. When no matching timestamp exists, the cursor
shows no baseline observation rather than interpolating one.

The evidence disclosure links the selected checkpoint and physics payload via
their MoonData URIs and checksums. The browser reads only these two registered
API surfaces; it does not start training or control a robot. Existing reports
do not all declare joint/target index mapping or include world-model rollouts, so
this viewer does not invent missing tracks. New reference reports include their
full planned root-height/upright curves and body/root-position errors; the
inspector displays those with per-trial tracking metrics. It is a simulator trajectory inspection
tool, not a 3D animation or qualified skill selector.

When a follow-up is registered, **Recorded evaluation** switches its trace and
displays the original qualification duration plus follow-up outcomes. The
[goal-coverage experiment](G1_GOAL_COVERAGE.md) is registered as `goal-refinement`:
seed 1 passes two-second trials but fails every ten-second extension. Both
results stay visible; the original `producer_qualified` flag refers only to its
reported two-second criterion. Old sources need no migration.

The [ten-second study](G1_LONG_DURATION_STUDY.md) is registered as
`long-refinement`. All three selected actors remain unqualified and each falls
in all nine final trials. The inspector labels the original ten-second maximum
scope separately from each actual fall time.

The [diagnostic ablations](G1_DIAGNOSTIC_ABLATIONS.md) add four sources named
`h8-no-bootstrap`, `h8-bootstrap`, `h32-no-bootstrap`, and `h32-bootstrap`, plus
`invariant-refinement`. All preserve three failed candidates. The last source
stores the explicitly encoded v2 dynamics weights through the same byte-based
payload path; the registry does not interpret tensor encodings or grant release
approval.

The [counterfactual study](G1_COUNTERFACTUAL_STUDY.md) registers `branch-old-xy`,
`branch-old-invariant`, `branch-new-xy`, and `branch-new-invariant`. All four
retain three unqualified candidates; the augmented data and both model/critic
encoding settings stay in their original reports. The ten-second scope and
actual early falls are read through the same original-physics API.

The [physical-return critic study](G1_PHYSICS_CRITIC.md) registers
`critic-imagined` and `critic-physics`. Both remain unqualified. The latter seals
three `learning-critic-physics` binary payloads in addition to the usual reports,
weights and traces. Existing runs without those logs are unchanged.

The [actor-update study](G1_ACTOR_UPDATE_STUDY.md) adds `actor-lr-standard` and
`actor-lr-small`. Their earlier checkpoint selection is retained in the source
reports; both remain unqualified and use the existing physical-critic log payloads.

The [short-cycle study](G1_SHORT_CYCLE_STUDY.md) adds `cycle-fixed` and
`cycle-adaptive`. Its adapted models are saved per policy seed; the source report
records selected and latest model digests. Optional `learning-latest-dynamics-checkpoint`
payloads preserve rejected later models. Both methods retain all failures and
remain unqualified. Full compressed physical training records are also sealed.

The [paired-gradient study](G1_PAIRED_GRADIENT_STUDY.md) adds `paired-tail-on`
and `paired-tail-off`, holding each incoming model and critic fixed. Their
aggregate reports bind initial model digests per seed and retain unchanged
selected actors with all final falls. The incoming dynamics reports are
preserved as incoming diagnostics, alongside their selected/latest weights;
these runs do not claim new model fitting. The raw parameter-direction probe
remains a separate local research artifact, outside this registry slice.

The [sustained-model study](G1_SUSTAINED_MODEL_STUDY.md) registers
`sustained-old-model` and `sustained-new-model`, preserving the merged compressed
dataset and all three unqualified candidates in each cell. Policy reports
distinguish the verified model-training input from a shared actor replay and
retain the replay source/shard digests. No updated new-model actor is selected;
the old-model seed-zero update worsens fresh results slightly. Both failures
and retained incoming actors remain inspectable.

The [temporal-input study](G1_TEMPORAL_INPUT_STUDY.md) adds `temporal-frame`,
`temporal-history` and `temporal-preview`. These are actual finite-horizon
world-model policy updates, with the incoming supervised temporal actor as
each physics baseline. They reuse one declared world-model checkpoint and
retain its original fitting report; no dynamic-data refit is implied. Actor
replay and world-model training digests remain separate. Checkpoints use
`moonrobo.g1-temporal-actor.v1` and require the causal temporal runner; the
legacy loader rejects that format. All nine selected candidates remain
unqualified. The standalone supervised parents and student-label logs are
linked local research inputs rather than registered world-model runs.

The [temporal-value study](G1_TEMPORAL_VALUE_STUDY.md) adds
`temporal-frame-value-off`, `temporal-frame-value-on`,
`temporal-preview-value-off`, and `temporal-preview-value-on`.
The temporal actor checkpoint optionally embeds a declared finite-task value
network and its normalization/input spec; actor inference stays on its temporal
runner. Both arms retain calibrated values even when the tail is disabled.
Compressed `learning-critic-physics` records distinguish training and independent
value-audit roles. All candidates remain unqualified; update-zero actor selection
does not turn value calibration into a new control success.

The [replay-distribution study](G1_REPLAY_DISTRIBUTION_STUDY.md) adds
`temporal-teacher-value-frame` and `temporal-teacher-value-preview`. These
teacher-only actor-start refinements retain the same physical value-calibration
budgets and initial weights as the prior mixed-tail cells. Every candidate is
unqualified; two selected one-step preview actors are verified against the
saved diagnostic directions. Re-scored prior policies use the same new final
seeds, with their original training history retained. Frozen-direction probes
remain local diagnostics outside the training registry slice.

## Verified Local Results

The first feedback run and latest completed warm-start run were registered as
`first` and `warm` under `target/learning/experiment-book/moondata`. Both contain
three selected candidates. All six remain unqualified:

| Experiment | Training seed | Mean survival (s) | Falls / trials | Joint RMSE (rad) |
| --- | ---: | ---: | ---: | ---: |
| first | 0 / 1 / 2 | 1.2400 | 9 / 9 each | 0.0971 |
| warm | 0 | 1.4844 | 9 / 9 | 0.1154 |
| warm | 1 | 1.4533 | 9 / 9 | 0.1200 |
| warm | 2 | 1.4711 | 9 / 9 | 0.1203 |

Survival increased, tracking error worsened, and every trial still fell. The
registry preserves all three observations. Catalog validation passed with zero
findings; this result concerns stored evidence, not controller performance.

To repeat registration and validation against those existing local runs:

```sh
moon run --target native scripts/verify_learning_registry.mbtx /absolute/path/to/moonrobo /absolute/path/to/moonrobo/target/learning/experiment-book/moondata /absolute/path/to/moonrobo/target/learning/g1-policy-feedback /absolute/path/to/moonrobo/target/learning/g1-policy-warm-native
```

Package tests cover non-UTF-8 weight bytes, blob deduplication, repeated imports,
ID conflicts, reopening after removing the original run, corrupt summaries and
contradictory reported qualification. Host tests cover an uninitialized workspace
and a registered summary without changing the catalog.

The cockpit adds four interaction/numerical tests for case/seed pairing,
missing observations, evidence binding, stale requests and read failure. All
118 active cockpit JavaScript tests and 76 Rabbita package tests passed;
one existing JavaScript test is skipped. The release build completed.
Browser checks used the actual `first`/`warm` records at desktop, 375 × 812
and 812 × 375 viewports. Keyboard cursor movement and Esc focus restoration
passed. The cockpit currently declares a light color scheme; this change adds
no animation. The research data-only RoboBook has no `robot.json`, so its
underlying cockpit uses the existing sample/error fallback; that header is not
G1 readiness evidence. The learning dialog reads the actual registered records.

Initial registry-slice verification on 2026-10-23: all 884 native repository tests passed. `moon info`
completed with zero errors and the new package/script formatting completed;
existing repository/toolchain warnings remain.

The comparison and failed-trial viewer now uses those references. Job submission,
review/adoption, complete model/body compatibility, aligned reference/model
tracks and a qualified controller remain outstanding. General recovery,
retention and migration extensions stay deferred until a concrete consumer
needs them.
