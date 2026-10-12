# Derive joint rates and accelerations from a recording

`telemetry_motion` turns selected recorded position channels into interval rates
or three-point acceleration estimates. This helps inspect a robot or simulation
recording when it contains joint positions but no velocity or acceleration.
The output CSV goes directly into the existing explorer and time-series plot.
The accompanying JSON retains every source stencil, output unit, unsupported
timestamp and observed source gap.

This is offline analysis, with no robot connection, program execution, SDK,
bridge, live subscriber or provider. Finite differences are estimates, not
measured velocity or proof that a motion is safe or physically complete.

## Try the synthetic two-joint recording

Build the three commands using your selected toolchain and external target:

```sh
moon --target-dir /absolute/path/to/build build cmd/telemetry_motion cmd/telemetry_csv cmd/telemetry_plot --target native --frozen --strip -j 1
```

Use the executable paths reported by your toolchain. For example, with `BIN`
pointing to the target's `native/debug/build/cmd` directory:

```sh
"$BIN/telemetry_motion/telemetry_motion.exe" examples/telemetry/joint-motion.csv joint.shoulder.rad,joint.slider.m --units rad,m --order 1 --max-gap-ms 750 > rates.json
"$BIN/telemetry_motion/telemetry_motion.exe" examples/telemetry/joint-motion.csv joint.shoulder.rad,joint.slider.m --units rad,m --order 2 --max-gap-ms 750 > acceleration.json
"$BIN/telemetry_motion/telemetry_motion.exe" examples/telemetry/joint-motion.csv joint.shoulder.rad,joint.slider.m --units rad,m --order 2 --max-gap-ms 750 --csv > acceleration.csv
"$BIN/telemetry_csv/telemetry_csv.exe" acceleration.csv > explored.json
"$BIN/telemetry_plot/telemetry_plot.exe" acceleration.csv --channel joint.shoulder.rad.acceleration --unit rad/s^2 --max-gap-ms 750 --svg > acceleration.svg
```

There are eight irregularly spaced source observations in two segments, separated
by a 2500 ms gap. Order 1 produces six rate estimates: shoulder rates are
0.25, 1.25 and 2.5 rad/s in each segment; slider rate is 2 m/s throughout.
Order 2 produces four estimates at 10250, 11000, 14250 and 15000 ms. Shoulder
acceleration is 2 rad/s² and slider acceleration is 0 m/s² at each supported
stencil. Both plots remain split across the gap when using the same cutoff.
The large position jump between segments does not create a velocity spike.

The existing [JointState importer](offline-ros2-joint-state.md) can supply
position CSV to this command as well. Import position fields, choose the matching
channels and original units, and retain the import report alongside this report.

## Input and command contract

```text
telemetry_motion INPUT.csv CHANNEL[,CHANNEL]
  --units UNIT[,UNIT] --order 1|2 --max-gap-ms MS [--csv]
```

- Input follows the [numeric CSV contract](offline-telemetry-csv.md): distinct
  channel names, finite numeric values, nonnegative strictly increasing Int64
  integer timestamps in milliseconds. Every row and every channel is validated,
  including values not selected for differentiation. Input and output fit in memory.
- Select at least one channel. Selection is by exact name, in the requested order;
  missing names and duplicates are errors. Output names append `.rate` for order 1
  or `.acceleration` for order 2.
- `--units` is required and supplies one source-position label per channel in the
  same order. JSON output records `(UNIT)/s` or `(UNIT)/s^2`. The labels do not
  convert values, check calibration or prove that a channel measures position.
- `--max-gap-ms` is required and positive. An adjacent interval exactly at the
  cutoff is included; a longer interval starts a new source segment. Choose a
  cutoff appropriate to the cadence. There is no smoothing, interpolation,
  extrapolation or gap filling.
- Default output is JSON; `--csv` outputs only supported estimates. `--help`
  describes the command. Unknown/duplicate options, missing values, bad input
  and arithmetic overflow emit one JSON error and exit 2, including in CSV mode.
  No partial data precedes an error. Success exits 0.

## What the numbers mean

Let `q[i]` be a selected position, and let `h_left` and `h_right` be the adjacent
timestamp differences converted from milliseconds to seconds.

Order 1 uses `(q[i] - q[i-1]) / h_left`. This is the average signed rate over
that interval. It is assigned to the interval's right source timestamp for CSV
compatibility; it is not an instantaneous measurement at that timestamp. No
rate is emitted at the start of a recording or after a gap.

Order 2 uses:

```text
v_left  = (q[i]   - q[i-1]) / h_left
v_right = (q[i+1] - q[i])   / h_right
a[i]    = (v_right - v_left) / ((h_left + h_right) / 2)
```

This is the second derivative of the quadratic through the three nonuniformly
spaced positions, assigned to the middle source timestamp. It exactly reproduces
quadratic positions up to floating-point rounding. For other motion it is a local
estimate over the full stencil, not necessarily the true acceleration at the
middle instant. It needs both neighboring samples and cannot be computed at
either recording boundary or where either adjacent interval crosses a gap.

Timestamp subtraction happens in Int64 before Double conversion, preserving
short intervals even for epoch values beyond 2^53. Numerical differentiation
amplifies noise, particularly acceleration. Finite input or intermediate
subtraction/rate overflow can make an estimate unrepresentable; the whole operation
then fails. No clamping or silent zero replacement is used. Ordinary floating-point
rounding and underflow remain possible.

Use positions in a consistent coordinate frame and calibration. Wrapped angles
must be unwrapped before use: `rad` does not cause angle unwrapping, and a wrap
would appear as a large position jump. This tool does not infer physical limits,
detect hidden motion between samples, retime a program, or qualify hardware.

## Reports and reuse

JSON format `moonrobo.telemetry-motion.v1` records the method, timestamp assignment,
order, cutoff, source sample count, segment count, ordered channel/unit mappings,
and derived `recording`. `stencils` aligns one-for-one with the output recording
and retains zero-based source sample indices, exact source timestamps, selected
source values and zero-based segment. These indices count parsed sample rows,
not physical file lines. Int64 JSON timestamps and durations are decimal strings.

`unavailable` records each source timestamp lacking an estimate with a boundary,
gap-before, gap-after or gap-before-and-after reason. `gaps` records each source
interval exceeding the cutoff once. A singleton, too-short segment or entirely
disconnected recording succeeds as a JSON report with no estimates. CSV export
then fails explicitly instead of producing a recording that appears to contain
zero motion.

CSV has the standard timestamp/channel layout and omits unknown estimates;
it does not contain unit labels, method, stencils or gap markers. Keep the JSON
and raw input together. Use the same gap cutoff when plotting to avoid connecting
unrelated segments. Derived samples can also feed the existing threshold-event
tool, but any chosen threshold is an analysis criterion, not a safety qualification.

The pure API is `src/telemetry_csv.motion_csv(text, channels, unit_labels~,
order~, max_gap_ms~)` returning `TelemetryMotion`. `TelemetryMotion::to_csv`
exports its supported estimates. Export is intended for results returned by the
API; hand-built inconsistent public records are outside its contract. Neither
operation accesses files, networks or devices. File paths and source stencils are
context, not authenticated robot/session identity or a sealed MoonData capture.

For periodic position channels, use [offline periodic unwrapping](offline-periodic-unwrapping.md) first when the shortest-displacement sampling assumption is justified. Keep the same gap cutoff for unwrapping and differentiation.
