# Compare two offline telemetry runs

Use `cmd/telemetry_compare` to find how a recorded candidate run differs from a
baseline. Feed it two numeric CSV recordings, choose matching channels and an
elapsed-time window, then export measurements for a review or spreadsheet.
This is offline analysis. It never connects to a device or grants readiness.

## Try the synthetic shoulder/temperature example

Build once for clean machine-readable output:

```sh
moon build cmd/telemetry_compare --target native
./_build/native/debug/build/cmd/telemetry_compare/telemetry_compare.exe \
  examples/telemetry/baseline-run.csv examples/telemetry/candidate-run.csv \
  --max-gap-ms 200 > comparison.json
```

Use the executable path reported by your Moon version if different. Both files
are synthetic, with different start timestamps, column orders, and sample rates.
The candidate is about 0.1 rad higher at the shoulder and 2 degrees C warmer.
At the 200 ms interpolation limit, the export has six compared baseline times:
four exact matches and two interpolated values. Two times fall inside a 300 ms
candidate gap and one lies after the candidate ends. Those three times remain
explicitly unmatched. Battery and motor-current channels are not compared because
only one file contains each.

Inspect only the shoulder during the first 400 ms, then export the paired values:

```sh
./_build/native/debug/build/cmd/telemetry_compare/telemetry_compare.exe \
  examples/telemetry/baseline-run.csv examples/telemetry/candidate-run.csv \
  --channels joint.shoulder.rad --window 100 400 --max-gap-ms 200
./_build/native/debug/build/cmd/telemetry_compare/telemetry_compare.exe \
  examples/telemetry/baseline-run.csv examples/telemetry/candidate-run.csv \
  --channels joint.shoulder.rad --window 100 400 --max-gap-ms 200 --csv > shoulder-deltas.csv
```

The selected window has four compared times and a shoulder RMS difference of
approximately 0.1 rad. Small decimal rounding differences are normal.

## Alignment and interpretation

- Each file's first sample is elapsed zero. This happens before window selection,
  so changing `--window` never silently moves the origin. Window endpoints are
  inclusive elapsed integer milliseconds, not absolute timestamps.
- Baseline sample times determine the comparison grid. Exact elapsed matches
  work by default. `--max-gap-ms N` explicitly enables linear interpolation only
  across a candidate interval no longer than N milliseconds. A value of zero
  retains exact-only behavior. There is no extrapolation.
- An interpolated point preserves the candidate's two original bracket timestamps.
  It is an estimate, not an observed sample. The tool cannot detect excursions
  between recorded samples or reconstruct unknown motion through a gap.
- Channels are matched by exact name, regardless of column order. Without
  `--channels`, common names are selected in baseline order. An explicit list
  preserves its requested order and fails if either file lacks a name.
- All deltas are candidate minus baseline. Bias (`mean_delta`) preserves the
  sign; mean absolute difference, RMS difference, and peak absolute difference
  describe magnitude. Peak time is the earliest compared time attaining the peak.
- Each compared baseline sample has equal weight. These are sample-weighted
  statistics, not duration-weighted integrals. Gaps are excluded from statistics
  and reported separately. No paired samples means an empty summary, not zero
  error. Swapping baseline and candidate can change the grid and statistics.
- Names are labels, not a unit schema. Use comparable channels in the same units,
  coordinate frame, calibration convention, and meaningful run-start phase.
  A shared name does not prove physical compatibility. Degrees vs radians or
  Celsius vs Fahrenheit must be converted before comparison. The separate
  [explicit normalization tool](offline-telemetry-normalization.md) can apply
  user-supplied name mappings and scale/offset recipes and preserve provenance.
  No unit conversion, clock-drift correction, event registration, pass/fail
  tolerance, hardware qualification, or physical-success claim is inferred.

## Inputs and outputs

The [numeric CSV contract](offline-telemetry-csv.md#csv-contract) applies to both
files. Both entire recordings are validated before any window filtering. Files
must fit in memory. `--help` describes options. Invalid input or options emit a
JSON `error` object and exit 2, including in CSV mode; success exits 0.

JSON output contains `baseline_file`, `candidate_file`, and `comparison`.
The comparison format is `moonrobo.telemetry-comparison.v1`. It retains both
origins, requested bounds, interpolation limit, channel ordering, sample counts,
per-channel summaries, paired values/deltas, and each unmatched time/reason.
Int64 timestamps and bounds are JSON strings to preserve all integer precision.
Input paths provide context but are not content hashes or immutable evidence IDs.

CSV output is long-form: one row per channel at each paired time, plus one row
per unmatched baseline time. Columns are `elapsed_ms`, `baseline_timestamp_ms`,
`candidate_left_timestamp_ms`, `candidate_right_timestamp_ms`, `status`,
`channel`, `baseline`, `candidate`, `delta`. Rows stay in elapsed order.
`status` is `exact`, `interpolated`, `candidate-gap-exceeds-limit`, or
`outside-candidate-range`. Gap values stay empty. JSON is the complete report;
CSV omits summaries and configuration metadata and is for plotting/tabular work.

The reusable `src/telemetry_csv.compare_csv` function takes CSV text and optional
`channels`, `start_ms`, `end_ms`, and `max_gap_ms`. `Comparison::to_csv` exports
its result. Neither API performs file, network, bridge, or hardware operations.

## When recording starts do not correspond

Use [event-aligned comparison](offline-event-comparison.md) to select observed
threshold episodes explicitly and compare signed pre/post-event windows. The
existing command above keeps its first-recorded-sample origins unchanged.
