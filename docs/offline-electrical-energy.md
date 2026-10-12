# Inspect electrical power and observed energy offline

Use `telemetry_energy` to turn a recording's voltage and current into sample
power and gap-aware drawn, recovered and net electrical energy estimates. This
helps compare a recorded load cycle or inspect when electrical flow reversed.
It does not connect to hardware, reconstruct an unknown gap, measure battery
state of charge, qualify a battery or prove physical work was successful.

## Try the synthetic electrical cycle

The example contains seven voltage/current observations, changing load and
reversed current, plus a five-second recording gap. Work with a preserved copy
of the raw CSV and retain both the report and numeric export.

Use the supported pinned environment and an absolute external target. In the
retained delivery workspace, `BUILD.md` explains the shared native lock, disk
reserve and dependency checks. For another correctly provisioned workspace:

```sh
SOURCE=/absolute/path/to/moonrobo
TARGET=/absolute/path/outside/source/moonrobo-energy-build
# Set MOON_NATIVE_LOCK to the shared lock for the provisioned environment.
flock "$MOON_NATIVE_LOCK" moon -C "$SOURCE" --target-dir "$TARGET" build cmd/telemetry_energy cmd/telemetry_plot --target native --frozen --strip -j 1
BIN="$TARGET/native/debug/build/cmd/telemetry_energy/telemetry_energy.exe"
flock "$MOON_NATIVE_LOCK" "$BIN" "$SOURCE/examples/telemetry/electrical-cycle.csv" \
  bus.voltage.v bus.current.a --current-polarity discharge-positive \
  --max-gap-ms 2000 > energy.json
flock "$MOON_NATIVE_LOCK" "$BIN" "$SOURCE/examples/telemetry/electrical-cycle.csv" \
  bus.voltage.v bus.current.a --current-polarity discharge-positive \
  --max-gap-ms 2000 --csv > energy.csv
```

Use the executable path reported by your pinned Moon version if different.
Check free space is greater than 4 GiB before every native phase and stay within
your allocated build budget. The example yields:

- Sample powers: 48, 72, −24, 0, −48, 0 and 24 W
- Five supported intervals, 8,000 ms integrated and 5,000 ms excluded
- Two independently observed segments
- Drawn energy 138 J / 3,600 = approximately 0.0383333 Wh
- Recovered energy 54 J / 3,600 = 0.015 Wh
- Net observed energy 84 J / 3,600 = approximately 0.0233333 Wh

The 72 W to −24 W interval crosses modeled zero three-quarters of the way
through. Its draw is 54 J and recovery 6 J. Merely taking the positive/negative
parts of its net 48 J would lose both directions of flow.

The reusable CSV contains the original seven timestamps and four derived
columns: `power.w`, `observed.drawn.wh`, `observed.recovered.wh`, and
`observed.net.wh`. It can be explored, compared or plotted with existing tools:

```sh
PLOT="$TARGET/native/debug/build/cmd/telemetry_plot/telemetry_plot.exe"
flock "$MOON_NATIVE_LOCK" "$PLOT" energy.csv --channel power.w --unit W \
  --max-gap-ms 2000 --svg > power.svg
```

Use the SAME gap cutoff when plotting. The example has seven markers, two
observed line paths and one gap band. Cumulative values carry forward across
an excluded gap only as sums over supported intervals. That flat step is not
an estimate of zero consumption during the missing time. JSON retains this
important distinction; CSV alone does not retain gap metadata.

## Input and sign contract

```text
telemetry_energy INPUT.csv VOLTAGE_CHANNEL CURRENT_CHANNEL
  --current-polarity discharge-positive|charge-positive
  --max-gap-ms POSITIVE_INTEGER [--csv]
```

The existing unquoted numeric CSV contract applies: nonnegative, strictly
increasing integer millisecond timestamps; unique channel names; finite numeric
values; at least one sample. Both selected channels must exist and differ.
Every row and every channel is validated, including unused columns.

- Supply voltage in volts and current in amperes, from a common timestamped
  recording. Channel names are labels and do not prove units or synchronized
  measurement. Normalize mV/mA or other units with the explicit normalization
  tool first. The tool neither converts nor infers units.
- Voltage must be a nonnegative terminal magnitude. Negative voltage fails;
  this is not a general signed-circuit or three-phase power analyzer.
- With `discharge-positive`, positive recorded current means outward/drawn
  flow. With `charge-positive`, positive recorded current means inward/recovered
  flow, so the current sign is reversed when computing power.
- Power is voltage × normalized current. Positive power means draw and negative
  power means recovery at the measurement point. “Recovered” describes estimated
  inward electrical energy; it does not assert stored battery charge,
  electrochemical efficiency, regenerative braking or a valid charging regime.
- `max-gap-ms` is mandatory and positive. Intervals equal to the cutoff are
  included; longer intervals are excluded entirely and start a new segment.
  No interpolation or energy estimate crosses such a gap. Choose the cutoff
  based on your recording cadence, not on a supposed safety threshold.

## Integration and uncertainty

For a supported interval with duration h hours and powers P0 and P1, net energy
is the trapezoid (P0 + P1) × h / 2. Same-sign intervals contribute to draw or
recovery. Opposite-sign intervals split at |P0| / (|P0| + |P1|), then integrate
both triangles separately. The implementation uses scaled ratios and half-sums
to avoid unnecessary overflow and zero-fraction cancellation.

This models LINEAR POWER between sample points. It is not multiplication of
linearly interpolated voltage and current, and does not assert that actual
power was linear. Sample power is a derived point value; every interval energy
is a modeled estimate. Missed transients, aliasing, calibration errors, sensor
phase lag and intra-interval sign reversals are not discovered. There is no
extrapolation before the first sample or after the last.

Draw and recovery totals are nonnegative sums over supported intervals; net is
draw minus recovery. Sampling intervals are duration-weighted, not row-weighted.
The durations are computed as exact Int64 timestamp differences before Double
conversion. Disjoint duration totals cannot exceed the recording's Int64 span.
Floating-point rounding, cancellation and underflow can still affect results;
nonfinite power or accumulated energy fails the entire operation. Very small
opposite-sign fractions can round at the displayed crossing, even though both
triangle fractions are computed independently.

A singleton or entirely isolated recording has zero supported intervals and
zero integrated duration. Its zero totals mean “no interval was integrated,”
not zero real energy use. Such recordings still export their observed sample
power. No error tolerance, pass/fail limit, full-cycle consumption, charge,
capacity, state-of-health or readiness decision is inferred.

## JSON, CSV and reusable API

Successful JSON wraps `input_file` and `energy`. Format is
`moonrobo.telemetry-energy.v1`. The report retains:

- Selected channel names, explicit units, polarity and gap cutoff
- Every selected original voltage/current pair and source sample index
- Each derived sample power, segment and segment-start flag
- Each integrated interval's exact endpoint indices/timestamps, duration,
  modeled crossing fraction and drawn/recovered/net estimates
- Every excluded gap and total integrated/excluded duration
- Summary totals and the reusable derived recording

All Int64 fields are JSON strings to preserve large timestamp precision. Source
sample indices are zero-based nonblank data-row positions, not physical CSV
line numbers. File paths label inputs but do not authenticate robot, session or
capture identity. Keep the raw recording and JSON alongside the CSV; use the
separate MoonData retention workflow if durable capture identity is needed.

`src/telemetry_csv.energy_csv(text, voltage_channel, current_channel,
current_polarity=..., max_gap_ms=...)` returns `Result[TelemetryEnergy, String]`.
`TelemetryEnergy::to_csv` returns a reusable numeric recording. The pure API
has no I/O. Inputs and outputs are held in memory. Exporting arbitrary invalid
hand-constructed public result structs is outside the supported contract.

CLI success exits 0. Invalid options, input, selected channels or arithmetic
emit a JSON `error` object and exit 2, including in CSV mode. Check exit status
before consuming redirected output. The command does not modify its input.
