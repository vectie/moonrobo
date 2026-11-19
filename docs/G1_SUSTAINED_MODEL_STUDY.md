# G1 World-Model Refitting With Sustained Transitions

Updated: 2026-10-23. This follows [teacher initialization](G1_TEACHER_INITIALIZATION.md).
All new teacher/student physics transitions now feed a world-model refit and
a paired actor-update comparison. Global prediction improves on a common
scale, sparse late prediction worsens, and no new-model actor update is
selected. The best incoming actor still completes six of nine ten-second
canonical trials and fails all wave trials. No learned candidate qualifies.

## Full Replay, Smaller Window Duplication

The derived `g1-sustained-augmented` dataset retains the original 264 episodes
and adds all 24 teacher episodes plus all 360 student-controlled aggregation
episodes: 648 episodes and 120,023 actual transitions in total. New train data
contributes 103,674 transitions. Only recorded `applied_action` values enter
dynamics fitting. Counterfactual `teacher_action_targets` remain in the source
logs and are excluded from the model dataset.

The [native builder](../scripts/build_g1_sustained_replay.mbtx) checks joint/model
layouts, cadence declarations, unique episode IDs and original reference-family
ownership across every source. All appended episodes must belong to an already
owned training family. The original validation/test episodes remain unchanged.
Re-exported arrays for all 934 validation and 916 test windows match the
previous arrays column by column, including window refs, inputs, goals,
rewards and termination/truncation flags. Dataset ID/provenance headers name
the new derived version; full-file hashes consequently differ.

The old one-step-overlapping window export would repeat most of this larger
dataset eight times. `MotionDataset::windows` now accepts optional positive
`stride`, default one. Coarse export retains the last complete window of each
episode even when it is off the stride grid, preserving valid episode-end
labels. Gaps and episode boundaries remain unfilled; episodes shorter than
the requested window remain in raw data without fabricated windows. Default
stride-one output is unchanged.

The new train export uses eight-step windows, stride eight and endpoint
retention. It yields 15,002 windows: 6744 starting before two seconds and 8258
at or after two seconds. All source episodes remain in the raw dataset;
window extraction is explicit and reconstructible rather than silently
dropping failed trajectories.

## An Observed Export Limit And The Working Data Path

An initial whole-blob native export crashed on the approximately 697 MiB
merged JSON input and produced empty output. An earlier direct async pipe
also caused gzip to exit on nonblocking input. None of those failed outputs
was consumed by a trainer. The working path exports 32 source-sized chunks:
the original dataset, the teacher collection and each of 30 student batches.
Each chunk is independently parsed/validated by the existing native reader,
with the additional global identity/family checks above. It does not claim
that arbitrary large JSON parsing has been fixed.

Each shard is an ordinary `moonrobo.training-batch.v1` JSON batch compressed
with gzip. A small `moonrobo.training-batch-shards.v1` train manifest records
the common layout/horizon plus relative file, logical SHA-256 and window count
for each shard. The numerical `WindowBatch` loads every listed shard, verifies
its digest/layout/count and concatenates its tensors. There is no episode
joining during concatenation: each already-materialized window is complete.

Flat JSON batches remain supported. Flat `.json.gz` uses the uncompressed
JSON digest as its logical training identity, so archived legacy inputs still
match existing model checkpoints. Storage-byte hashes are separate. A shard
manifest's digest binds its verified child digests and becomes that training
input's identity. This is a local numerical-reader format, not a new public
MoonData catalog or job protocol.

The complete merged dataset is retained as `collection/dataset.json.gz`
(approximately 123 MiB). All source logs, excluded teacher labels and manifests
remain available. The experiment importer now accepts that fixed compressed
dataset path when the existing uncompressed path is absent, using the same
byte-preserving `learning-transition-dataset` payload kind. Registration does
not parse the archive; dataset validation belongs to the builder. Existing
raw-dataset imports retain their behavior.

## World-Model Fit And Common-Scale Prediction

Three fresh invariant residual models use the same two-layer 128-wide network
and eight-step autoregression as before. Each has 1000 Adam updates, batch 128,
learning rate 0.001, with half early and half late train-window sampling.
Normalization uses only the new train tensors. Selection uses the original
validation arrays, weighting global and late validation MSE equally. All
three select update 1000, beat state persistence, pass frozen-parameter input
gradient checks and reload identically. Late held-out coverage is still just
eight validation and three test windows; these are sparse overlapping windows.

Because normalization changes, each model's own normalized error cannot be
compared directly with the old fit. A separate post-selection diagnostic scores
both models using the **old model's state scale** on the same held-out arrays:

| Model | Validation MSE | Test MSE | Late validation MSE | Late test MSE |
| --- | ---: | ---: | ---: | ---: |
| Old shared model | 0.14306 | 0.26736 | 0.01602 | 0.18211 |
| New fit / 0 | 0.12650 | 0.24583 | 0.07608 | 0.22588 |
| New fit / 1 | 0.12506 | 0.24615 | 0.07882 | 0.22315 |
| New fit / 2 | 0.12241 | 0.24367 | 0.07623 | 0.24701 |

Global error improves, while every refit worsens the sparse late sets. These
scores establish neither physical derivative agreement nor stable control.
The new fit also changes data, window sampling, normalization and fitting
budget relative to the old 400-update, batch-64 checkpoint; there is no isolated
data-only effect or matched-efficiency claim.

## Same Policy Replay And Physical Critic Supervision

The frozen comparison uses three selected dataset-aggregation actors in both
cells. `sustained-old-model` uses the old world-model seed zero;
`sustained-new-model` uses new fit seed zero, fixed in advance. Both actors
sample from the same new 15,002-window replay and retain their incoming
normalization. Model parameters remain frozen throughout policy training.

The explicit `--policy-replay` argument allows a compatible derived actor
replay while still verifying the separate model-training input against its
checkpoint. Body/model, cadence, frame and axes must agree; source dataset ID
may differ. Policy reports retain both model-training and actor-replay digests.
Without this optional argument, the old strict same-input path is unchanged.
The old compressed train batch is loaded and logically hash-checked rather
than relabeled as if the old model had learned from the new data.

Incoming critics were explicitly zero-output/untrained. Both cells now fit
physical soft-return targets before the first actor step and every 20 actor
updates: six constant-goal train cases, 400 optimizer steps per refresh, batch
512, ten refreshes and 4000 critic steps per seed. Reset seed is
`3200 + 10000 * policy_seed + refresh_index`. Initial collection, targets'
producing actor, training MAE before/after calibration and initial actor
validation are identical between cells. Later physical data changes as the
actors diverge. Supervision on those training samples is not an independent
critic-accuracy guarantee.

Each seed has 200 actor updates, batch 64, learning rate 0.0003, 32 imagined
steps and terminal critic bootstrap. Validation seeds 30–32 select at updates
0/1/5/10/20/50/100/150/200, including the incoming actor. Fresh final seeds
8600–8602 never select weights. Independent incoming scoring uses those same
final conditions:

| Method / seed | Selected update | Incoming → selected survival (s) | Incoming → selected RMSE (rad) | Falls / 9 |
| --- | ---: | --- | --- | ---: |
| Old / 0 | 1 | 4.7867 → 4.7600 | 0.05832 → 0.06114 | 9 |
| Old / 1 | 0 | 6.7067 → 6.7067 | 0.05032 → 0.05032 | 7 |
| Old / 2 | 0 | 7.3289 → 7.3289 | 0.04767 → 0.04767 | 3 |
| New / 0 | 0 | 4.7867 → 4.7867 | 0.05832 → 0.05832 | 9 |
| New / 1 | 0 | 6.7067 → 6.7067 | 0.05032 → 0.05032 | 7 |
| New / 2 | 0 | 7.3289 → 7.3289 | 0.04767 → 0.04767 | 3 |

New-model refinement selects no updated actor. The old model selects one
update that slightly worsens fresh survival and tracking. Unchanged actors'
physical traces match their independently re-scored incoming traces exactly.
Seed two still completes stand/sway 3/3 each and falls in every wave case;
no candidate meets zero falls over all nine ten-second trials with mean
RMSE at most 0.15 rad. Repeated incoming actors are not new learned successes.

## Reproduction, Evidence And Remaining Work

```sh
moon run --target native scripts/build_g1_sustained_replay.mbtx /absolute/path/to/moonrobo /absolute/path/to/moonrobo/target/learning/g1-counterfactual-study/augmented /absolute/path/to/moonrobo/target/learning/g1-balance-teacher-data /absolute/path/to/moonrobo/target/learning/g1-teacher-aggregation /absolute/path/to/moonrobo/target/learning/g1-sustained-replay
moon run scripts/fit_g1_sustained_policy.mbtx /absolute/path/to/moonrobo /absolute/path/to/moonrobo/target/learning/g1-sustained-replay /absolute/path/to/moonrobo/target/learning/g1-counterfactual-study/augmented /absolute/path/to/moonrobo/target/learning/g1-teacher-aggregation/policy /absolute/path/to/moonrobo/target/learning/g1-sustained-model-study
moon run scripts/verify_g1_sustained_policy.mbtx /absolute/path/to/moonrobo /absolute/path/to/moonrobo/target/learning/g1-sustained-model-study /absolute/path/to/moonrobo/target/learning/g1-teacher-aggregation/policy /absolute/path/to/moonrobo/target/learning/experiment-book/moondata /absolute/path/to/moonrobo/output/research/g1-sustained-model-study.json
```

Use fresh output directories. All configurations and provider sources are
frozen before fitting. The [verification report](../output/research/g1-sustained-model-study.json)
retains configurations, all validation checkpoints, physical training records,
fresh outcomes, common-scale predictions and MoonData refs. Both cell IDs above
are registered through the existing read-only experiment/cockpit path, with
the compressed merged dataset, selected/latest actors, world-model weights and
compressed critic training episodes. Full MoonData validation has zero findings.
Registration and successful model diagnostics grant no execution authority.

Twenty-five numerical tests and all 887 native tests pass. New regressions
exercise strided endpoint/gap behavior, gzip/logical identity, shard tensor
equivalence and tampering, explicit cross-dataset body compatibility, common
prediction scaling and compressed dataset byte preservation after removing its
source. The expected public MoonBit API addition is optional `stride` on
`MotionDataset::windows`; the experiment API is unchanged.

The subsequent [temporal-input study](G1_TEMPORAL_INPUT_STUDY.md) implements
causal histories, future commands and changing-goal imagined rollouts. Its
best frame-only model-refined run completes one wave trial while still failing
the other two; histories and preview do not consistently improve results.
Those comparisons do not establish temporal input as the sole cause of these
failures. Stable all-case learned control, matched PPO efficiency,
complete workbench/E1 phases and physical qualification remain unfinished.
General production hardening stays deferred.

For disk space, the previous augmented `train-batch.json` and uncompressed
collection datasets in the two physical-critic, two actor-rate, two short-cycle
and two paired-tail study cells were losslessly archived as `.json.gz`.
Original weights, reports and registered BlobStore payloads remain intact.
Restore those old JSON paths with `gzip -d` before workflows or repeated imports
requiring them. The new source logs, shard manifest and compressed dataset are
retained; the large failed export artifacts were removed after terminal errors.
