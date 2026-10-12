# Explore and export offline telemetry CSV

To compare two recordings by elapsed time, including bounded interpolation and
per-channel differences, use the [offline run comparison](offline-run-comparison.md)
workflow. The single-recording explorer below keeps samples as recorded.

To combine different channels from two sensor recordings into one reusable CSV,
use the [offline sensor merge](offline-sensor-merge.md). It supports an explicit
clock offset and bounded nearest-sample association with a separate source-time
report.

The existing MoonData `import-files` command archives arbitrary files as raw
payloads. A CSV imported that way is one opaque payload, not a decoded numeric
recording. Use `cmd/telemetry_csv` to inspect joint/sensor samples and export a
portable replay-oriented JSON payload without opening a bridge or robot session.

```sh
moon run cmd/telemetry_csv --target native -- examples/telemetry/joints.csv
moon run cmd/telemetry_csv --target native -- examples/telemetry/joints.csv 1020 1050
moon run cmd/telemetry_csv --target native -- examples/telemetry/joints.csv > recording.json
```

For a clean machine-readable stdout export, build once and run the compiled
executable (Moon toolchain progress output may otherwise accompany a `moon run`):

```sh
moon build cmd/telemetry_csv --target native
./_build/native/debug/build/cmd/telemetry_csv/telemetry_csv.exe examples/telemetry/joints.csv > recording.json
```

Use the executable location reported by your Moon version if it differs.
The executable accepts `INPUT.csv [START_MS END_MS]`; both bounds must be supplied
when selecting a window. `--help` describes usage. Errors emit a JSON `error`
object and exit 2. Successful results exit 0, including an empty window.

## CSV contract

- UTF-8 text, comma delimiter, unquoted fields; quoted or multiline CSV is
  deliberately unsupported and returns a line-numbered error.
- Header starts with `timestamp_ms`, then at least one unique, nonempty channel
  name. `timestamp_ms` is reserved. Header order defines value-array order.
- Example names: `joint.shoulder.rad`, `sensor.temperature.c`. Names are labels;
  units are neither guessed nor converted.
- Each data row has exactly the header's column count. Values must be finite
  floating-point numbers; decimal and scientific notation are supported.
- Timestamps are nonnegative Int64 integer milliseconds, strictly increasing.
  They are kept as recorded, without assuming Unix time or rebasing to zero.
- Whitespace around fields, CRLF, blank lines and a missing final newline work.
  At least one data row is required; missing values are errors, not zeroes.
- The entire recording is validated, including rows outside the selected window.

## JSON output

`format` is `moonrobo.telemetry-csv.v1`; `timebase` is
`milliseconds-as-recorded`. `channels` contains ordered names. Each item in
`samples` contains `timestamp_ms` and a numeric `values` array. MoonBit encodes
Int64 timestamps as JSON strings, preserving precision beyond JavaScript's safe
integer range. Consumers should parse those strings as 64-bit integers.

`sample_count` counts the selected samples. `summaries` contains each channel's
minimum, maximum, first and last values in that window. For an empty window,
channels remain present but samples and summaries are empty. Bounds are inclusive.
For the example window 1020–1050, two samples remain and shoulder minimum/maximum
are 0.1/0.25.

This is an in-memory offline explorer and JSON export, not a live playback driver
or a stored MoonData replay artifact. It does not interpolate, resample, infer
units, write a dataset catalog, or send commands to hardware. Redirecting stdout
writes an export at a path you choose. Large recordings must fit in memory.
Use MoonData `import-files` separately when you want to retain the original CSV
or exported JSON as a raw dataset payload.

The reusable `src/telemetry_csv` package exposes `parse` and `explore_csv` for
applications that already have CSV text; it performs no filesystem or network I/O.
