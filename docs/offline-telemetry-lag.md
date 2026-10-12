# Explore the recorded offset between two telemetry channels

An integration engineer reviewing a recorded request and observed response can
inspect which integer-sample offsets have similar shapes. This helps choose a
small set of real observation pairs to examine instead of manually shifting
spreadsheet columns. It does not measure physical latency or calibrate a clock.

This is a new offline inspection step after numeric CSV import or
[rotated-capture stitching](offline-telemetry-stitch.md). Existing
[event-aligned comparison](offline-event-comparison.md) compares different runs
around explicitly chosen events; it does not scan offsets between two channels.
MoonData's [pipeline Phase D](MOONDATA_PIPELINE.md#phase-d-quality-and-review)
identifies action/state lag as a review need. This command supports the recorded
inspection slice of PRD MR-W04/B06 and carries B07-oriented processing/source
lineage. It does not create a MoonData capture, quality verdict or physical proof.

## A readable known-delay example

`examples/telemetry/delayed-response.csv` is synthetic. It has twelve observations
100 ms apart, at times 1000 through 2100 ms. For sample indices 2 through 11,
`measured.n[i] = 2 * command.n[i - 2] + 1`. The first two measured values are
unrelated warm-up values. The extra temperature channel is retained in JSON.
No part of this file is observed robot telemetry.

Run from the repository root with Node; only built-in modules are needed:

```sh
node scripts/telemetry-lag.mjs examples/telemetry/delayed-response.csv --reference command.n --response measured.n --reference-unit N --response-unit N --max-lag-samples 4 --min-pairs 6 > lag-scan.json
node scripts/telemetry-lag.mjs examples/telemetry/delayed-response.csv --reference command.n --response measured.n --reference-unit N --response-unit N --max-lag-samples 4 --min-pairs 6 --format svg > lag-scan.svg
```

The strongest positive association is at **+2 samples**: reference observation
0 (1000 ms, 0 N) pairs with response observation 2 (1200 ms, 1 N); reference 1
(1100 ms, 3 N) pairs with response 3 (1300 ms, 7 N); the final pair is reference
9 (1900 ms, 4 N) and response 11 (2100 ms, 9 N). There are ten real pairs and
correlation is approximately 1. The exact recorded timestamp difference is
+200 ms. Swapping reference and response selects -2 samples / -200 recorded ms.

A positive lag always pairs `reference[i]` with `response[i + lag]`. It means
later recorded response observations are being compared, not that software
proved the robot took that long to respond. Acquisition buffering, clock setup,
sampling, filters and unrelated common inputs can all produce such an association.
The tool neither changes timestamps nor creates simultaneous observations.

## Inspect and reuse one explicit lag

After reviewing the full curve, choose a lag yourself. No automatic peak is
exported or applied:

```sh
node scripts/telemetry-lag.mjs examples/telemetry/delayed-response.csv --reference command.n --response measured.n --reference-unit N --response-unit N --max-lag-samples 4 --min-pairs 6 --lag-samples 2 > lag-selection.json
node scripts/telemetry-lag.mjs examples/telemetry/delayed-response.csv --reference command.n --response measured.n --reference-unit N --response-unit N --max-lag-samples 4 --min-pairs 6 --lag-samples 2 --format csv > lag-pairs.csv
node scripts/telemetry-distribution.mjs lag-pairs.csv --channel lagged-response:measured.n --unit N --edges -5,0,5,11 > paired-distribution.json
```

The selection JSON retains both original timestamps, values, source sample
indices and physical line numbers for every pair. The CSV uses reference times
with columns `reference:command.n` and `lagged-response:measured.n`. These two
columns are intentionally **not simultaneous measurements**. Response timestamp
and provenance are in the selection JSON, not encoded into a binary64 numeric
CSV column. Keep that JSON and the original source beside any export.

The distribution continuation contains ten selected response observations and
bin counts [3, 2, 5] for [-5,0), [0,5), and [5,11]. It describes just those ten
paired observations, not the entire response recording or a duration distribution.
The CSV can be reopened by the existing product numeric parser. Native product
consumption has not been exercised for this feature.

Use new output paths and check exit status: shell redirection to the input would
truncate it before the process starts. The command itself reads files and writes
stdout only. Success/help exit 0; errors exit 2 with one JSON `error` on stderr
and no stdout. Complete validation and calculation happen before output.

## Selection and sampling contract

Required options are `--reference`, `--response`, `--reference-unit`,
`--response-unit`, `--max-lag-samples` and `--min-pairs`.

- Reference and response must be different, existing numeric channel names.
  Units are explicit labels, not conversion or verification. Correlation is
  dimensionless and does not establish compatible physical meaning.
- `--window START_MS END_MS` selects inclusive absolute recorded timestamps.
  Omit it to select the full recording. Every row/channel is validated even
  outside the selected window. Window selection retains original sample indices.
- The selected window must contain 3 through 8192 observations and have exactly
  one positive integer-millisecond sampling interval. An irregular interval or
  gap fails; choose an uninterrupted window instead. No jitter tolerance,
  resampling, imputation or gap-spanning estimate is performed. Regular recorded
  timestamps do not prove complete acquisition or absence of dropped data.
- `--max-lag-samples` is an integer from 0 through 256, smaller than selected
  sample count. Every integer lag from its negative to positive is reported.
  Each lag has N - |lag| real pairs. Both members must lie inside the selected
  window. There is no circular wrapping, padding or extrapolation.
- `--min-pairs` is an explicit integer from 3 through selected sample count.
  Lags with fewer pairs remain in JSON/SVG as `insufficient-pairs`, correlation
  null. They cannot be selected for CSV. A high pair count alone does not prove
  significance, independence, enough excitation or a representative window.
- `--format json|svg|csv` defaults to JSON. JSON always includes the full scan;
  `--lag-samples SIGNED_INTEGER` adds a detailed explicit selection. CSV requires
  that selection. SVG shows the complete scan and rejects a selection option.
  Selection is allowed for constant channels when enough pairs exist, even
  though their correlation remains undefined.

The established unquoted numeric CSV contract applies: UTF-8, `timestamp_ms`
first, unique printable channel labels, finite numeric cells, and strictly
increasing nonnegative Int64 timestamp integers. The CLI decodes UTF-8 strictly.
Int64 timestamps, intervals, requested bounds and signed offsets are JSON strings;
none passes through Number. Channel values use finite binary64 precision.

## Calculation and interpretation

For each lag separately, let X and Y be its overlapping reference and response
values. The reported Pearson coefficient is:

```text
sum((X - mean(X)) * (Y - mean(Y))) /
  sqrt(sum((X - mean(X))^2) * sum((Y - mean(Y))^2))
```

Each pair has equal weight. Different lags use different subsets and their own
means, so pair counts and endpoints must be considered when comparing scores.
Channels are scaled by their maximum absolute overlapping value before centering,
with compensated sums and separately computed square roots to limit overflow.
Rounding outside [-1,1] is clamped to that range. This is not exact-decimal
arithmetic; small differences near large offsets can lose precision.

Constant reference/response subsets produce `reference-constant`,
`response-constant` or `both-constant` and null correlation. Arithmetic that
cannot resolve a finite coefficient yields `numerically-unresolved`, also null.
None of these is converted to zero association. Negative coefficients are
retained as negative associations, not ranked as positive peaks.

`highest_positive_association` lists positive candidate lags within 1e-12 of the
computed maximum. This fixed absolute-coefficient tolerance groups numerical
near-ties; it is not statistical uncertainty, a confidence interval or an
application threshold. No positive coefficient yields null. Repeated periodic
patterns can yield several equal peaks, and nonperiodic/noisy recordings can
have several nearly equal peaks. Always inspect the whole curve and raw pairs.
There is no significance test, confidence claim, sub-sample interpolation,
drift correction, phase-unwrapping, event detection or causal inference.

## Evidence and limits

JSON format `moonrobo.telemetry-lag.v1` includes method version, raw UTF-8 source
SHA-256, selected channels/units, window, original and selected sample counts,
exact sampling interval, policies, complete lag curve, original selected rows
(including unselected channels), and optional paired selection. Sample indices
are zero-based original nonblank data rows; source lines are one-based physical
lines. A hash binds bytes, not authorship, calibration, robot/session identity,
command execution or source truth. Reports are not authenticated or immutable.

The standalone SVG labels the sign convention and plots correlation on [-1,1].
Undefined lags appear as crosses below the plot and interrupt the line. Marker
labels include exact lag, recorded offset and pair count. Long channel names can
overrun the fixed canvas; the full JSON remains complete. The SVG contains no
external resources. Its XML structure and escaping are tested; graphical browser
rendering and cockpit integration are not qualified.

All source parsing and output live in memory. Only selected samples/lag range
are bounded; very large complete inputs are not streamed. Runtime work is
proportional to selected samples times scanned lags. CSV normalizes number
spellings, may lose negative zero, and omits source identity and lag metadata.
No Moon command, dependency install, network, provider, bridge or hardware
operation is used. No physical safety, stop performance, trial acceptance,
MoonData storage, complete PRD B07 acceptance or cumulative qualification follows.

Reusable exports are `scanLag(text, options)`, `selectLag(report, lagSamples)`,
`lagCsv(report, lagSamples)` and `lagSvg(report)`. Export helpers expect an
unmodified successful report; they do not revalidate arbitrary hand-built objects.
They do not perform file I/O. The CLI supplies paths and explicitly selected
output formats. Inputs and earlier outputs remain unchanged.

## Focused verification

```sh
node --test scripts/test-telemetry-distribution.mjs scripts/test-telemetry-stitch.mjs scripts/test-telemetry-lag.mjs
```

The new tests cover known signed offsets and real pair endpoints, hand-computed
correlation, varying overlap, undefined constant signals, periodic ambiguity,
exact Int64 windows, gap rejection, blank-line lineage, scaled finite arithmetic,
source validation, actual CLI output/reopening, and both stitching and distribution
continuations. Prior Node distribution/stitching regressions run alongside them.
No native compiler, full application, browser, provider or hardware claim is made.
