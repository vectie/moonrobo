# Inspect recorded planar laser scans offline

Use `telemetry_scan` to inspect exported ROS 2 `sensor_msgs/LaserScan` messages,
choose an observed scan, and save a sensor-frame point table or standalone SVG.
This is useful for reviewing a recording with missing or out-of-range returns
without flattening variable-length beams into unrelated scalar channels.

The command reads files only. It does not connect to ROS, decode rosbag/CDR,
operate a device, transform frames, correct motion, infer occupied/free space,
or establish hardware readiness or command completion.

## Run the example

Build `cmd/telemetry_scan` with the repository's pinned native setup and an
absolute target directory outside the source module. In the retained R395
workspace, use the `run-smoke.sh` and `BUILD.md` beside the source; they also
isolate HOME/XDG, take the shared native lock and check storage budgets.

The executable is `TARGET/native/debug/build/cmd/telemetry_scan/telemetry_scan.exe`.
The command accepts these arguments:

```text
telemetry_scan INPUT.jsonl FRAME_ID SCAN_INDEX [--csv|--svg]
```

`SCAN_INDEX` is zero-based and counts nonblank JSONL rows, not physical lines.
The requested frame must match every input scan literally and contain no control
characters or XML-invalid noncharacters. Every row is
validated before selected output appears. Success is exit 0; usage, read,
selection and validation errors are JSON errors with exit 2.

With `examples/telemetry/ros2-laser-scan.jsonl`, select frame `laser_front`:

- Index `0`: seventeen beams, ten usable returns, exact stamp sec=1700000000,
  nanosec=123456789. Five central beams lie on the synthetic x=2 m wall.
- Index `1`: seventeen missing returns. The blank physical line is retained in
  provenance: the second scan is source line 3. Its SVG says no usable returns.

Default JSON includes the selected scan, scan index/count, input path,
processing format, convention, all metadata and every beam. `--csv` exports a
long-form table with every original beam, including unusable readings and blank
Cartesian cells. `--svg` plots only usable points. Points are not joined into
surfaces; the orange cross is the sensor origin. The X axis points right, Y up,
with equal scales and the chart half-width in metres shown below the plot.

## Input and geometry contract

One plain message object per nonblank UTF-8 JSONL line is supported. The required
fields follow the [official ROS 2 LaserScan message definition](https://raw.githubusercontent.com/ros2/common_interfaces/rolling/sensor_msgs/msg/LaserScan.msg):
`header.stamp.sec`, `header.stamp.nanosec`, `header.frame_id`, `angle_min`,
`angle_max`, `angle_increment`, `time_increment`, `scan_time`, `range_min`,
`range_max`, `ranges`, and `intensities`. Additional message fields are ignored;
duplicate keys at any depth fail. This tool does not unpack a topic/message
wrapper; export the message object first.

- This importer supports nonnegative integer sec up to 2147483647 and nanosec
  from 0 through 999999999. Scan header stamps must strictly increase, including
  at sub-millisecond resolution. Neither value is converted into a floating
  absolute timestamp. A header marks the first ray, not the scan midpoint.
- Angles are radians about sensor +Z, zero forward along +X. For original beam
  index i, angle = angle_min + i × angle_increment; x = range × cos(angle) and
  y = range × sin(angle), in metres. Negative increments retain clockwise order.
- `angle_increment` must be finite and nonzero. `ranges` must be nonempty;
  the derived last angle must match `angle_max` within 1e-5 times the largest of
  1 and the absolute first/declared-last/derived-last angles, accommodating
  float32 source rounding. No extra endpoints are created or beams reversed.
- `time_increment` and `scan_time` must be finite and nonnegative. Each beam
  retains i × time_increment seconds after the exact header. Zero increment
  remains zero; this is not evidence that the rays were simultaneous. Reported
  scan_time is retained but is not used to synthesize stamps or verify cadence.
- `0 <= range_min < range_max`, both finite. Numeric returns at either limit are
  usable. Below/above-limit returns retain their numeric value and explicit
  status but have null Cartesian coordinates.
- JSON-friendly missing/nonfinite values are null or the exact strings `NaN`,
  `Infinity`, `+Infinity`, `-Infinity`. These produce missing, nan,
  positive-infinity or negative-infinity statuses. They never produce zero
  ranges or free-space claims. Bare NaN/Infinity are invalid JSON; lowercase or
  other spellings fail rather than being silently normalized. If an exporter
  converted several nonfinite categories to null, their original distinction
  is unrecoverable and remains missing.
- Intensities are empty or match the range count. Finite numeric values retain
  device-specific units; null means unavailable. Nonfinite/string intensities
  fail. Intensities do not change range usability.

The JSON and CSV `raw_range` retain the parsed source value/category, not the
original numeric lexical spelling. The CSV encodes this cell as JSON text and
uses ordinary CSV escaping; quoted frame names and commas are preserved. This
is a point table, not the scalar `timestamp_ms` format accepted by the other
telemetry commands.

## Keep the evidence and its limits

Retain raw JSONL, selected JSON report and output together. The format version,
source line, exact stamp, beam index, range, angle, timing offset and exclusions
make this local derivation reviewable. Keep a hash of raw input for later
identity checks. Changing an export creates another local derived artifact;
the tool never overwrites source recordings.

A literal frame label is neither an authenticated robot/session identity nor a
transform to a common map. The scatter assumes each beam's recorded sensor basis
without motion compensation; a moving scanner can distort the shape. Missing
returns do not demonstrate empty space, and no return proves an obstacle or a
safe route. No calibration uncertainty or covariance is inferred.

This slice supports PRD MR-W04 observation inspection and B06/B07 traceability
needs locally. Durable MoonData lineage, command/session binding, cockpit UI,
hardware qualification and physical outcome acceptance remain outside this
workflow. Reports can contain a private input path/frame name; review them
before sharing externally.
