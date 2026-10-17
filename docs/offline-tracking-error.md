# Inspect requested-versus-measured recorded tracking error

An operator reviewing two channels in the **same numeric recording** can inspect
how far each measured value differs from the requested value at that recorded
row. The dependency-free Node workflow reports signed errors, bias, mean absolute
error (MAE), root mean square error (RMSE), and maximum absolute error. Export the
error channel and reopen it in the existing distribution explorer.

This is a narrow offline inspection extension grounded in MR-W04 and
MOONROBO-B06, with source-content traceability relevant to B07. It does not complete
cockpit freshness, queue, incident, recovery, authority or MoonData requirements.
It provides no physical tracking, calibration, device readiness, safety, successful
execution or hardware qualification. The file's requested/measured roles and
common unit are caller declarations, not authenticated facts.

## Try the complete workflow

`examples/telemetry/tracking-error.csv` is a synthetic four-row recording, not
observed robot telemetry. Run these commands from the repository root:

```sh
node scripts/telemetry-tracking-error.mjs examples/telemetry/tracking-error.csv --requested requested.n --measured measured.n --common-unit N > tracking-report.json
node scripts/telemetry-tracking-error.mjs examples/telemetry/tracking-error.csv --requested requested.n --measured measured.n --common-unit N --format csv > tracking-error.csv
node scripts/telemetry-distribution.mjs tracking-error.csv --channel tracking_error --unit N --edges -3,0,2,4 > error-distribution.json
node scripts/telemetry-distribution.mjs tracking-error.csv --channel tracking_error --unit N --edges -3,0,2,4 --format svg > error-distribution.svg
```

The four errors are **1, -2, 0, 3 N**, with bias **0.5 N**, MAE **1.5 N**,
RMSE **sqrt(3.5), approximately 1.870828693 N**, and maximum absolute error
**3 N**. The reopened distribution has bin counts **[1, 2, 1]** for [-3,0),
[0,2), and [2,4]. Its SVG is a sample-count histogram, not a time-series or a
qualification verdict. Open that SVG in a viewer; this command launches no browser.

Use distinct output paths and check the exit status before consuming files.
Shell redirection to the input would truncate it before Node starts. The command
itself only reads its input and writes stdout. Success/help exits 0. Errors exit
2 with one JSON error on stderr and no stdout. All validation and calculations
finish before output. No Moon command, compilation, installation or network is
needed. Existing native CSV consumers have not been exercised for this feature.

## Explicit choices

- `--requested NAME` and `--measured NAME` select two different existing columns.
  No label guessing or automatic pairing is performed.
- `--common-unit UNIT` declares that both columns already use the same compatible
  quantity and unit. No unit detection, conversion, coordinate transformation,
  angular wrapping or calibration is performed. Convert incompatible recordings
  explicitly before this operation, retaining their original provenance.
- `--window START_MS END_MS` optionally selects inclusive nonnegative Int64
  recorded timestamps. Without it every row is selected. Exact timestamp and
  window strings never pass through JavaScript Number.
- `--format json|csv` defaults to JSON. JSON contains the summary and selected
  original observations; CSV contains only `timestamp_ms,tracking_error`.
  The fixed error-channel name avoids injecting source labels or units into CSV.

The full UTF-8 source must fit within 4 MiB. Its established unquoted numeric CSV
schema requires `timestamp_ms` first, unique printable channel names, complete
finite numeric cells and strictly increasing nonnegative Int64 timestamps.
Whitespace, LF/CRLF, blank lines and an optional BOM are accepted. Quotes and
multiline CSV are unsupported. The CLI decodes UTF-8 strictly and validates every
row and column, including rows outside the window and unrelated channels.
The accepted-byte cap is not a streaming-memory guarantee: the CLI reads the file
into memory before checking it, and JSON can exceed the source size.

## Meaning of the numbers

For each selected row i, `error[i] = measured[i] - requested[i]`. Positive error
means the recorded measured value is greater. With n selected rows:

```text
bias          = sum(error) / n
MAE           = sum(abs(error)) / n
RMSE          = sqrt(sum(error^2) / n)
max_abs_error = max(abs(error))
```

Each row has equal weight. Irregular cadence and large gaps neither add samples
nor change weights. There is no interpolation, hold, lag selection, clock shift
or continuity claim. Same-row membership does not prove simultaneous physical
acquisition. Bias is signed; MAE and RMSE cannot cancel opposing errors. Swapping
channel roles reverses error and bias while preserving the absolute metrics.
These sample statistics do not establish uncertainty, confidence, a tolerance
pass/fail rule, representativeness or a physical failure diagnosis.

An empty window produces zero samples and null metrics/span/CSV digest in JSON.
It cannot export reusable CSV because the shared recording parser requires at
least one sample. Singleton and all-zero-error windows have ordinary defined
statistics. Any selected subtraction that overflows finite binary64 fails the
whole operation. No infinity is silently serialized as null.

Calculations use finite binary64 values, not exact decimal arithmetic. Statistics
scale by maximum absolute error before compensated summation and squaring,
preventing avoidable large-value sum/square overflow. Results are clamped only
to known mathematical normalized bounds before restoring scale. Extremely small
relative contributions can underflow; precision already lost in large input
values is not recovered. No arbitrary-precision or error-bound claim is made.

## Preserve the evidence beside the exported error channel

`moonrobo.telemetry-tracking-error.v1` JSON records the method version, exact raw
UTF-8 source SHA-256, original channel order, selected role/unit declarations,
window, original and selected sample counts/spans, formulas/policies, and all
selected original channel values. Each sample retains its exact timestamp,
zero-based original sample index, one-based physical source line, requested value,
measured value and signed error. Reopening JSON retains these fields.

`error_csv_sha256` binds the exact companion CSV bytes for a nonempty selection.
Keep that JSON and original input with the CSV. CSV alone omits units, source
identity, original line numbers and channel roles. Its number spellings are
normalized and negative zero can be lost. A content hash is not authentication,
robot or session identity, a command receipt, durable MoonData storage, source
truth or proof of physical execution. Reports remain editable local files.

The public functions are `trackingError(text, options)` and
`trackingErrorCsv(report)`. The export helper expects the unmodified successful
report returned by the calculator, not an arbitrary imported JSON object. JSON
reopening is inspection, not a trusted report-import or execution surface.

## Focused verification

```sh
node --test scripts/test-telemetry-tracking-error.mjs scripts/test-telemetry-distribution.mjs
```

Coverage includes hand calculations, role reversal, constant offsets, all-zero
and singleton windows, irregular cadence, exact Int64 timestamps, complete input
validation, empty windows, extreme magnitudes, cancellation, subtraction overflow,
hostile labels, JSON/CSV reopening and the actual CLI-to-distribution continuation.
Only affected Node checks are required here. Native compilation, browser rendering,
full cockpit integration, physical calibration and full PRD acceptance are unrun.
