# Compare a measurement across recorded operating modes

An operator reviewing a numeric mode channel and a measured load/current channel
can now answer “which measured ranges occur in each recorded mode?” across all
repeated runs, without hand-cutting a window for every mode change. The existing
`telemetry-distribution.mjs` command groups observations using the code in the
same original row, applies shared explicit bins, and reports each group's
quantiles and denominator. Undeclared codes remain visible as a separate group.

This adds two-channel conditional inspection to the existing whole/window
histogram and recorded-state duration workflows. It is a bounded offline slice
of PRD MR-W04 / MOONROBO-B06, with B07-oriented source anchors. It does not fulfill
cockpit readiness, physical proof, MoonData persistence or incident reconciliation.
A supplied label such as `working` is a reviewer's name for a recorded code, not a
verified physical state, approved action, or causal explanation of a measurement.

## Compare, inspect, export, and reopen

From the repository root, with Node and built-in modules only:

```sh
node scripts/telemetry-distribution.mjs examples/telemetry/state-conditioned-load.csv --channel load.n --unit N --edges 0,3,6,10 --group-by mode --groups '0=idle,1=working,2=held,3=maintenance' > mode-load.json
node scripts/telemetry-distribution.mjs examples/telemetry/state-conditioned-load.csv --channel load.n --unit N --edges 0,3,6,10 --group-by mode --groups '0=idle,1=working,2=held,3=maintenance' --format svg > mode-load.svg
node scripts/telemetry-distribution.mjs examples/telemetry/state-conditioned-load.csv --channel load.n --unit N --edges 0,3,6,10 --group-by mode --groups '0=idle,1=working,2=held,3=maintenance' --format csv --select-group 1 > working-observations.csv
node scripts/telemetry-distribution.mjs working-observations.csv --channel load.n --unit N --edges 0,3,6,10 > working-recheck.json
```

The synthetic input has twelve observations, including repeated idle/working
runs and a long recording gap. The hand-calculated results are:

- Idle (code 0): four observations, all in [0,3), nearest-rank median 1 N.
- Working (code 1): five observations, bin counts [0,1,3] and one overflow;
  median 8 N. The final bin [6,10] includes 10. Its fraction is 3/5, not 3/12.
- Held (code 2): one observation, 3 N, in [3,6).
- Maintenance (code 3): no observations; fractions/quantiles are unavailable.
- Undeclared code 9: two observations, -1 N and 9 N; one underflow and one in
  the final bin. They are not silently dropped or assigned to a declared state.

SVG uses identical bins and fixed 0–100% bar scales for all groups. It shows
sample counts beside the normalized fractions so a one-sample group is visibly
different from a large group. There is no automatic “better” group or hypothesis
test. Long labels can exceed the fixed canvas. JSON contains complete labels and
values; SVG structure and escaping are tested, but graphical rendering is not.

The selected CSV preserves all original channels and exact recorded timestamp
strings for the chosen code, in source order. Numeric value spellings are
normalized through binary64; negative zero and lexical precision are not retained.
The working export has five rows and reproduces the working histogram/quantiles
when reopened by the original ungrouped command. To inspect unassigned rows,
replace `--select-group 1` with `--select-group undeclared`.

CSV requires an explicit selection. It refuses an undeclared numeric selector
(use the literal `undeclared` for the combined unassigned group), an empty group,
or a missing selection. `--select-group` is accepted only with CSV; JSON/SVG
always show the full comparison. Preserve JSON and the raw input beside exports.

Important: filtering can remove observations between adjacent exported rows.
The CSV is a selected-observation set suitable for counts/distributions, not a
continuous capture. Do not run interval, derivative, duration, resampling or
motion analysis on it as if no intervening observations existed. JSON
`source_blocks` identifies consecutive original sample-index blocks, with first
and last source anchors. Even one such block can contain a long recording gap:
blocks describe adjacency in a file, not continuity of physical observation.

Use distinct output paths: shell redirection can truncate an input before the
command opens it. Success/help exits 0. Errors exit 2, put one JSON error on
stderr, and emit no stdout. Validate exit status before using any output. The
command validates and computes the complete result before writing it.

## Explicit grouping and observation semantics

- `--channel NAME` selects the numeric measurement and `--unit UNIT` supplies a
  display label only. Units are not verified, converted or calibrated.
- `--group-by NAME` selects a different numeric channel from the same recording.
  There is no cross-file join, automatic alignment, inferred state, interpolation,
  left-hold or timestamp shift. Every selected row belongs to exactly one group.
- `--groups CODE=LABEL,...` declares 1–64 unique finite numeric codes and distinct
  nonblank printable labels. Declaration order controls display order. CLI labels
  may contain `=` after the first separator but not commas; API labels may contain
  commas. Shell-quote spaces and metacharacters. Matching is exact numeric equality
  after binary64 parsing, with no tolerance. Prefer small integer codes: distinct
  decimal spellings can round to the same value, and -0 equals 0.
- `--edges E0,E1,...` supplies 2–65 increasing finite bounds shared by all groups.
  Bins are [lower,upper), except the last includes its upper endpoint. Both tails
  are reported. No automatic thresholds, alarms or pass/fail decision is made.
- Each observation has weight one, regardless of cadence, gaps, repeated values
  or elapsed time. Bin fractions use that group's total count, including tails.
  `fraction_of_window_samples` instead describes the group's share of all selected
  rows. An absent group's share is 0 in a nonempty window; all fractions are null
  in an empty window. Empty-group quantiles are always null.
- Quantiles use nearest-rank values at 0/25/50/75/90/95/100 percentiles within each
  group, including out-of-bin values. An even-count median is the lower central
  value. There is no interpolation, mean, confidence interval or causal claim.
- `--window START_MS END_MS` is inclusive and uses nonnegative Int64 decimal
  timestamps. Omitting it selects all source observations. A singleton/point
  window can contribute one observation; no time duration is calculated. Time
  stays exact using BigInt internally and decimal strings in reports.
- `--states` / `--max-gap-ms` belong to the separate duration workflow and cannot
  be combined with group comparison. Existing ungrouped/duration commands remain
  unchanged. State-duration modeling should use the original complete recording.

## Source contract and scope

The shared parser validates the entire strict UTF-8 unquoted numeric CSV before
selection, including out-of-window rows and unselected channels. It requires
`timestamp_ms` first, unique printable channel names, finite numeric values,
equal column counts and strictly increasing nonnegative Int64 times. Missing
cells and nonfinite values are errors; nothing is filled or silently discarded.
BOM, LF/CRLF, blank lines and a missing final newline are supported. No clock
domain or Unix-time assumption is made.

JSON `moonrobo.telemetry-conditioned-distribution.v1` includes source SHA-256,
original span, window, channel names/unit, grouping/bin/quantile/fraction rules,
all declarations and observations, undeclared code counts, and source blocks.
Observations carry zero-based original sample indices, one-based physical source
lines, exact timestamps and all original numeric channel values. SHA-256 hashes
valid source UTF-8 bytes including BOM and line endings, but does not authenticate
the source or prove its truth. No raw source or derived result is modified.

This command does not create a MoonData artifact, robot/session/command binding,
immutable processing record, readiness decision, safety evidence or physical
receipt. It never contacts a device/provider or grants dispatch authority. Reports
and input files are held in memory; there is no streaming or large-file guarantee.
No dependency install, Moon compilation, native cockpit, browser, SDK or hardware
execution is part of this workflow qualification.

## API and verification

`conditionedDistribution(text, { channel, unit, edges, groupBy, groups, window })`
is exported from `scripts/telemetry-conditioned.mjs`. Groups are
`{ value: number, label: string }`; optional window bounds are decimal strings.
`conditionedSvg(report)` and `selectedGroupCsv(report, selector)` accept a
successful, unmodified report; they do not revalidate arbitrary mutable objects.
The histogram helper is shared with the existing ungrouped distribution path.

```sh
node --test scripts/test-telemetry-conditioned.mjs scripts/test-telemetry-distribution.mjs scripts/test-telemetry-state-duration.mjs scripts/test-telemetry-stitch.mjs scripts/test-telemetry-lag.mjs
```

Fifteen focused comparison tests exercise hand-calculated conditional results,
unknown and absent groups, group partition accounting, exact windows/source
anchors, noncontiguous source blocks, cadence-independent weights, reopening and
reanalysis, declaration order, full-source validation, SVG semantics/escaping,
actual CLI artifacts and error outputs. Existing regression tests run unchanged.
