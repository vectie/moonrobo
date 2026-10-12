# Import recorded ROS 2 JointState telemetry

`telemetry_import_joint_state` converts JSON Lines representations of ROS 2
`sensor_msgs/msg/JointState` messages into MoonRobo's reusable numeric CSV.
Select joint names and position, velocity or effort fields explicitly. Every
message resolves its name array again, so a recorder's changing joint order does
not swap measurements. Feed the CSV into the existing explorer, plotter,
comparator, normalizer or bucket workflow without a ROS installation or device.

This supports already exported message objects, not binary rosbag/MCAP files,
`ros2 topic echo` YAML, topic-envelope JSON, ROS 1 stamps or a live subscriber.
A separate tool must export those formats first. No bridge is opened, source is
modified, or MoonData capture is created. Import is not evidence of readiness,
calibration, robot identity, command completion or physical success.

## Run the synthetic recording

Build into an absolute external target with the project's frozen dependencies:

```sh
moon build cmd/telemetry_import_joint_state cmd/telemetry_csv cmd/telemetry_plot --target native --frozen --strip -j 1 --target-dir /tmp/moonrobo-joint-state-build
B=/tmp/moonrobo-joint-state-build/native/debug/build/cmd
"$B/telemetry_import_joint_state/telemetry_import_joint_state.exe" examples/telemetry/ros2-joint-state.jsonl examples/telemetry/ros2-joint-state-recipe.json > joint-report.json
"$B/telemetry_import_joint_state/telemetry_import_joint_state.exe" examples/telemetry/ros2-joint-state.jsonl examples/telemetry/ros2-joint-state-recipe.json --csv > joints.csv
"$B/telemetry_csv/telemetry_csv.exe" joints.csv > explored.json
"$B/telemetry_plot/telemetry_plot.exe" joints.csv --channel shoulder.rad --unit rad --max-gap-ms 500 --svg > shoulder.svg
```

Use the executable locations reported by your Moon version. Build once, then run
the binaries for clean stdout. Check the exit status before using output and
redirect to a path distinct from both input files. `--help` prints usage. Input
or option errors exit 2 with one JSON `error` object even with `--csv`; successful
imports exit 0. No partial recording is emitted after a late error.

The synthetic fixture has four messages on physical lines 1, 3, 5 and 7. Its
selected rows are:

```csv
timestamp_ms,shoulder.rad,elbow.rad_s,shoulder.nm
1700000000000,0.1,1,2
1700000000100,0.2,1.5,2.5
1700000000200,0.3,2,3
1700000001700,0.5,0,3.5
```

Numeric spelling can differ. The output plot has two segments separated by a
1500 ms recorded gap; no intermediate movement is reconstructed.

## Explicit recipe

```json
{
  "timestamp_policy": "floor-milliseconds",
  "channels": [
    {"joint":"shoulder","field":"position","target":"shoulder.rad","unit":"rad"},
    {"joint":"elbow","field":"velocity","target":"elbow.rad_s","unit":"rad/s"}
  ]
}
```

Exactly these recipe keys and channel keys are required. Unknown, duplicate,
missing or mistyped fields fail. At least one channel is required. Joint names
match literally, including Unicode and punctuation; no aliases or suffixes are
inferred. Only `position`, `velocity` and `effort` are supported. Each joint/field
pair and each target may be selected once. Targets must be nonblank, unique,
unquoted CSV labels without surrounding whitespace, commas, quotes, CR or LF;
`timestamp_ms` is reserved. Unit labels must be nonblank and are retained as
metadata, never used to convert or infer revolute/prismatic units.

The timestamp policy is mandatory:

- `exact-milliseconds`: reject any stamp with a nonzero sub-millisecond part.
- `floor-milliseconds`: explicitly compute `sec * 1000 + nanosec / 1000000`
  using integer division. Every source record retains the original second and
  nanosecond values and the discarded remainder (0–999999 nanoseconds).

The result must be strictly increasing in milliseconds under either policy.
Two messages that round down to one millisecond fail; no sample is silently
merged or discarded. Clock reversal/reset also fails. Choose an appropriate
recording or another higher-resolution analysis tool for these inputs; this
importer does not resample them. No time zone, wall/simulation clock domain,
clock synchronization or rebasing is inferred from the ROS stamp.

## Message contract

Each nonblank line must be one JSON object with:

- `header.stamp.sec`: numeric integer 0 through 2147483647.
- `header.stamp.nanosec`: numeric integer 0 through 999999999.
- `header.frame_id`: string, retained separately for every record.
- `name`: nonempty array of unique, nonblank strings.
- `position`, `velocity`, `effort`: all three arrays must exist. Each is empty
  when unavailable or has exactly the name array's length. Every numeric value
  in all three arrays must be finite, including unselected values.

A selected joint must exist in every message and its selected field must be
nonempty. Missing data is never replaced by zero, copied forward or dropped.
Additional object fields are ignored, but duplicate JSON object keys are
rejected anywhere in each line. Blank lines, CRLF and no final newline work;
multiline pretty JSON does not. Empty recordings fail. Negative ROS seconds are
valid in ROS but unsupported by MoonRobo's nonnegative recorded-time pipeline;
they are explicitly rejected here. Numeric spellings use the JSON parser's
Double representation and must resolve to in-range whole numbers. These stamp
ranges are exactly representable; sensor values retain normal Double rounding.

This follows the official ROS 2
[JointState field contract](https://raw.githubusercontent.com/ros2/common_interfaces/rolling/sensor_msgs/msg/JointState.msg)
and [Time component ranges](https://raw.githubusercontent.com/ros2/rcl_interfaces/rolling/builtin_interfaces/msg/Time.msg),
with the nonnegative-time and millisecond limits above. The importer cannot
verify that a JSON export faithfully represents a ROS publisher or robot.

## Lineage and library API

Default JSON reports format `moonrobo.ros2-joint-state-import.v1`, the explicit
recipe, output recording, and one aligned `sources` entry per sample. Each entry
contains one-based physical line number, original `sec`/`nanosec`, discarded
nanoseconds, `frame_id`, and the selected zero-based joint array indices in
recipe order. Frames can change: the report preserves them without asserting
frame equivalence or transforming coordinates. Millisecond timestamps are
Int64 decimal strings in JSON and exact decimal text in CSV.

CSV has only timestamps, output channel names and numeric measurements. Retain
the raw JSONL, recipe and JSON report together to preserve source mapping,
precision choices, unit labels and frames. These are traceability metadata,
not content hashes, authenticated identity or immutable MoonData lineage.

Pure API: `parse_joint_state_recipe(text)` and
`import_joint_state_jsonl(text, recipe)` return `Result[..., String]`;
`JointStateImport::to_csv()` returns reusable CSV. Input and output are held in
memory, not streamed. Public result arrays are mutable; use unmodified successful
results for exports. No robot, SDK, provider or physical system was exercised.
