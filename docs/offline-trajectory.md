# Inspect recorded XY motion

`telemetry_path` turns two named Cartesian position channels from an existing
numeric CSV into a spatial route, interval distance/speed data and JSON summary.
Use it to inspect recorded rover motion, stationary periods and missing sections
without a robot connection. It supplements the channel explorer and two-run
comparison: no hardware, simulation driver or dispatch is opened.

## Quick start

```sh
moon build cmd/telemetry_path --target native
./_build/native/debug/build/cmd/telemetry_path/telemetry_path.exe examples/telemetry/rover-path.csv pose.x.m pose.y.m --units m --svg > route.svg
./_build/native/debug/build/cmd/telemetry_path/telemetry_path.exe examples/telemetry/rover-path.csv pose.x.m pose.y.m --units m > route.json
./_build/native/debug/build/cmd/telemetry_path/telemetry_path.exe examples/telemetry/rover-path.csv pose.x.m pose.y.m --units m --window 10500 12000 --csv > interval.csv
```

Use the executable path reported by your toolchain. Open the standalone SVG in
any SVG-capable browser or image viewer. It uses equal X/Y scales, Y upward,
visible samples and separate strokes across gaps. Hover a sample for exact
recorded time, coordinates and zero-based segment number. Green marks the first
sample and orange the last; overlapping samples can hide earlier markers.
JSON and CSV retain every selected sample even when markers overlap.

The synthetic sample contains two route segments separated by a 3000 ms outage.
With the default 1000 ms cutoff it yields 20 m of observed chord distance over
3000 ms of connected intervals, one gap, and 10 m/s peak interval speed. The
stationary 11500–12000 ms interval has zero distance and speed. Nothing estimates
the missing motion between (6, 8) and (10, 9).

## Input and options

The [existing numeric CSV contract](offline-telemetry-csv.md) applies: unquoted,
rectangular finite numeric fields; `timestamp_ms` followed by distinct named
channels; nonnegative strictly increasing Int64 timestamps. All rows and channels
are validated before filtering, including excluded rows. Extra channels are
accepted but do not affect geometry. Entire input must fit in memory.

```text
telemetry_path INPUT.csv X_CHANNEL Y_CHANNEL
  [--units LABEL] [--max-gap-ms MS] [--window START_MS END_MS]
  [--svg | --csv]
```

- X and Y must be distinct existing Cartesian position channels with the same
  linear units, frame and calibration. Mapping is explicit, independent of column
  order. Longitude/latitude, joint angles and mixed units are not Cartesian input.
- `--units` labels output only; default `coordinate-units`. It never converts or
  checks physical units. Speeds use that unit per second.
- `--max-gap-ms` is a positive interval cutoff, default 1000. Intervals exactly at
  the cutoff are connected; longer intervals start a new segment. Choose it for
  the recording cadence, not as an automatic judgment of sensor health.
- `--window` uses inclusive absolute recorded milliseconds, unlike the comparison
  tool's elapsed-time window. No point is created at a window boundary. A window
  without positions is an error; singleton and stationary paths are supported.
- Output defaults to JSON; `--svg` and `--csv` are mutually exclusive. Errors
  produce a JSON error object and exit 2, even when SVG/CSV was requested. Check
  exit status before treating redirected output as a valid export.

## Interpreting exports

JSON format is `moonrobo.trajectory.v1`. Bounds cover selected points;
`observed_distance` sums Euclidean straight-line chords only for connected
adjacent samples. `observed_duration_ms` sums those intervals. `peak_interval_speed`
is the largest chord distance divided by interval seconds, not instantaneous
speed. No smoothing, interpolation, extrapolation, acceleration or turn inference
occurs. Coarse samples can miss turns/excursions and underestimate actual travel.
Coordinate/distance/speed overflow produces an error instead of a non-finite export.

Each point includes timestamp, X/Y, zero-based segment and `connected`. For the
first point and the first point after a gap, incoming distance and speed are
unavailable: JSON uses zero placeholders with `connected=false`; CSV leaves both
cells blank. Connected stationary intervals have explicit numeric zeros. JSON
Int64 values are strings to preserve large timestamps. CSV timestamps remain
exact decimal integers. Exported CSV uses fixed column names; retain the JSON or
source file to preserve the channel mapping and units label.

The SVG is a bounded-size overview, not an interactive playback UI; very long
labels or dense recordings are better inspected in JSON/CSV. It contains escaped
labels, no script, network reference or external font. Huge/dense files are not
streamed or downsampled. Singletons use the last-point color (orange).

The reusable `src/telemetry_csv` API exposes `trajectory_csv`, `Trajectory::to_svg`
and `Trajectory::to_csv`. Export methods expect a result from `trajectory_csv`;
hand-constructing invalid public records is outside their contract.

These are derived offline observations, not proof of physical completion,
calibration correctness, robot identity or a safe action. Preserve the raw CSV
and its session/robot/frame metadata separately. Existing PRD requirement statuses
and physical qualification claims are unchanged.
