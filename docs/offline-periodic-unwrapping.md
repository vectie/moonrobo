# Unwrap recorded periodic joint channels

`telemetry_unwrap` prepares wrapped encoder/angle recordings for plotting and
finite-difference motion analysis. A jump from 179° to −172° can represent a
+9° displacement across a wrap boundary. With an explicit 360° period this tool
changes the second value to 188° in a new derived recording, so the existing
motion tool can estimate +90°/s over 100 ms instead of a wrap-induced −3510°/s.

This is a shortest-displacement interpretation. You must know that actual
inter-sample displacement is less than half a period for it to be unambiguous.
Neither the recording nor this tool can identify hidden complete turns or tell
a wrap crossing from genuinely large movement. Choose a gap limit appropriate
to the recording and speed before interpreting the result. No units, geometry,
calibration, device identity, physical success or safe limits are inferred.

## Synthetic two-channel workflow

Build to an absolute external target with the frozen graph, then run the native
executables for clean machine-readable stdout. Use the executable locations
reported by your toolchain if they differ:

```sh
moon --target-dir /tmp/moonrobo-periodic-build build cmd/telemetry_unwrap cmd/telemetry_motion cmd/telemetry_plot --target native --frozen --strip -j 1
B=/tmp/moonrobo-periodic-build/native/debug/build/cmd
"$B/telemetry_unwrap/telemetry_unwrap.exe" examples/telemetry/unwrap-joints.csv examples/telemetry/unwrap-recipe.json --max-gap-ms 100 > unwrapped.json
"$B/telemetry_unwrap/telemetry_unwrap.exe" examples/telemetry/unwrap-joints.csv examples/telemetry/unwrap-recipe.json --max-gap-ms 100 --csv > unwrapped.csv
"$B/telemetry_motion/telemetry_motion.exe" unwrapped.csv shoulder.continuous.deg,encoder.continuous.count --units deg,count --order 1 --max-gap-ms 100 > rates.json
"$B/telemetry_motion/telemetry_motion.exe" unwrapped.csv shoulder.continuous.deg,encoder.continuous.count --units deg,count --order 2 --max-gap-ms 100 > acceleration.json
"$B/telemetry_plot/telemetry_plot.exe" unwrapped.csv --channel shoulder.continuous.deg --unit deg --max-gap-ms 100 --svg > shoulder.svg
```

The eight observations form two four-sample segments, separated by an 1100 ms
gap. Within the first segment the shoulder becomes 170, 179, 188, 197 degrees
and the encoder becomes 10, −6, −22, −38 counts. The second segment starts afresh
at −170 degrees and 4080 counts; its next values are −179/4096, −188/4112 and
−197/4128. The temperature channel and all timestamps remain unchanged.

The downstream rate report contains six estimates: shoulder +90 then −90 deg/s,
encoder −160 then +160 count/s. The four supported acceleration estimates are
zero. No derivative crosses the outage. The SVG has two segments and one gap.
Keep the same 100 ms gap cutoff in every downstream command; CSV does not carry
an explicit segment marker, and a larger downstream cutoff could reconnect a
boundary at which unwrapping deliberately reset.

## Recipe and CLI contract

```text
telemetry_unwrap INPUT.csv RECIPE.json --max-gap-ms MS [--csv]
```

A recipe is a nonempty JSON array. Each entry requires exactly four fields:

```json
[
  {"source":"shoulder.deg","target":"shoulder.continuous.deg","period":360,"unit":"deg"},
  {"source":"encoder.count","target":"encoder.continuous.count","period":4096,"unit":"count"}
]
```

- `source` is a literal channel name after the CSV parser trims header spaces.
  No guessed aliases or suffix interpretation. Each source may be selected once.
- `target` is the final column name. Renames are simultaneous, including swaps.
  Final mapped and untouched names must be unique. A source may keep its name.
  Labels cannot be blank, `timestamp_ms`, contain quotes, commas, CR/LF or have
  surrounding whitespace. Unicode is supported.
- `period` is a positive finite number in the recorded values' units. It must
  have a representable nonzero half-period. Use 360 for degrees, an explicit
  numeric approximation such as 6.283185307179586 for radians, or the known
  modulo count for an encoder. No particular wrap origin is required.
- `unit` is a nonblank descriptive label retained exactly as supplied. It does
  not select a period or cause conversion. An incorrect unit/period combination
  cannot be detected automatically.
- Unknown, duplicated, missing and mistyped JSON fields fail. Duplicate keys
  with escaped spellings are also rejected. Empty recipes fail.
- `--max-gap-ms` is required and positive. A timestamp interval strictly greater
  than this cutoff starts a new segment. Equality remains connected. No zero
  fill, interpolation, smoothing, resampling or row deletion occurs.
- All input rows and channels are validated even when unselected. The existing
  [unquoted numeric CSV contract](offline-telemetry-csv.md#csv-contract) applies.
  Inputs must contain at least one sample and fit in memory. Nonnegative Int64
  timestamps must strictly increase and are preserved exactly.

The command writes only stdout, never an input path. Redirect to a different
file. Success exits 0; bad input/options, unreadable files or nonfinite arithmetic
exit 2 with one JSON `error` object, including in CSV mode. No partial result is
emitted after a late error. Check the exit status before consuming redirected
output. `--help`/`-h` alone prints usage.

## Algorithm and ambiguity

For each selected channel and connected pair:

1. Compute the signed raw difference `d = current_raw - previous_raw`.
2. Compute signed remainder `r = d % period`, retaining `d`'s sign.
3. If `r > period/2`, subtract a period; if `r < -period/2`, add a period.
   Otherwise keep `r`. The result is the shortest signed periodic delta `s`.
4. Accumulate `offset += s - d`; output `current_raw + offset`.

Every segment begins with offset zero and its first raw value. Resetting after a
gap intentionally loses continuity and turn-count information between segments.

At an exact half-period, both directions have equal length. The tool keeps the
raw difference's sign and marks that sample/channel in `half_period_ties`; it
does not invent an unambiguous direction. For a difference of +540 degrees with
period 360, the estimate is +180 degrees and is also marked as a tie. Adjacent
values differing by a full period reduce to zero, but that is not proof of no
movement. A recorded +300° difference becomes −60° under the explicit shortest-
displacement assumption; a genuine +300° movement would be misinterpreted.

Arithmetic uses ordinary Double precision, including the user-supplied period.
Nonfinite differences, corrections, cumulative offsets or outputs fail the
whole operation. Finite rounding, cancellation, underflow, and loss of resolution
at very large offsets remain possible. Exact tie detection follows represented
numbers, without an inferred tolerance. This operation does not denoise signals.

## Reports and reusable API

Default JSON wraps `input_file`, `recipe_file` and `unwrap`, whose format is
`moonrobo.telemetry-unwrap.v1`. It contains the explicit recipe in its original
order, algorithm/assumption/tie descriptions, gap cutoff, segment count and:

- `recording`: all output columns and rows in original CSV order
- `points`: one entry per source row, with source index, exact timestamp, segment,
  segment-start flag, selected raw values, local step adjustments, cumulative
  offsets and half-period tie flags; these arrays follow recipe order
- `gaps`: neighboring source indices/timestamps and the exact missing interval

Selected source values plus the output recording let you inspect every
correction. Untouched columns are passed through unchanged. Timestamps and
other Int64 fields are decimal strings in JSON and exact decimal text in CSV.
Numeric formatting can change; raw lexical formatting is not retained.

`--csv` emits a reusable numeric recording, retaining every source row. It drops
unit labels, original selected values, corrections, tie flags and segment IDs.
Preserve the raw CSV, recipe and JSON report together. Input paths are context
labels, not content hashes, authenticated identity or immutable MoonData lineage.
Import those files through the existing MoonData workflow separately if needed.

Pure API entry points in `src/telemetry_csv` are `parse_unwrap_recipe(text)`,
`unwrap_csv(text, channels, max_gap_ms=...)` and `TelemetryUnwrap::to_csv()`.
They return `Result[..., String]` and perform no filesystem or network I/O.
Use successful unmodified results for exports; public result arrays are mutable.
No ROS runtime, bridge, hardware, physical control or readiness test is involved.
