# Smooth irregular recorded telemetry without filling unknown intervals

`cmd/telemetry_smooth` turns an irregular numeric recording into centered,
time-weighted moving means at supported original timestamps. This is useful for
inspecting a noisy joint-position trend before using the existing motion or plot
commands. It is an offline transformation of a chosen mathematical model.
Original observations remain in JSON; the output channels have `.mean` suffixes.

## Complete example

Use the retained pinned environment and an absolute external build target:

```sh
R=/workspace/scratch/665adc5202cf/.moonsuite-background/r336-340/work/r337-moonrobo
. "$R/environment.sh"
bash "$R/verify-native.sh"
B="$R/target/native/debug/build/cmd"
"$B/telemetry_smooth/telemetry_smooth.exe" \
  "$R/source/examples/telemetry/smoothing-session.csv" joint.rad,temp.c \
  --half-window-ms 150 --max-gap-ms 200 > smooth.json
"$B/telemetry_smooth/telemetry_smooth.exe" \
  "$R/source/examples/telemetry/smoothing-session.csv" joint.rad,temp.c \
  --half-window-ms 150 --max-gap-ms 200 --csv --segment 0 > smooth-0.csv
"$B/telemetry_motion/telemetry_motion.exe" smooth-0.csv joint.rad.mean \
  --units rad --order 1 --max-gap-ms 200 > smoothed-motion.json
"$B/telemetry_plot/telemetry_plot.exe" smooth-0.csv \
  --channel joint.rad.mean --unit 'rad (time-window mean)' \
  --max-gap-ms 200 --svg > smoothed-position.svg
```

The packet verification script serializes actual executable calls with the shared
native lock and checks capacity. Use that script in this shared workspace.
The commands above describe the user-facing interface, not an instruction to
bypass that wrapper while other builds are active.

The synthetic example has twelve observations and a 1300 ms recording gap.
With the explicit 150 ms half-window (300 ms full width), six source timestamps
have complete support. The first segment's output is 2.25, 2.75 and 3.25 rad at
250, 400 and 550 ms. Six centers stay unsupported. The two connected output
segments must be exported separately. A rate computed from the first export is
approximately 3.333333 rad/s; it describes the smoothed model, not measured
velocity. Neither filtering nor a plausible rate proves anything about hardware.

## Model and gaps

For a source timestamp t and half-width H, the result is

    mean(t) = integral from t-H to t+H of linear_recorded_curve(u) du / (2H)

Each clipped source interval contributes its trapezoid area, weighted by elapsed
time. It is not an arithmetic average of the rows in the window. A ten-millisecond
interval contributes a tenth as much duration as a hundred-millisecond interval.
Window endpoints inside source intervals use linear endpoint interpolation.

- Every source row and channel is validated first, including unselected channels.
  The existing [numeric CSV contract](offline-telemetry-csv.md#csv-contract) applies.
- Timestamps are nonnegative, strictly increasing Int64 milliseconds. Units,
  clocks, calibration, coordinate frames and timing jitter are not inferred.
- Source intervals longer than `--max-gap-ms` split connected segments; equality
  is allowed. The full centered window must fit within one segment. The program
  never shortens a window, extrapolates, carries a value through a gap, or inserts
  artificial zero values. A source observation is not automatically a supported
  filtered estimate.
- Unsupported centers are `recording-boundary` when the window extends past the
  overall recording, otherwise `source-gap-overlaps-window`. The recording-boundary
  reason has precedence if both apply; all source gaps are still present in JSON.
- The integration includes only intervals with positive overlap. An exact left
  endpoint excludes the preceding interval; an exact right endpoint excludes
  the following one. Merely touching a gap does not cross it.
- Centered filtering uses future observations and is unsuitable for a causal
  live control loop. Smoothing can hide peaks, attenuate fast movement and alter
  event timing. This box filter is not a guarantee of anti-aliasing or noise
  removal; choose the window deliberately and keep the raw data for inspection.
- This numeric method is unsuitable for wrapped angles, categorical channels,
  discontinuities or quaternions without domain-specific processing. For periodic
  positions, consider the existing [unwrapping](offline-periodic-unwrapping.md)
  workflow first, while retaining its ambiguity assumptions and segment choices.
- Floating point calculations use normalized endpoints and compensated summation
  to avoid avoidable overflow; rounding and underflow still apply. The normalized
  result is clamped to [-1, 1] before restoring the per-window magnitude scale,
  enforcing the mathematical convex-mean bound against rounding overshoot.

## JSON, CSV and API

Success exits 0. Invalid options/input, unsupported CSV selection and bounded-work
limits emit a JSON `error` and exit 2, including in CSV mode. `--help` lists flags.
All flags may occur once. Both `--half-window-ms` and `--max-gap-ms` are required.
The half-width is 1 through 4611686018427387903 ms; gap cutoff is positive.
Everything fits in memory. There is a 100000-source-row cap and at most 1000000
interval-channel contributions across all supported windows. Reduce the window,
selected channels or recording length if the contribution limit is exceeded.
Split records with enough overlapping input to support the wanted edge windows;
a split without overlap loses filtered edge values.

JSON has `input_file` and `smooth`, with format `moonrobo.telemetry-smooth.v1`:

- `source` retains all selected original channel values in requested order.
  Source row indices refer to that full recording, not line numbers or the output.
- `recording` has derived `.mean` channel names and only supported source times.
- `points` aligns one-to-one with output rows and stores original center index,
  exact full-window bounds, source segment, and inclusive first/last source indices
  needed to reconstruct the integral from `source`. No source values are silently
  overwritten by estimates.
- `missing` identifies every omitted original center and reason. `source_gaps`
  retains every excessive original interval with indices, timestamps and duration.
- Both source and output segment counts are explicit. Segment IDs follow the full
  source, so the first supported output need not be segment 0.
- Int64 values are JSON strings, preserving exact timestamps beyond 2^53.

CSV contains `timestamp_ms` and suffixed numeric channels. Without `--segment`,
it succeeds only when the output is nonempty and all means belong to one source
segment. With multiple output segments, select an ID shown in JSON. Empty or
nonexistent segments fail. `--segment` requires `--csv`; JSON always retains the
complete analysis. Keep JSON and the original input beside exports: CSV alone
omits the model, missing centers and lineage. Do not concatenate disconnected
segments for a downstream operation that would reconnect across their gap.

The reusable API is `src/telemetry_csv.smooth_csv(text, channels,
half_window_ms=..., max_gap_ms=...) -> Result[TelemetrySmooth, String]`.
`TelemetrySmooth::to_csv(segment?)` exports one connected subset. Like the
existing resampling API, source gaps use the public `ResampleSourceGap` record;
no redefinition or altered existing behavior is required. API inputs are CSV
text; there is no file mutation, network access, provider, device or dispatch.
Input paths are context, not content hashes or durable MoonData evidence IDs.
This contributes to inspectable processing, not full PRD acceptance or durable
proof retention.
