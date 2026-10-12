# Retained digital trial inspection

Open **Digital trials · inspection only** in the normal Rabbita cockpit, then
**Refresh retained trials**. Select one saved trial to inspect it, or select A
and B to compare. This catalogue is independent of the design-workbench design
comparison. Inspection is read-only; use the explicit continuation below to open
a selected trial in the existing review editor.

## Continue a selected trial into review

After inspecting A or B, choose **Continue to review trial A/B**. The editor
re-reads that exact trial through the existing host GET route and uses the newly
returned revision for later actions. The catalogue's historical inspection is
never used as the editor's current revision. The page moves to the trial ID in
the editor after a successful read.

If a different trial's editor has inputs or file selections, confirmation asks
before discarding them. Cancel leaves every input unchanged and makes no request.
Confirmed replacement occurs only after a successful, matching host response;
old file selections, reviewer name, event ID and note are cleared to avoid
applying another trial's proof or review. Continuing the same trial retains its
editor draft. A failed or invalid read retains inputs but clears the old active
inspection, so another read is required before recording an event.

Closing the dialog, changing that side's selection, or refreshing the catalogue
during the read cancels the handoff. Repeated clicks while it is pending do not
start another request. The two catalogue sides remain independent, and the
ordinary exact-ID **Re-open trial** route remains available.

Continuing records no review or reconciliation, imports nothing, and performs
no export. An unknown import acknowledgement remains unknown until the separate
explicit reconciliation action has matching frozen-result proof and a named
reviewer. Review and pending-Book export remain explicit existing actions; this
workflow never grants physical authority or confirms Book acceptance.

## Evidence boundaries

- The frozen accepted/rejected result, blockers, limitations, robot revision,
  dossier/result/baseline/artifact digests, native recorded metrics, provenance
  references and verified replay receipt are read from the retained import
- Current local profile, URDF, validation and qualified calibration bindings are
  rechecked on each selection. Changed or unavailable current files never rewrite
  the frozen outcome
- The import acknowledgement, named reviews and ordered inert events are shown
  separately. Lost acknowledgement is not a failed physical command; reviews do
  not change the frozen result, current binding or physical authority
- The complete host JSON remains available in a raw-evidence disclosure for each
  side. Imported text is rendered as text, never HTML
- Physical authority and automatic retry remain false. Inspection does not run
  a simulator, replay evidence, repair files, mutate events, dispatch devices,
  contact providers or acknowledge MoonBook retention

## Comparison

Only matching, native-verified baseline digests permit numeric deltas. Deltas
are B minus A, with units; they are descriptive, without ranking or readiness
inference. Different or unverified baselines retain side-by-side values with
all numeric deltas unavailable. Frozen accepted/rejected labels remain the
original result labels, not a new comparison verdict.

The v1 native projection supports distance (m), duration (s), maximum measured
segment slope (deg), waypoints and deliveries (counts), and required, available
and margin energy (Wh). Missing, nonnumeric, nonfinite, duplicate, wrong-unit or
unsupported metrics are unavailable. No metric is re-simulated or coerced to
zero. The broader terrain blocker and frozen limitations remain visible even
when an enumerated-path result was accepted.

## Portable comparison dossier

After both A and B are loaded, choose **Download comparison dossier (Markdown
+ JSON)**. Keep both files with matching `trial-comparison-<ID>` names and `.md`
and `.json` extensions. The full content-bound dossier ID appears in both files.
These are separate, non-atomic downloads; browsers may block one or request
permission for multiple downloads. The Markdown is a standalone readable
report. The versioned JSON (`moonrobo.trial-comparison-dossier.v1`) retains each
complete native response as an exact JSON text string, including the
original dossier and result strings, all binding fields, and every ordered
event. Selection captures the response text before parsing, so JSON whitespace
and number lexemes (including signed zero) are retained too; HTTP headers and
transport framing are not part of the dossier.

Export reads only the pair already inspected. It does not refresh either side,
run a simulation, create a review, mutate native trials, or use the separate
pending-Book incident exporter. An accepted trial without a review can be
included. Selecting the same trial twice is permitted and remains explicit.
Selections changing, loading, failing, refreshing or closing invalidate export;
a selection change during digest calculation suppresses the pending download.

Each side carries a separate client receipt timestamp and host identity. The
host's current-binding projection is frozen as a historical observation, not a
promise that those files still match on this or another computer. There is no
atomic cross-trial snapshot claim. Existing comparison rules, missing values,
zero values, incompatible baselines and acknowledgement uncertainty are kept.

The manifest records SHA-256 over UTF-8 for both exact payload strings and the
readable report. It detects changes; it is not a signature, authenticated review
or evidence of authorship. Treat received dossiers as untrusted. The Markdown
escapes supplied markup and controls; the exact unescaped source remains in
the JSON evidence strings.

Use **Verify and reopen a portable dossier locally** to choose the JSON. The
cockpit checks its contract, size (16 MiB maximum), identities, payload digests,
manifest, recomputed comparison and report before showing the historical report
as plain text. This is an inert local file view, with no HTTP request or native
trial import. Optionally choose the companion Markdown too to verify the exact
downloaded pair; mixed or modified supplied pairs are rejected. Without it,
the status explicitly says only the JSON's internal report was checked.
Verification establishes self-consistency, not authenticated native-store
verification. It never converts a portable claim into current host,
provider, Book or hardware authority. A mismatch or unsupported version clears
the preview and reports rejection. The exported Markdown is readable without a
running cockpit; verification uses the cockpit's local file control.

## Limits and failure handling

The catalogue lists at most 32 entries in lexical trial-ID order. It does not
page, rank, or claim completeness when truncated. Missing store, empty store,
unreadable store, invalid names, missing import/head evidence, invalid evidence
and over-limit history have explicit states. Unverified entries are not
selectable and no repair is attempted. A trial supports at most 128 inert
events; over-limit history is refused, not partially interpreted. Appending
beyond the limit is rejected before writing. Directory names are enumerated
before the count bound; this is not a streaming filesystem index.

Every selection clears that side before reading it. Newer selections, refresh
and closing the panel invalidate older pending responses. A failed second side
cannot keep stale comparison values. Refresh discards previous inspections;
select again to recheck current files. The separate import/event editor keeps
its draft as before.

## Read-only interface

GET `/api/moonrobo/digital-trials` returns
`moonrobo.digital-trial-catalogue.v1`. GET
`/api/moonrobo/digital-trials/<trial-id>` uses the existing fully verified
immutable import/event/head reader and current binding inspection. The result
includes native `binding.frozen_evidence` and separate
`current_binding_blockers` / `current_binding_unknowns` arrays.

The native CLI also supports `digital_trial catalogue <robobook-root>` and
`digital_trial inspect <robobook-root> <trial-id>`. These commands do not create
the evidence directory or write an acknowledgement.

## Verification

Run focused MoonBit checks/tests for `src/moonmoon_adapter`, `src/runtime`,
`src/host_api` and `src/moonbook`, plus the cockpit's existing and retained-trial
Node tests. The native HTTP integration test accepts `MOONROBO_NATIVE_HOST`,
`MOONROBO_NATIVE_TRIAL` and `MOONROBO_BUILD_DIST`. It starts the real local native
host, fetches the normal production asset, drives the shipped controller against
its HTTP routes, verifies accepted/rejected and different verified baselines,
separates current changed-file and acknowledgement/history states, and hashes
the entire fixture store around read-only operations. It is an HTTP/DOM fixture,
not a claim of browser-pixel, provider, calibrated hardware or physical testing.
