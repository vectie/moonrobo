# Reference Learning Results In MoonData

Updated: 2026-10-23. The [actor-state origin comparison](G1_REFERENCE_STATE_ORIGINS.md)
now has two registered experiment entries and a verified cockpit comparison.
All six final policies remain unqualified. Two individual trials in trajectory
seed 2 meet the fixed limits; completing a trial alone does not establish this.

The counts below describe this three-cycle integration. The subsequent
[six-cycle replay integration](G1_REFERENCE_REPLAY_PLATFORM.md) adds the FIFO
and initial-anchor comparison without replacing these historical entries.

## Recorded comparison

| Experiment ID | Actor imagination origins | Baseline in its trial inspector | Falls per seed / 27 |
| --- | --- | --- | --- |
| `reference-reset-origin` | Episode resets | Shared zero-output incoming actor | 27 / 27 / 27 |
| `reference-trajectory-origin` | Current-cycle recorded physical states | Same-seed trained reset-only actor | 27 / 27 / 24 |

Each entry exposes three final actors after 36 actor steps each. No intermediate
checkpoint is newly selected. The trajectory entry compares against the actual
trained reset baseline, rather than comparing both methods only to their incoming
prior. The original paired study and its independent verification remain bound
to SHA-256 `c9713dd0cdc6118d83c598a05120fbda15f7e29e946c57387704217d34c95387`.

Both entries preserve the same complete paired corpus of 603 numeric episodes /
152,776 transitions: 243 new episodes / 66,414 transitions and 360 reused episodes /
86,362 transitions. Registering the same bytes twice does not create independent
physical evidence; the existing content-addressed BlobStore shares them.

The [reset registration](../output/research/g1-reference-reset-registration.json)
and [trajectory registration](../output/research/g1-reference-trajectory-registration.json)
retain import, idempotent reimport, API round-trip and whole-store validation
evidence. No physical execution authority is granted.
Final whole-MoonData validation passes with zero findings, blockers or warnings
and 64 catalog entries. The book now has 44 registered learning experiments;
catalog entries also include their stored source/summary records.

## Evidence and producer

`moonrobo.g1-reference-learning-fit.v1` uses the existing experiment registry.
Its additional `moonrobo.g1-reference-learning-evidence.v1` manifest binds:

- All nine original full-body reference clips, their manifest and source physics.
- All 603 compact numeric physical archives, including failures and reused records.
- Actor, dynamics and value weights from all three cycles of all six paired runs.
- Final actor aliases, incoming actor, fixed quality targets, frozen charter,
  original study, inherited baseline report and native verification.
- Frozen numerical providers, common-fit equality, origin sampling and gradient
  checks, plus three per-seed compact viewer reports.

Import checks original record hashes/counts, reference and provider bindings,
the source hash in native verification and all declared evidence files. Missing
cycle weights or mismatched bytes fail import. Existing producer formats and
public MoonBit APIs are retained.

`collection/dataset.json.gz` is one actual common first-training episode with
the 338-channel reference goal. It is explicitly a representative reader input,
not the complete training corpus. All original physical archives and reference
clips remain available separately. Source controls in the inherited reference
assets are not RL actor or dynamics supervision labels in this study.

The evidence retains cycle weights, not a complete optimizer, replay-buffer and
simulator snapshot for exact training restart. Simulator assets are not newly
archived. Export/registration use independent APFS clones on this local host to
preserve existing bytes/paths without duplicating every extent; this is not a
portable copy utility or a BlobStore change.

## Actual cockpit behavior

Open **MoonData → Learning experiments**, then inspect
`reference-trajectory-origin`, training seed 2. The inspector shows:

- The same-seed trained reset-only baseline and the 30/20/10-second remainders.
- **2/27 individual trials meet all fixed tracking limits**, separately from
  **Full recorded suite: not qualified**.
- A shortcut to the first trial meeting every limit; it is hidden when none do.
- Per-trial completion, joint/body/root position and root angle limits, with
  textual failure reasons. A completed trial with excessive error stays failed.
- Dashed baseline physics, solid candidate physics and dotted full planned
  reference. Physics ends at its actual termination; the reference continues.
- Root angle error curves as well as root height, upright and position errors.

The medium-friction pose trial starts at reference20 s and completes its
remaining10 s, while its trained reset baseline falls at6.10 s. Joint/body/root
position/root angle RMSE are 0.02290 rad /0.02293 m /0.02597 m /0.03787 rad.
The standard-friction completion lasts the same10 s but exceeds all four limits
(root angle0.15008 rad); it is visibly marked outside the tracking limits.
The origin0 stand trial falls at7.24 s, while its planned trace still spans30 s.

![Individual pass with the full policy still unqualified](/Users/kq/Workspace/moonrobo/output/research/g1-reference-origin-platform.png)

The [completed-but-inaccurate view](../output/research/g1-reference-origin-completed-error.png)
and [fall view](../output/research/g1-reference-origin-failure-platform.png)
preserve the other two cases. These are actual local browser captures. Full-body
3D, synchronized world-model prediction overlays and skill release remain open.

## Reproduce and verification

With the existing verified study and numerical runtime available:

```sh
moon run --target native scripts/export_g1_reference_learning_registry.mbtx /Users/kq/Workspace/moonrobo /Users/kq/Workspace/moonrobo/target/learning/g1-reference-state-origin /Users/kq/Workspace/moonrobo/output/research/g1-reference-state-origin.json replay-prefix /Users/kq/Workspace/moonrobo/target/learning/reference-trajectory-platform
moon run --target native scripts/register_g1_reference_registry.mbtx /Users/kq/Workspace/moonrobo /Users/kq/Workspace/moonrobo/target/learning/reference-trajectory-platform reference-trajectory-origin /Users/kq/Workspace/moonrobo/target/learning/experiment-book 1792730000000 /Users/kq/Workspace/moonrobo/output/research/g1-reference-trajectory-registration.json
MOONROBO_REFERENCE_HOST=http://127.0.0.1:5300 node --test ui/rabbita-cockpit/reference-registry.integration.test.mjs
```

Use `prefix-only` for the reset arm. The two live integration tests check all
twelve stored physical reports across the four reference experiments. New
reference numerical checks pass (14), registry native tests pass (11), and UI
checks pass (121, with three environment-dependent skips). Production UI build
succeeds with its existing large-chunk warning.

This completes this result-to-platform slice. Sustained full-reference learning,
broader motion coverage, successful matched model/PPO cost-to-target, the full
workbench and E1/hardware phases remain unfinished under the
[phase plan](SUPERMIMIC_PHASE_PLAN.md).
