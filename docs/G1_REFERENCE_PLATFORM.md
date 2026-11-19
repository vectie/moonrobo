# Full-Body References And Policies In MoonData

Updated: 2026-10-23. Both [reference-initialization studies](G1_REFERENCE_INITIALIZATION.md)
now register their original motion clips, all compact physical trajectories,
checkpoints, quality targets, source and verification reports in the research
RoboBook. The actual cockpit reads both experiments through the existing API.
It pairs by reference origin and overlays the full planned root trajectory,
including the part after a policy falls. This is further SM-1.4/SM-4 progress;
3D body animation, world-model overlays, matched learning efficiency and released
skills remain unfinished.

The subsequent [learning result integration](G1_REFERENCE_LEARNING_PLATFORM.md)
adds the trained reset/state-origin comparison and per-trial quality status.
Counts and validation below describe the earlier initialization registration;
the new entries preserve that evidence and its viewer behavior.

## Recorded Experiments

| Experiment ID | New neural training seeds | Falls per seed / 27 | Provider's fixed reference gate |
| --- | --- | --- | --- |
| `reference-joint-initialization` | 0, 1, 2 | 16 / 11 / 13 | All fail |
| `reference-feedforward-initialization` | 0, 1, 2 | 0 / 0 / 0 | All pass |

Each study includes 108 actual episodes: three policies ×27 conditions plus
27 zero-output baseline conditions. All 216 original numeric records remain
available. The baseline is reused across three seed comparisons, not recounted
as 81 independent baseline conditions. The nine input clips and each clip's
0/10/20-second origins are correlated known training references. Passing the
engineering gate is not unseen-motion, noisy-sensor or hardware qualification.

Registration evidence is in the [failed-group record](../output/research/g1-reference-joint-registration.json)
and [passing-group record](../output/research/g1-reference-feedforward-registration.json).
All six stored physical reports reopen through the native host API and match
their exported reports exactly. The final whole-MoonData validation passes with
zero findings/warnings and sixty catalog entries. There are now forty-two
registered learning experiments; the larger catalog also contains their source
and summary entries.

## New Producer Contract

`moonrobo.g1-reference-policy-fit.v1` retains the existing per-seed run/summary
shape and `moonrobo.g1-reference-actor.v1` checkpoint bytes. It does not fabricate
a dynamics fit or use the old learned-balance producer name. The importer seals:

- `collection/reference/manifest.json`, all declared `clips/*.npz`, and the
  original `source-physics.jsonl.gz`;
- `collection/reference-quality.json` and `reference-feedback.pt`, preserving
  the exact inherited feedback input to initialization;
- `policy/reference-study.json`, `reference-verification.json` and
  `reference-charter.json`;
- every numeric file named by all study evaluation/baseline records beneath
  `physics/`, including failed and zero-output trajectories;
- the zero-output checkpoint, three selected/latest fitted checkpoints, seven
  numerical provider source files and three compact viewer reports.

The study pins reference, quality, feedback and provider hashes. The manifest
pins its clips/source physics. Each physical record pins its numeric file.
Import checks these bindings and requires native verification for the full
record count with the matching study hash. Unsafe or duplicate evidence paths,
missing records and mismatched bytes fail registration. Reimport is idempotent;
changed bytes under the same experiment ID remain rejected. No new public
MoonBit API or parallel artifact catalog is introduced.

`collection/dataset.json.gz` is only the **first evaluated policy episode**,
using the full 338-channel reference goal. It is not the fitting corpus. The
complete fitted state/control corpus is the nine reference clips. Each numeric
policy record preserves state, actual observation/control, next state, reward
and terminal flags; reference ID/hash/origin reconstruct the goals. Source
controls remain supervision labels, not inference goals.

Clips and compact physics seal as `learning-reference-clip` and
`learning-reference-physics`. Metadata/provider files use the corresponding
`learning-reference-*` kinds. Identical clip bytes are shared through the
existing SHA-256 BlobStore across both experiments. These references belong to
the learning-experiment source; this is not yet a standalone, searchable motion
library or deployed-skill registry. Simulator assets and a complete resumable
optimizer/environment snapshot are not newly archived by this integration.

## Actual Cockpit Behavior

Open **MoonData → Learning experiments → Inspect trials**. The two experiment
names above show their failures/passes independently. Pairing uses case,
evaluation seed **and reference start step**; seed7300 is the source reset,
not a replacement for the origin. The selector and summary display the origin
and requested remainder explicitly. The recorded evaluation is labelled
**Reference remainders (30/20/10 s)**, rather than twenty-seven thirty-second
trials.

The inspector shows per-trial joint/body/root-position/root-angle RMSE, plus
root-height, upright-Z and body/root-position-error curves. Baseline physics is
dashed, candidate physics solid and planned reference dotted, with a textual
legend and cursor readout. The reference curve is independently materialized
from the full clip remainder and continues to its planned end after a fall.
Physics traces end at their actual last sample; no post-fall states or
world-model predictions are fabricated. All clocks are elapsed time from the
restored origin, while labels retain the absolute reference origin.

Viewer reports contain compact diagnostic channels; full states, controls and
body references remain in the original NPZ payloads. This is not yet full-body
3D animation or a reference/physics/prediction comparison for every channel.
The comparison table's mean joint RMSE is the arithmetic mean of trial RMSEs;
the physical report separately preserves pooled metrics and all per-trial gate
results. Qualification uses every required trial and every frozen metric,
not only the displayed aggregate.

The running local host was checked in the actual in-app browser for both the
failed and passing group. A passing stand trial from origin20 s completes its
remaining10 s while the baseline falls at4.34 s. The failed joint-input stand
trial falls at4.58 s while its planned reference continues through30 s.

![Passing policy and reference remainder](/Users/kq/Workspace/moonrobo/output/research/g1-reference-platform.png)

The [failed-policy screenshot](../output/research/g1-reference-failure-platform.png)
also preserves the visible post-fall reference. The research book has no robot
profile; unrelated main cockpit controls show their existing unavailable-profile
state. This read-only experiment workflow does not configure a device or grant
physical authority.

## Reproduce

Run from the repository root, with the existing studies/model/runtime available.
The following uses new export directories and a new experiment ID:

```sh
moon run --target native scripts/export_g1_reference_registry.mbtx /Users/kq/Workspace/moonrobo /Users/kq/Workspace/moonrobo/target/learning/g1-reference-feedforward-initialization /Users/kq/Workspace/moonrobo/output/research/g1-reference-feedforward-initialization-study.json /Users/kq/Workspace/moonrobo/target/learning/reference-platform-new
moon run --target native scripts/register_g1_reference_registry.mbtx /Users/kq/Workspace/moonrobo /Users/kq/Workspace/moonrobo/target/learning/reference-platform-new reference-platform-new /Users/kq/Workspace/moonrobo/target/learning/experiment-book 1792720000000 /Users/kq/Workspace/moonrobo/output/research/reference-platform-new.json
MOONROBO_REFERENCE_HOST=http://127.0.0.1:5300 node --test ui/rabbita-cockpit/reference-registry.integration.test.mjs
```

The export/registration scripts use independent APFS clones on this host to
avoid duplicate extents while retaining generated file paths and bytes. After
sealing, they verify every replaced file against its BlobStore checksum. There
are no hard links to mutable originals and no BlobStore implementation change.
Each registration compacts274 generated source/package paths without changing
their bytes; shared source paths may occur in both runs. This is a local storage
choice, not a portable Linux copy utility.

Ten native registry tests, fifty-six numerical tests and the six-report live
HTTP/UI-contract integration pass. Existing UI unit checks pass; production
cockpit build succeeds with its existing large-chunk warning. `moon info`
finishes without errors or new public API changes; existing toolchain warnings
remain. Existing experiment formats, follow-up modes and false physical authority
are retained. The next research step is a matched learning charter from the
same nonpassing reference actor, with supervision and common prior costs
explicit, rather than claiming a speedup by refining an already passing actor.
