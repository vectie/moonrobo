# Merge independently recorded sensor channels

Use `telemetry_merge` when pose and sensor channels are in separate numeric CSV
recordings and you need one recording for plotting, comparison or a spreadsheet.
It combines every input channel on the primary file's timestamps. Unlike the
two-run comparison, channels need not have the same names and values are joined,
not subtracted. This is local, in-memory data preparation; no bridge is opened.

## Try the synthetic pose and sensor recordings

Build once for clean machine-readable stdout, then keep both the alignment
report and the reusable numeric CSV:

```sh
moon build cmd/telemetry_merge --target native
./_build/native/debug/build/cmd/telemetry_merge/telemetry_merge.exe \
  examples/telemetry/merge-pose.csv examples/telemetry/merge-sensors.csv \
  --primary-prefix pose --secondary-prefix sensors \
  --secondary-offset-ms 5000 --tolerance-ms 20 > merged-report.json
./_build/native/debug/build/cmd/telemetry_merge/telemetry_merge.exe \
  examples/telemetry/merge-pose.csv examples/telemetry/merge-sensors.csv \
  --primary-prefix pose --secondary-prefix sensors \
  --secondary-offset-ms 5000 --tolerance-ms 20 --csv > merged.csv
```

Use the executable path reported by your Moon toolchain if different. In this
synthetic example the secondary clock is explicitly known to be 5000 ms behind
the primary clock. The tool does not discover that offset. The report contains
four complete rows: one exact and three nearest matches, with offsets of 0,
-10, +10 and +10 ms. Primary timestamps 10300 and 10500 have no sensor observation
within 20 ms and are listed as unmatched. One secondary sample is unused.

`merged.csv` has this data (numeric spelling can vary by toolchain):

```csv
timestamp_ms,pose.x.m,pose.y.m,sensors.current.a,sensors.temperature.c
10000,0,0,1,20
10100,3,4,2,21
10200,6,8,3,22
10400,9,12,4,23
```

This CSV is accepted by the existing explorer, comparator and trajectory tool:

```sh
moon run cmd/telemetry_csv --target native -- merged.csv
moon run cmd/telemetry_path --target native -- merged.csv pose.x.m pose.y.m --units m --svg > merged-route.svg
```

For clean redirected output from those tools, build and invoke their executables
as described in the [explorer](offline-telemetry-csv.md) and
[trajectory](offline-trajectory.md) guides. The sample merged route has 15 m of
observed chord distance. Original primary rows omitted during merging are not
restored by downstream tools; retain the original pose file for full-path work.

## Alignment contract

```text
telemetry_merge PRIMARY.csv SECONDARY.csv
  [--primary-prefix LABEL] [--secondary-prefix LABEL]
  [--secondary-offset-ms SIGNED_MS] [--tolerance-ms MS] [--csv]
```

- Both inputs follow the [numeric CSV contract](offline-telemetry-csv.md#csv-contract).
  All rows and all channels are validated, including rows that will not be used.
  Inputs must each contain at least one sample and fit in memory.
- The primary timestamps remain exactly as recorded. Neither file is rebased to
  elapsed zero. Use recordings with a known common millisecond timebase, or supply
  a known constant secondary offset. Clock drift, clock domain and event alignment
  are not inferred. Offsets resulting in a negative or overflowing timestamp fail.
- Default tolerance is zero: only exact aligned timestamps match. A nonnegative
  `--tolerance-ms` allows the nearest observed secondary sample within that many
  milliseconds, inclusive. Equal-distance ties choose the earlier sample.
- Nearest matching may choose an earlier or later observation, including the
  nearest endpoint outside the secondary recording's time range. It never creates
  interpolated values. This offline association is unsuitable as a causal live
  controller input. Choose a tolerance justified by your recording cadence.
- The same secondary row may be associated with several primary rows. The report
  marks each reuse after the first and counts reused placements and unused source
  rows. Reused values are not new measurements.
- Only matched primary rows appear in the combined numeric recording. Missing
  sensor data is never zero-filled. Gaps can therefore remain in its timestamp
  grid. Inspect the report before using the CSV in downstream analysis.
- Channel order is primary columns followed by secondary columns. Default names
  are `primary.ORIGINAL` and `secondary.ORIGINAL`; prefixes distinguish same-name
  sensors. Use `--primary-prefix ""` or `--secondary-prefix ""` to keep original
  names where they remain unique. Resulting name collisions are errors. Prefixes
  cannot contain commas, double quotes, line breaks or surrounding whitespace.
- Units and frames stay as supplied. Merging does not convert units, identify
  robots, establish calibration compatibility or establish physical readiness.

## Outputs and API

JSON is the default. It wraps `primary_file`, `secondary_file` and `merge`.
The merge format is `moonrobo.telemetry-merge.v1`. It records alignment options,
counts, the combined `recording`, one `matches` entry per output row, and
`unmatched` primary rows with the nearest source timestamp and rejection reason.
`delta_ms` always means aligned secondary timestamp minus primary timestamp;
both original and shifted secondary timestamps are retained. Int64 fields are
JSON strings so large timestamps remain exact. Paths label inputs but do not
prove immutable content identity. Preserve the original files separately.

`--csv` emits only the reusable numeric recording. It omits alignment metadata,
source times and unmatched rows, so retain the JSON report alongside the CSV.
Zero matches is a successful JSON report with an empty recording; CSV mode
instead fails because an empty recording is not valid input to existing tools.
All errors emit a JSON `error` object and exit 2, including in CSV mode. Success
exits 0. Check the exit code before consuming redirected output.

The reusable `src/telemetry_csv.merge_csv` function has the same options and
returns `TelemetryMerge`. `TelemetryMerge::to_csv` returns `Result[String, String]`
and rejects an empty result. Exporting hand-constructed invalid public records
is outside its contract. The package performs no I/O. Use MoonData `import-files`
separately if the raw inputs and derived exports need dataset retention; this
command does not create MoonData artifacts or mutate input files.
