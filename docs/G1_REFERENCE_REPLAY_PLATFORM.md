# Six-Cycle Reference Replay In MoonData

Updated: 2026-10-23. This integrates the
[initial-anchor comparison](G1_REFERENCE_REPLAY_ANCHOR.md) into the existing
learning experiment registry and cockpit. All six complete policies remain
unqualified. This is a small known-reference simulation study, not the complete
SuperMimic reproduction or a released general motion skill.

## Data and current scope

The development data path works end to end: nine thirty-second physics-derived
reference clips, numeric transition reading, model fitting, policy updates,
independent physics evaluation, MoonData storage and cockpit inspection. The
paired study contains **927 episodes / 284,781 transitions**, of which 603 /
173,984 are inherited and 324 / 110,797 are new. These are repeated physical
rollouts over nine known procedural references, not 927 distinct source motions.
Both experiment entries retain the same paired corpus; registration does not
double its independent evidence.

A large external motion collection, a general motion-library index, unseen-motion
evaluation and real-robot training streams remain unfinished. Full-body 3D and
world-model prediction overlays, complete job/recovery workflows, a successful
matched model/PPO cost-to-target comparison and E1 execution remain open.

## Registered comparison

| Experiment ID | Dynamics fitting pool | Inspector baseline | Individual passes per seed / 27 |
| --- | --- | --- | --- |
| `reference-recent-replay` | Recent FIFO, 20,000 windows | Shared incoming zero-output actor | 0 / 5 / 0 |
| `reference-anchor-replay` | All initial windows plus recent windows, 20,000 total | Same-seed trained six-cycle FIFO actor | 3 / 9 / 0 |

Each final actor has six cycles and 72 actor updates. Every trial retains its
0/10/20-second reference origin and the complete 30/20/10-second planned remainder.
The anchor inspector compares against the actual trained FIFO policy, including
identical baseline episode IDs and summaries to the FIFO entry's candidate.
It does not substitute the incoming prior for this trained baseline.

The source report is pinned to SHA-256
`a8308c60c8c1d9eb3e561eb667daac8736d7374989dd21e69182ebd0bd65ae25`.
Each export binds all 927 physical archives, nine reference clips, all 108 cycle
actor/model/value files across the six paired runs, selected final actors,
providers, the frozen charter, reconstruction, sampling and gradient evidence.
Import verifies the selected checkpoints against the original final checkpoint
digests and derives episode counts and optimizer steps from the actual study.

On this APFS development host, independent copy-on-write clones avoid duplicate
large file extents while retaining staged files, original paths and immutable
content-addressed blobs. Import still verifies each blob's bytes and size.
The BlobStore implementation and public MoonBit interfaces are unchanged by
this integration.

## Actual cockpit evidence

The existing trial inspector now includes training cycles, dynamics replay mode
and retained-window count in its evidence disclosure. For anchor seed 1 it shows
six cycles and 6,199 initial windows in the 20,000-window capacity. Text labels
separate individual quality passes from complete-suite qualification.

- [Thirty-second pass](../output/research/g1-reference-replay-platform.png):
  seed 1, pose-offset, origin zero; candidate completes 30 s, baseline falls at
  19.96 s. Joint/body/root-position/root-angle errors are approximately
  0.0126 rad / 0.0247 m / 0.0244 m / 0.0444 rad. The suite still reads 9/27 and
  not qualified.
- [Completed but inaccurate](../output/research/g1-reference-replay-inaccurate-platform.png):
  seed 2, medium-friction stand, origin zero; candidate completes 30 s but joint
  RMSE 0.0353 rad exceeds 0.03 rad. Its full suite has 16 completions and zero
  quality passes.
- [Physical failure](../output/research/g1-reference-replay-failure-platform.png):
  seed 1, stand, origin zero; candidate falls at 8.4 s and the planned reference
  continues through the requested 30 s.

The three seed-1 full thirty-second passes are correlated known pose conditions.
They do not establish unseen-motion generalization. No default policy or physical
execution authority changes.

## Verification

Registration evidence is recorded in the
[anchor receipt](../output/research/g1-reference-anchor-replay-registration.json)
and [FIFO receipt](../output/research/g1-reference-recent-replay-registration.json).
The registration script checks idempotent import, stored inspection, three
per-seed API reports against their exports and whole-store MoonData validation.
Both registrations complete successfully. Final whole-store validation passes
with **68 catalog entries and zero findings, blockers or warnings**. The live
cockpit lists **46 registered learning experiments**, up from 44 before this
pair; experiment count and catalog-entry count have different meanings.

The live integration checks exercise all eighteen reports across the six
reference experiments. They check actual trained-baseline identity, fixed
quality counts, complete planned remainders, provenance, retained windows and
the distinction between full-duration passes and inaccurate completions.
All three live checks pass with no skips. Eighteen reference numerical tests,
eleven native registry tests and the cockpit suite (121 passed, four skipped
without live configuration) pass. The production UI build succeeds; `moon info`
and scoped script formatting complete without new public interface changes.

```sh
MOONROBO_REFERENCE_HOST=http://127.0.0.1:5300 node --test ui/rabbita-cockpit/reference-registry.integration.test.mjs
```

The complete [phase plan](SUPERMIMIC_PHASE_PLAN.md) remains active; this result
completes the bounded comparison's platform connection, not a full phase gate.
