# Plot recorded telemetry over time

The resulting JSON can also be opened locally in the cockpit's
[historical telemetry review dialog](offline-telemetry-cockpit.md).

Use `telemetry_plot` to visually inspect selected channels in one numeric CSV.
It creates a standalone SVG with stacked panels and a shared recorded-time axis,
plus a JSON report retaining the exact selected observations. This fills the gap
between the numeric explorer and the spatial XY route: it shows how each channel
changed over time, including uneven sampling and visibly disconnected gaps.
No threshold, incident, calibration, readiness or hardware outcome is inferred.

## Run the synthetic example

From the repository, build into an external directory of your choice:

```sh
moon build cmd/telemetry_plot --target native --frozen --strip -j 1 --target-dir /tmp/moonrobo-plot-build
/tmp/moonrobo-plot-build/native/debug/build/cmd/telemetry_plot/telemetry_plot.exe examples/telemetry/plot-recording.csv --channel motor.current.a --unit A --channel temperature.c --unit °C --max-gap-ms 500 --svg > plot.svg
/tmp/moonrobo-plot-build/native/debug/build/cmd/telemetry_plot/telemetry_plot.exe examples/telemetry/plot-recording.csv --channel motor.current.a --unit A --channel temperature.c --unit °C --max-gap-ms 500 > plot.json
```

Use the executable location reported by your Moon version if different. Open
`plot.svg` in an SVG-capable viewer or browser. The six synthetic rows make two
panels and two segments separated by a 1500 ms gap. The first observation is at
9007199254740993 ms, deliberately beyond JavaScript's exact Number range.
No browser, robot, network account or device is required to produce the files.

To focus on three observations, add:

```text
--window 9007199254741093 9007199254741493
```

## Options and input

```text
telemetry_plot INPUT.csv --channel NAME [--channel NAME ...]
  [--unit LABEL ...] [--max-gap-ms MS] [--window START_MS END_MS] [--svg]
```

- Select at least one existing channel by exact name. Repeat `--channel` in the
  desired panel order. Duplicate selected names are errors; there is no inferred
  channel selection or renaming.
- Optional `--unit` labels are in selected-channel order, regardless of where
  options appear. Supply exactly one per channel, or omit all for `unspecified`.
  Labels are descriptive text only. They do not convert or validate units.
- The existing [numeric CSV contract](offline-telemetry-csv.md#csv-contract)
  applies: unquoted rectangular CSV; header `timestamp_ms` followed by unique
  named channels; finite Double values; nonnegative, strictly increasing Int64
  timestamps. Blank lines and CRLF are supported. All rows and channels are
  validated before selection, including excluded channels and out-of-window rows.
- `--window` uses inclusive absolute recorded milliseconds, defaulting to the
  whole recording. It does not insert observations at boundaries. A window with
  no observations is an error. Single observations and constant channels work.
- `--max-gap-ms` is a positive integer, default 1000. Consecutive selected rows
  with a larger interval start another segment; equality remains connected.
  Amber bands and disconnected paths mark those gaps. Choose this value for your
  recording cadence. It is not a health threshold or proof of continuity.
- Names and unit labels used in the SVG must be nonblank, single-line text without
  unsupported XML controls. XML metacharacters are escaped, including repeated
  characters. Long combined panel labels are shortened after 60 Unicode
  characters; the complete label remains in tooltips and JSON.

## Reading the plot

Every selected channel has its own Y scale from its observed minimum to maximum.
Panel heights therefore do not compare magnitudes across channels. Constant
channels are centered and explicitly labeled `constant`; a single timestamp is
centered on X. The axes do not force a zero baseline.

The shared X axis shows elapsed milliseconds from the first selected sample.
Exact recorded first/last times are printed in the footer. Timestamp subtraction
happens in Int64 before conversion to display coordinates, so nearby times above
2^53 remain separately placed. Very long spans and dense recordings can still
make distinct observations overlap at screen resolution. Hover each dot for the
exact recorded timestamp, value, source sample position and segment number.

Dots are observations. Straight connecting lines are visual guides only; they
are not interpolated measurements or evidence of what happened between samples.
There is no smoothing, downsampling, resampling or extrapolation. Finite opposite
numeric extremes are supported without overflowing the display coordinates.
A viewer's own rasterization may round geometry, but JSON retains recorded data.

## Report and reusable API

Default JSON format is `moonrobo.telemetry-plot.v1`. It contains:

- `start_ms`, `end_ms`, `max_gap_ms` and `timebase` describing the explicit selection
- `source_sample_count`, `segment_count` and `gap_count`
- Ordered `channels`, each with exact name, supplied/default unit label, minimum
  and maximum over the selected rows
- `samples`, with exact `timestamp_ms`, zero-based `source_sample_index` in the
  complete parsed recording, zero-based `segment`, `connected` and ordered values

The first selected sample has `connected=false`, even when an earlier observation
exists outside the window. JSON Int64 fields are strings, preserving exact
integer timestamps. CSV line numbers are not sample positions; blank lines do
not consume sample positions. Keep raw input and JSON beside the SVG: the SVG is
a visual export, and neither output establishes immutable source identity.

`src/telemetry_csv.plot_csv` takes CSV text, selected names and optional
`unit_labels`, `start_ms`, `end_ms` and `max_gap_ms`. It returns
`Result[TelemetryPlot, String]`. Call `TelemetryPlot::to_svg` on an unmodified
successful result. Export of hand-constructed or subsequently mutated records
is outside this contract. The library performs no I/O.

Both input and output are whole-file, in-memory operations. Every observation
produces a marker in every selected panel, so large files or many panels can
make large/slow SVGs. Select fewer channels or a narrower time window as needed.
Normalized or merged CSV exports work as input under their existing contracts;
this tool does not restore omitted rows or infer missing values.

Success exits 0. Bad files, empty windows, missing channels, mismatched unit
counts and invalid/unknown/duplicate options emit a JSON `error` on stdout and
exit 2, even with `--svg`. Check the exit status before treating redirected output
as SVG. The command writes stdout only and does not modify source files.
No MoonData catalog write, live stream, physical qualification or dispatch occurs.
