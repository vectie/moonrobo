# Import recorded JSON Lines telemetry

For ROS 2 `JointState` messages with name-indexed arrays and sec/nanosec stamps,
use the [JointState importer](offline-ros2-joint-state.md).

`telemetry_import_jsonl` brings a structured recorder export into the existing
offline numeric workflow. Supply exact object-key paths for time and each channel;
the command produces reusable CSV or a JSON report with source-line lineage.
It reads local files and writes stdout. No robot, live stream, account or bridge
is contacted, and no readiness, calibration or physical outcome is inferred.

## Try the synthetic recorder export

Build the importer and existing consumers into an external target directory:

```sh
moon build cmd/telemetry_import_jsonl cmd/telemetry_csv cmd/telemetry_plot --target native --frozen --strip -j 1 --target-dir /tmp/moonrobo-jsonl-build
```

Run the executables at the locations reported by your Moon version. With the
current toolchain, from this repository:

```sh
/tmp/moonrobo-jsonl-build/native/debug/build/cmd/telemetry_import_jsonl/telemetry_import_jsonl.exe examples/telemetry/structured-recording.jsonl examples/telemetry/structured-recipe.json > imported-report.json
/tmp/moonrobo-jsonl-build/native/debug/build/cmd/telemetry_import_jsonl/telemetry_import_jsonl.exe examples/telemetry/structured-recording.jsonl examples/telemetry/structured-recipe.json --csv > imported.csv
/tmp/moonrobo-jsonl-build/native/debug/build/cmd/telemetry_csv/telemetry_csv.exe imported.csv > explored.json
/tmp/moonrobo-jsonl-build/native/debug/build/cmd/telemetry_plot/telemetry_plot.exe imported.csv --channel motor.current.a --unit A --max-gap-ms 500 --svg > current.svg
```

The four synthetic records become columns `motor.current.a,pose.y.m,pose.x.m`,
in recipe order. Their original physical line numbers are 1, 3, 4 and 5. The
first exact recorded timestamp is 9007199254740993 ms, beyond JavaScript's exact
Number range. The plot shows a 1600 ms disconnected gap using the explicitly
chosen 500 ms cutoff. Keep the input, recipe and JSON report beside the CSV.

## Recipe and input contract

```json
{
  "timestamp_path": ["clock", "recorded_ms"],
  "channels": [
    {"path": ["motor", "current"], "target": "motor.current.a", "unit": "A"},
    {"path": ["pose", "y"], "target": "pose.y.m", "unit": "m"}
  ]
}
```

- The recipe requires exactly `timestamp_path` and `channels`. Each channel
  requires exactly `path`, `target` and `unit`; unknown fields and wrong types
  are errors. There must be at least one channel.
- Paths are nonempty arrays of literal object-key strings. `["pose","x"]`
  selects a nested key, whereas `["pose.x"]` selects one literal key containing
  a dot. Slashes, tildes, Unicode and empty keys work literally. Arrays cannot
  be traversed; there are no array indexes, JSON Pointer escapes, wildcards,
  flattened-name guesses or implicit aliases.
- The timestamp value must be a JSON string containing only ASCII decimal
  digits and represent 0 through 9223372036854775807 milliseconds. Leading
  zeroes are accepted and canonicalized. Numeric JSON timestamps are rejected,
  even small ones, so the parser cannot silently round a large timestamp.
  Export the timestamp as a decimal string at the recorder. Converting an
  already-rounded JSON number to text cannot recover its lost precision.
- Timestamp order must already be strictly increasing. Duplicates and reversed
  rows fail; nothing is sorted, deduplicated, shifted or converted from seconds.
  The supplied millisecond timebase is trusted, not discovered or verified.
- Every selected channel value must be a finite JSON number. Strings, nulls,
  booleans, objects and arrays are errors. There is no zero filling, coercion,
  interpolation or unit conversion. Values use Double arithmetic; very small
  JSON numbers can underflow and large integers can lose numeric precision.
- Output names must be unique, nonblank, different from `timestamp_ms`, have
  no surrounding whitespace, comma, double quote, CR or LF. Selection order is
  recipe order; unselected fields are not exported. The same source path may
  intentionally be selected under different target names.
- Unit labels must be nonblank strings and are retained exactly. They describe
  the operator's selection; they do not prove the values have those units.
  The CSV does not carry unit metadata. Supply labels explicitly to the plotter
  or use the existing normalization recipe for intentional conversions.
- Each nonblank physical input line must be one complete JSON object. CRLF,
  blank lines and no final newline are accepted. Multiline JSON objects,
  comments, log prefixes and mixed record types are unsupported. A UTF-8 BOM
  is not stripped. Missing selected fields fail with the physical line number.
- Duplicate object keys are rejected throughout input and recipe, including
  nested unselected fields and escaped spellings of the same key. All nonblank
  lines must be valid JSON; unselected fields may otherwise have any JSON type.
  No late error produces a partial import or silently skipped row.

## Reports, errors and library use

```text
telemetry_import_jsonl INPUT.jsonl RECIPE.json [--csv]
```

Default JSON contains input/recipe path labels and an `import` object with
format `moonrobo.telemetry-jsonl.v1`, timebase, the explicit recipe,
`source_line_numbers` aligned with output samples, and the numeric `recording`.
JSON Int64 timestamps are strings. Paths and line numbers are traceability aids,
not content hashes or immutable identities. Retain the exact source and recipe;
the report does not duplicate unselected source fields or lexical formatting.

`--csv` emits only the reusable numeric recording. It drops source-line and unit
metadata, so retain the report too. The CSV can feed the existing explorer,
plotter, normalizer, merger, comparator, threshold extractor and XY trajectory
tool under those tools' own contracts. Importing does not establish physical
comparability between runs, robot identity or calibration compatibility.

Success exits 0. Missing files, malformed recipes/records, missing/type-invalid
fields, invalid timestamps and unsupported CLI arguments emit one JSON `error`
on stdout and exit 2, including with `--csv`. Check the exit status before
consuming a redirected file. The command never overwrites an input on its own;
as with any shell redirection, choose a different output path.

The reusable `src/telemetry_csv.parse_jsonl_recipe`, `import_jsonl` and
`TelemetryJsonlImport::to_csv` APIs perform no I/O. Direct typed recipes are
validated too. Use unmodified successful import results for export; constructing
or mutating public records does not create trustworthy lineage. Both files and
the output are held in memory. This is a bounded offline adapter for object-line
recorders, not a ROS bag/MCAP reader, streaming ingest or MoonData retention step.
