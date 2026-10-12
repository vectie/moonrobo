# Summarize recorded telemetry in explicit time buckets

`telemetry_bucket` summarizes an operator-chosen CSV window without changing the
recording. Select channels in order, a positive width in milliseconds and an
alignment. Each occupied bucket reports count, first, last, minimum, maximum
and an equal-weight-per-sample mean. Source sample indices and timestamps make
membership inspectable. Empty bucket spans stay explicit and have no values.

This is descriptive offline analysis. It does not smooth, interpolate, resample,
fill missing measurements, infer elapsed exposure, infer units or establish
physical robot state, readiness, calibration, safety or command completion.

## Run

Build the new command and the existing structured recorder importer with the
project's frozen dependencies, choosing an external target directory:

```sh
moon build cmd/telemetry_bucket cmd/telemetry_import_jsonl --target native --frozen --strip -j 1 --target-dir /tmp/moonrobo-buckets-build
```

Use the executable paths reported by your Moon version. With the pinned
toolchain used for this change:

```sh
/tmp/moonrobo-buckets-build/native/debug/build/cmd/telemetry_bucket/telemetry_bucket.exe examples/telemetry/bucket-observations.csv --channel temperature --channel current --width-ms 10 --align zero --window 1 69 > buckets.json
/tmp/moonrobo-buckets-build/native/debug/build/cmd/telemetry_bucket/telemetry_bucket.exe examples/telemetry/bucket-observations.csv --channel temperature --channel current --width-ms 10 --align zero --window 1 69 --csv > buckets.csv
```

The synthetic fixture selects six observations. Occupied bucket indices are
0, 1 and 4, with two samples each. Current means are 5, 5 and 2. Empty spans are
indices 2–3 and 5–6. The 0 ms and 70 ms rows are outside the requested window.
The first bucket's grid is 0–9 ms but its selected bounds are 1–9 ms.

```text
telemetry_bucket INPUT.csv --channel NAME [--channel NAME ...] --width-ms MS --align zero|window --window START_MS END_MS [--csv]
```

All four selection options are required. Channel names must exist and cannot
repeat. Width is 1 through 9223372036854775807 ms. Window bounds are inclusive
nonnegative Int64 milliseconds, with START <= END. `--help` prints usage.
Unknown, missing or repeated singleton options fail. Success exits 0; errors
exit 2 and emit one JSON `error` on stdout, including in CSV mode. Check status
before consuming a redirected output. No partial report is emitted on error.
The program only reads its input and writes stdout; choose a distinct output
path when using shell redirection.

## Exact selection and alignment

- `--align zero` anchors the grid at recorded 0 ms. Bucket index is integer
  floor(timestamp / width). Changing the window does not move this grid.
- `--align window` anchors at START_MS. Bucket index is integer
  floor((timestamp - START_MS) / width). Changing the window start moves the grid.
- Buckets ordinarily cover `origin + index*width` through
  `origin + (index+1)*width - 1`, both inclusive integer milliseconds. A sample
  exactly at the next boundary belongs to the next bucket. The final grid
  interval is capped at Int64 max, avoiding an unrepresentable exclusive end.
- Only samples inside the inclusive selection window contribute. First and
  last are the first and last selected observations, not inferred values at
  the bucket edges. Count counts observations, not milliseconds.
- With width 10 and window 5–15, zero alignment groups times 5,9 together and
  10,14,15 together. Window alignment groups 5,9,10,14 together and 15 alone.
- Every source row and every channel is validated before selection. The
  existing strict numeric CSV contract applies: unique headers, finite numeric
  values and nonnegative strictly increasing timestamps; no quoted CSV input.
  Blank lines and CRLF are accepted. Late errors outside the window still fail.
  Empty/header-only source recordings fail. A valid recording with no samples
  in the selected window succeeds with one compressed empty span.

No continuous-time claim is made. Three values 4,10,4 at times 0,1,99 have mean
6 even though their time spacing is unequal. All selected samples have equal
weight. The mean uses scaled compensated Double summation to avoid overflow
for finite extremes; normal floating-point rounding, loss of small terms and
underflow remain possible. It is not exact decimal or arbitrary-precision math.

## JSON, CSV and empty spans

JSON format `moonrobo.telemetry-buckets.v1` retains selection, alignment/origin,
timebase, weighting, ordered channels, source/selected counts, total bucket
count, occupied `buckets` and compressed `gaps`. Each occupied bucket includes
its grid bounds, selected bounds, count, source indices/timestamps and ordered
channel statistics. A gap includes first/last bucket index, empty bucket count
and selected bounds. Leading and trailing empty spans are included.

Timestamp, index and UInt64 count fields are decimal strings in JSON. These
remain exact above 2^53 and at Int64 max on both native and JS library targets.
UInt64 permits 9223372036854775808 total buckets for width 1 over the complete
nonnegative Int64 domain. Neither implementation nor output enumerates empty
buckets. A multi-billion-bucket empty span costs one gap record.

CSV is a long-form report, with one `observed` row per occupied bucket/channel
and one `empty-span` row per contiguous empty run, in chronological order.
Selection metadata repeats on every row. Membership lists use semicolons.
Empty statistics are blank and count is 0 on empty spans; no zero-valued sample
is invented. Header labels specify `sample_weighted_mean`; all bounds are
inclusive. The CSV is a summary report, not input for the numeric recording
parser or plotter. JSON additionally retains full grid bounds, total and
selected counts and explicit weighting/timebase strings.

`source_sample_indices` are zero-based positions in the complete parsed input,
before window selection. They are not physical CSV line numbers. Blank lines
do not consume sample indices. Selected timestamp lists preserve exact order.
These labels are traceability aids, not source hashes or immutable identities.
Keep the exact raw recording and report together. Arrays in exported public
types are mutable; `to_csv()` expects the unmodified successful result.

## Structured recorder to buckets

The R213 importer composes directly with the new workflow:

```sh
/tmp/moonrobo-buckets-build/native/debug/build/cmd/telemetry_import_jsonl/telemetry_import_jsonl.exe examples/telemetry/structured-recording.jsonl examples/telemetry/structured-recipe.json > imported-report.json
/tmp/moonrobo-buckets-build/native/debug/build/cmd/telemetry_import_jsonl/telemetry_import_jsonl.exe examples/telemetry/structured-recording.jsonl examples/telemetry/structured-recipe.json --csv > imported.csv
/tmp/moonrobo-buckets-build/native/debug/build/cmd/telemetry_bucket/telemetry_bucket.exe imported.csv --channel motor.current.a --width-ms 500 --align window --window 9007199254740993 9007199254743193 > imported-buckets.json
```

The first bucket contains sample indices 0,1,2 (physical JSONL lines 1,3,4), and
the final occupied bucket contains index 3 (line 5). Empty buckets 1–3 are one
gap. The retained importer report maps each sample index to its physical source
line. CSV itself has no recipe, original line numbers or unit labels; retain
the raw JSONL, recipe and import report to make that join. The importer and
bucketter do not write a MoonData capture or establish robot/session identity.

The pure library API is `src/telemetry_csv.bucket_csv`, returning
`Result[TelemetryBuckets, String]`, plus `TelemetryBuckets::to_csv`. Both source
and results are held in memory. Work is bounded by source samples and selected
channels, with compressed gaps. This is not a streaming aggregate or full
cockpit/proof-session qualification.
