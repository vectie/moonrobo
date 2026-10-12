# Reconstruct a fixed-cadence telemetry grid offline

`telemetry_resample` evaluates selected numeric channels on an explicit uniform
millisecond grid. This connects existing CSV/JSONL imports to reusable fixed-rate
numeric output and existing exploration, plotting and comparison tools. Irregular
samples are piecewise-linearly interpolated only inside an explicitly permitted
source interval. The output distinguishes source observations from estimates.

This is descriptive offline processing. It cannot establish robot readiness,
command completion, physical motion, telemetry authenticity or safe control.
It neither contacts a device nor imports a ROS runtime or MoonData store.

## Example: inspect two separated capture segments

After a native build, set `BIN` to the external native build command directory:

```sh
BIN="$TARGET/native/debug/build/cmd"
"$BIN/telemetry_resample/telemetry_resample.exe" \
  examples/telemetry/irregular-grid.csv position.m,temperature.c \
  --start-ms 0 --end-ms 2300 --step-ms 100 --max-gap-ms 300 > grid.json
```

There are 24 requested grid times. Four coincide with observations and five are
interpolated. Three times fall outside the source range; twelve lie inside the
1300 ms recording gap from 600 to 1900. No values are generated at those fifteen
unsupported times. Source segment 0 contains six output rows at 100–600 ms;
segment 1 contains three at 1900–2100 ms. The 2000 ms estimate is 4.5 m and 27 °C.

Export each segment for the existing tools:

```sh
"$BIN/telemetry_resample/telemetry_resample.exe" \
  examples/telemetry/irregular-grid.csv position.m,temperature.c \
  --start-ms 0 --end-ms 2300 --step-ms 100 --max-gap-ms 300 \
  --csv --segment 1 > grid-segment-1.csv
"$BIN/telemetry_csv/telemetry_csv.exe" grid-segment-1.csv > exploration.json
"$BIN/telemetry_plot/telemetry_plot.exe" grid-segment-1.csv \
  --channel position.m --unit 'm (resampled estimate)' \
  --max-gap-ms 100 --svg > grid-segment-1.svg
```

Keep `grid.json`, the original input and the processing parameters beside the
CSV/SVG. The existing plot consumes derived CSV as a recording; its markers are
not additional raw sensor measurements. Use an explicit derived-value label.
Do not concatenate segment CSVs and assume a continuous capture.

## CLI contract

```
telemetry_resample INPUT.csv CHANNEL[,CHANNEL...] \
  --start-ms MS --end-ms MS --step-ms MS --max-gap-ms MS \
  [--csv [--segment N]]
```

All four timing options are required. Channel names are case-sensitive; selection
order determines output order. Empty, missing and duplicate channels are errors.
Options must not be repeated. `--segment` requires `--csv`; JSON always reports
the complete operation. Errors are JSON on stdout with exit status 2. No output
file is written by the command itself; shell redirection is controlled by you.

- `0 <= start_ms <= end_ms`, `step_ms > 0`, `max_gap_ms >= 0`.
- Grid timestamps are `start_ms + k * step_ms <= end_ms`. The start is the grid
  origin, not the input's first sample or an inferred clock. An unaligned end
  is not appended. Equal start/end requests one point.
- Integer grid and bracket subtraction use nonnegative Int64 timestamps before
  conversion to Double, preserving small offsets above 2^53 milliseconds.
- At most 100000 grid times are allowed per operation. Narrow a requested window
  or increase its step for larger spans. Input, provenance and output fit in
  memory; this is not a streaming implementation.
- Every input row and channel is validated using the existing strict numeric CSV
  parser, even outside the requested window or selection. The parser accepts
  blank lines/CRLF, requires strictly increasing nonnegative timestamps, and
  rejects quoted fields and nonfinite values.

## Interpolation and gaps

At an exact source timestamp the value is preserved, regardless of gap cutoff.
Otherwise the two enclosing original rows must be no more than `max_gap_ms`
apart. A span exactly at the cutoff is allowed. A zero cutoff means exact-only.
No extrapolation, nearest-neighbor substitution, edge fill or missing-value zero
is generated. Each channel is evaluated independently with the same bracket:

`right_weight = (grid_time - left_time) / (right_time - left_time)`

`estimate = (1 - right_weight) * left_value + right_weight * right_value`

The implementation uses an algebraically equivalent difference form for same-sign
endpoints to avoid intermediate overflow; opposite signs use the convex sum.
Nonfinite results fail the entire operation. Floating-point rounding and
underflow remain possible, including a very long span's weight rounding to 1.

Every original interval exceeding the cutoff splits a source segment, including
intervals outside the requested window and gaps entirely between grid times.
Segment IDs are zero-based and stable relative to the full input. This matters
when the grid is coarse: adjacent accepted grid times can straddle a source gap
even when no requested grid point was omitted. CSV without `--segment` therefore
fails when accepted points belong to multiple source segments. With one output
segment it exports that segment automatically, even if its ID is not zero.
Unknown, empty or negative segment IDs fail. No-supported-point JSON is a valid
inspection result; an empty numeric CSV export is an error.

## JSON and pure API

`resample_csv(text, channels, start_ms~, end_ms~, step_ms~, max_gap_ms~)` returns
`Result[TelemetryResample, String]` in `vectie/moonrobo/src/telemetry_csv`.
`result.to_csv(segment?)` returns one connected segment's numeric CSV.

CLI JSON wraps the report under `resample`, with `input_file` beside it. The
format is `moonrobo.telemetry-resample.v1`; Int64 fields serialize as decimal
strings. Important fields:

- `recording`: selected channel names and supported grid values in timestamp order
- `points`: one entry per output row, carrying grid index, timestamp, exact flag,
  source segment, bracket row indices/timestamps/selected values and right weight
- `missing`: one entry per unsupported grid time with grid index and reason
  `outside-source-range` or `source-gap-exceeds-limit`
- `source_gaps`: all excessive original intervals with indices, timestamps and
  durations, including gaps containing no grid point
- Counts: source rows/segments, distinct output segments, grid times, exact and
  interpolated points. `exact_count + interpolated_count + missing.length`
  equals `grid_count`.

Source sample indices are zero-based numeric rows after blank-line removal,
not physical input line numbers. For exact points both indices, timestamps and
selected source-value arrays are the same and `right_weight` is zero. JSON does
not persist unselected channels or raw file bytes; retain the original file.
These are processing lineage fields, not durable MoonData capture identity.

## Interpretation limits

Choose a step and cutoff appropriate to the measured signal. This operation is
not an anti-alias filter: a coarse grid can miss peaks, transitions and intermediate
source observations, and a fine grid adds estimates without new information.
Do not use it to treat linear interpolation as measured dynamics. It does not
infer units, align clocks, calibrate sensors, smooth noise or repair corruption.

Categorical/state channels, wrapped angles, quaternions, impulses and discontinuous
signals are generally unsuitable for scalar linear interpolation. Use the existing
explicit periodic-channel unwrap workflow first when its assumptions apply.
Downstream derivatives/energy calculated from resampled values are estimates
of the interpolation model and need not match calculations on original data.
The gap cutoff only bounds interpolation; it does not prove what happened between
observations or authorize any physical action.
