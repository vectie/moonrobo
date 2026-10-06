# Digital trial receipt inspection

The cockpit's **Digital trials** panel accepts an exact MoonMoon mission-study
envelope plus one exported result. Import preserves the original bytes in the
existing MoonRobo product proof-session home. It records an inert receipt
attempt, not a device command. The panel can reopen the same trial, inspect its
proof and blockers, annotate an acknowledgement-loss exercise, reconcile that
same receipt, and export a reviewed incident for MoonBook.

## State and authority

- `digital_result_state` is `digital-ready` only when the imported MoonMoon
  result is accepted. It describes a bounded digital result, never hardware
- `binding_state` compares current local profile, URDF, design validation and
  declared calibration source bytes with the frozen study. Missing evidence or
  unqualified calibration is `unknown`; changed bytes are `blocked`
- `state` also retains simulation blockers and unresolved receipt uncertainty
- `acknowledgement_state` concerns only this local digital import. The
  `lost-ack` exercise records uncertainty; `reconcile` requires the original
  exact result bytes and a named review on the same attempt. It cannot reconcile
  a physical command, make telemetry appear, or grant another command attempt
- Physical execution and automatic retry are always false. The existing grant,
  qualified-platform, bridge, stop and takeover gates are unchanged

The included MoonMoon fixtures are real outputs of its local digital test
study. They are not E1 evidence or external lunar truth. Their calibration is
explicitly unqualified, with a missing declared calibration manifest. The
accepted result therefore has a digital-ready result but an unknown overall
current binding. No manifest or physical proof is fabricated to make it ready.

## Direct host API and command

`POST /api/moonrobo/digital-trials/import` accepts
`{trial_id, session_id, dossier_text, result_text}`. Result and source strings
are compared and retained exactly, including whitespace. `GET
/api/moonrobo/digital-trials/{trial_id}` replays immutable event files and
rechecks current local bindings.

`POST /api/moonrobo/digital-trials/event` accepts `{trial_id,
expected_revision, event_id, kind, proof_text, reviewer, note, now_ms}`. `now_ms`
uses the MoonBit Int64 JSON string form. Kind is `lost-ack`, `reconcile`, or
`review`. Reconcile requires exact result bytes, reviewer and note. Review does
not clear an unknown acknowledgement. Events append to the existing record;
exact event replays return that event's existing identity. Changed replay,
stale revision, corrupt or partial files require inspection and never silently
overwrite prior evidence.

`POST /api/moonrobo/digital-trials/export` accepts `{trial_id}`. The latest event
must be a named review of a failed result or acknowledgement-loss incident.
Export does not mutate the trial.

The `cmd/digital_trial` executable provides these same direct handlers without
a listener: `import <root> <request.json>`, `inspect <root> <trial-id>`,
`event <root> <event.json>`, and `export <root> <trial-id>`.

## MoonBook boundary

The export envelope contains the existing
`moonbook.bookkeeper.product_outcome_submission.v1` contract and exact result,
dossier, attempt-history and named-review evidence bytes. Robo's reviewer name
is an attribution, not an authenticated Book acceptance. Receipt absence is
represented by `book_receipt: null` and `retention_state: pending-book-review`.
The candidate guidance is the review note; producer gap statements are bounded
claims for Book review, not independently reviewed findings.

Import the submission through Book's existing governed product-outcome flow.
Its own deliverable and assessment review gates remain mandatory. A reusable
`moonbook.outcome-lesson.v1` additionally needs exact durable outcome and
accepted-assessment references, explicit applicability, and separate lesson
review. This exporter cannot invent those records, mark retention confirmed,
or activate capability changes. It does not contact Book or claim delivery.

## Qualification limits

This is single-writer local-file persistence. Readback and immutable replay
detect partial/conflicting bytes; fsync, power-loss, multiple writers, browser
deployment, physical telemetry, authentic operator identity and hardware
safety are not qualified. Integrity hashes identify bytes, not trusted origin.
Receiver validation checks digital contract bindings; scientific recomputation
remains MoonMoon's native study inspection operation. Inputs have the existing
8 MiB dossier and 1 MiB result/source bounds; files may be read before checking
size. No source paths are executed. MoonProp and Mooncake are outside this work.
