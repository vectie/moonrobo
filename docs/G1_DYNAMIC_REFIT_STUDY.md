# G1 World-Model Refit From Temporal Actual-Action Data

Updated: 2026-10-23. This follows the [dynamic-state diagnostics](G1_TEMPORAL_GRADIENT_STUDY.md).
The comparison replaces half of a fixed fitting budget's old-data samples
with already collected temporal teacher/student actual-action samples. Both
arms start from the same sustained-world-model seed zero and preserve its
normalization. This separates the replay-mixture change from additional
optimization and changed units; it does not establish policy efficiency or
qualified control.

All six runs select updated models. Mixed replay substantially reduces dynamic
32-step prediction MSE relative to old-only further fitting, while its canonical
prediction is slightly worse than that control. Longer physical return improves
in only 8/18 mixed model/actor batches versus 9/18 old-only batches. Better
dynamic prediction therefore does not yet yield reliable policy improvement.

## Data Without Another Large Merged Export

The new replay uses all 36 temporal teacher episodes and all 1296 student
episodes from the three input variants, three policy seeds and eight rounds.
The [preparer](../scripts/prepare_g1_dynamic_replay.mbtx) streams each compressed
student JSONL record, validates its dataset with the canonical native MoonBit
reader, checks common physical axes/model/cadence, global unique episode IDs
and train-family ownership, then removes the temporary chunk. All 73 source
datasets are checked. Native validation samples endpoint output only after
parsing/checking every transition, rather than treating samples as full-data
validation. Declared train families exclude canonical sway/wave generators.

The small `moonrobo.g1-actual-action-streams.v1` manifest binds the ten complete
source files by SHA-256 and records all native chunk counts. Source compressed
logs remain unchanged. It references the existing original 15,002-window
sustained replay by its verified shard-manifest digest. No giant merged JSON
or duplicate eight-step transition export is created.

The numerical reader verifies those exact source bytes and native counts,
extracts only `state`, `applied_action`, `next_state`, time and context, and
materializes tensors in memory. `teacher_action_targets` never enter model
fitting. Eight-step windows use stride eight with the final complete window
retained; gaps and reset boundaries remain excluded. Short failed episodes
remain in the source/counts even when they produce no complete window.
The parent layout describes physical channel bindings; the new stream manifest
and per-arm training-input digest identify the actual composite training input.
This is a local fitting-provider input, not a new generic MoonData export API.

## Controlled Further Fitting

Each arm has three sampling seeds, the same 2000 Adam updates, batch 128 and
learning rate 0.0003. `old-only` samples entirely from the old replay; `mixed`
uses 64 old and 64 new windows per update. The old index draws are coupled
between arms, with a separate generator for new indices. Both use the same
incoming network weights and architecture. All six models retain identical
state/action/context normalization buffers.

Canonical validation physics data selects the dynamics checkpoint every 200
updates, including the incoming model at update zero. The score retains the
previous 50/50 global/after-two-seconds validation MSE weighting. Canonical test
arrays remain unchanged and never select weights. These existing late held-out
sets remain sparse; the experiment does not turn them into a broad dynamic
validation library. Selected and latest checkpoints are retained separately.

Each checkpoint keeps the standard residual-dynamics inference format and a
new training-input digest. Its input spec names the parent replay/checkpoint,
the mixture arm and, for `mixed`, the exact added stream manifest. It does not
relabel the old model as if it had already trained on this collection.

The added data contains 390,235 actual transitions and yields 49,379 complete
windows, including 32,086 starting at or after two seconds. These counts retain
all 1332 episodes and all failures. The original replay remains separate.

## Selected Models And Prediction Results

These scores all use the incoming sustained model's **own frozen state scale**.
They differ from the older study's common-scale table, which used an earlier
model's scale. Cross-table raw normalized scores must not be mixed. Canonical
validation has 934 windows, test 916; late test has only three.

| Arm / sampling seed | Selected update | Validation MSE | Test MSE | Late test MSE |
| --- | ---: | ---: | ---: | ---: |
| Incoming model | 0 | 0.56179 | 0.94889 | 0.65525 |
| Old only / 0 | 1800 | 0.29582 | 0.64721 | 0.47201 |
| Old only / 1 | 2000 | 0.28790 | 0.63530 | 0.46205 |
| Old only / 2 | 1600 | 0.30464 | 0.65933 | 0.50929 |
| Mixed / 0 | 2000 | 0.33521 | 0.68639 | 0.49008 |
| Mixed / 1 | 1800 | 0.34395 | 0.70012 | 0.49829 |
| Mixed / 2 | 2000 | 0.33561 | 0.68708 | 0.48120 |

Both further-fitting arms improve canonical prediction relative to the incoming
model. Old-only is better globally on this held-out suite. This avoids assigning
all gains from further optimization to the newly added data.

On the same saved dynamic origins, replaying actual recorded controls gives:

| Model | Frame dynamic H32 MSE / 39 windows | Preview dynamic H32 MSE / 28 windows |
| --- | ---: | ---: |
| Incoming | 0.67362 | 0.91362 |
| Old only / 0 | 0.76039 | 1.11592 |
| Old only / 1 | 0.72090 | 1.08637 |
| Old only / 2 | 0.65975 | 0.98179 |
| Mixed / 0 | 0.32709 | 0.60115 |
| Mixed / 1 | 0.30844 | 0.59857 |
| Mixed / 2 | 0.32253 | 0.61080 |

Mixed replay improves this dynamic MSE for every sampling seed versus its
old-only control. Endpoint errors exclude absolute root X/Y, consistently with
the preceding diagnostics. Only actual complete physical prefixes contribute;
early falls do not get invented H32 targets. All one/eight/32-step values and
root-height errors remain in the report. Not every physical coordinate improves:
preview seed-two root-height MAE slightly worsens despite its lower overall MSE.
Unselected final-update predictions are retained separately as diagnostics and
do not replace the validation-selected models.

## Physical Direction Comparison

After fitting, every selected model is tested on the same 111 saved training
origins from the preceding probe, across all six incoming frame/preview actors.
The original report hashes bind their integration states, histories, reference
phases and verified physical baselines. They do not enter fitting or checkpoint
selection. Both old-only and mixed arms use all three model sampling seeds.

The comparison replays actual controls for one/eight/32-step open-loop error,
then computes a fresh H32 on-policy Adam actor direction for each model/actor
pair. Restored physics measures −0.1/0/0.1/1 times that direction, retaining
local and original-ten-second-episode remaining returns separately. All model
parameters stay frozen. No policy checkpoint is selected or promoted by this
diagnostic, and repeated origins remain correlated.

The six actor batches per model are frame/preview × policy seeds 0/1/2, each
with its fixed origin batch. At multiplier one of a fresh on-policy Adam step:

| Arm / sampling seed | Positive local-return batches / 6 | Positive remaining-return batches / 6 | Mean local Δ | Mean remaining Δ |
| --- | ---: | ---: | ---: | ---: |
| Old only / 0 | 3 | 3 | +0.00273 | +0.67788 |
| Old only / 1 | 3 | 3 | −0.00048 | +0.17157 |
| Old only / 2 | 4 | 3 | +0.00086 | −0.08063 |
| Mixed / 0 | 5 | 4 | +0.01820 | +0.79962 |
| Mixed / 1 | 3 | 2 | +0.02765 | +0.41139 |
| Mixed / 2 | 4 | 2 | +0.00120 | +0.30166 |

Means above give each actor batch equal weight, not each individual origin.
Mixed gives positive local means in 12/18 combinations versus 10/18 old-only,
but positive remaining returns in only 8/18 versus 9/18 old-only. Dynamic-only
subsets, excluding stand, have 8/18 versus 11/18 positive remaining means.
These correlated combinations are diagnostic counts, not independent success
trials or a significance test. Mixed improves some mean magnitudes without
making every direction useful; a positive aggregate conceals regressions.

## Reproduction

```sh
moon run --target native scripts/prepare_g1_dynamic_replay.mbtx /absolute/path/to/moonrobo /absolute/path/to/moonrobo/target/learning/g1-sustained-replay /absolute/path/to/moonrobo/target/learning/g1-temporal-input-study /absolute/path/to/moonrobo/target/learning/g1-dynamic-replay
moon run scripts/fit_g1_dynamic_refit.mbtx /absolute/path/to/moonrobo /absolute/path/to/moonrobo/target/learning/g1-dynamic-replay /absolute/path/to/moonrobo/target/learning/g1-sustained-replay /absolute/path/to/moonrobo/target/learning/g1-sustained-model-study/new-fit /absolute/path/to/moonrobo/target/learning/g1-dynamic-refit
moon run scripts/probe_g1_dynamic_refit.mbtx /absolute/path/to/moonrobo /absolute/path/to/moonrobo/target/learning/g1-dynamic-refit /absolute/path/to/moonrobo/target/learning/g1-temporal-probe /absolute/path/to/moonrobo/target/learning/g1-temporal-input-study /absolute/path/to/moonrobo/target/learning/g1-sustained-model-study/new-fit /absolute/path/to/moonrobo/target/learning/g1-dynamic-refit-probe
moon run --target native scripts/report_g1_dynamic_refit.mbtx /absolute/path/to/moonrobo/target/learning/g1-dynamic-refit /absolute/path/to/moonrobo/target/learning/g1-dynamic-refit-probe /absolute/path/to/moonrobo/target/learning/g1-temporal-probe /absolute/path/to/moonrobo/output/research/g1-dynamic-refit-study.json
```

Use fresh preparation/fitting/probe directories. Scripts freeze source files,
configuration and charters before their numerical workers run. Thirty-four
numerical tests exercise the new stream reader, actual-action/label separation,
stride/gap/endpoints, source binding, held-out rejection, selected/latest input
identity and frozen normalization, alongside existing gradient/physics tests.
Ten relevant MoonBit data/registry tests pass. No public MoonBit API changes or
hardware operations are introduced.

The [verified study report](../output/research/g1-dynamic-refit-study.json)
retains both fitting histories, input digests, identical initial validation,
selected/latest model bindings, canonical held-out scores, every physical
comparison subset and selected/unselected open-loop diagnostics. This is a
world-model fitting/diagnostic study, without new policy selection or fabricated
policy-registry entries. Existing temporal policy results remain unchanged.

The subsequent [temporal-value study](G1_TEMPORAL_VALUE_STUDY.md) adds physically
calibrated finite-task value with history, planned reference and remaining time.
Initial independent value MAE improves, and the tail changes some restored
directions favorably. The full matched tail/no-tail training comparison still
fails every wave trial; five of six tail-enabled actors retain update zero.
The next comparison isolates teacher/current replay directions before another
sweep. Stable all-case learned control, matched PPO efficiency and full phase
acceptance remain incomplete.
