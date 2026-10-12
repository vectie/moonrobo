# Inspect recorded ROS 2 IMU attitude

`telemetry_import_imu` reads JSON Lines exports of ROS 2 `sensor_msgs/msg/Imu`,
converts selected quaternion orientations to roll/pitch/yaw, and exports numeric
CSV for MoonRobo's existing explorer, unwrapping and plotting tools. It also
imports normalized quaternion components, angular velocity and acceleration.
A synthetic heading crossing ±π demonstrates the complete inspection workflow.

No ROS installation, live topic, device, bridge or provider is used. This is
already-exported JSON message intake, not rosbag/MCAP, YAML or topic envelopes.
It does not estimate pose from acceleration, remove gravity, fuse sensors,
transform frames, establish calibration or prove physical completion.

## Try the complete offline workflow

Use the retained pinned environment and shared serial native lock described in
the accompanying BUILD.md. Every Moon command requires an absolute external
target. Build once, then use the binaries for uncontaminated data stdout:

```sh
moon --target-dir /tmp/moonrobo-imu-build build cmd/telemetry_import_imu cmd/telemetry_unwrap cmd/telemetry_plot cmd/telemetry_csv --target native --frozen --strip -j 1
/tmp/moonrobo-imu-build/native/debug/build/cmd/telemetry_import_imu/telemetry_import_imu.exe examples/telemetry/ros2-imu.jsonl examples/telemetry/ros2-imu-recipe.json > imu.json
/tmp/moonrobo-imu-build/native/debug/build/cmd/telemetry_import_imu/telemetry_import_imu.exe examples/telemetry/ros2-imu.jsonl examples/telemetry/ros2-imu-recipe.json --csv > imu.csv
/tmp/moonrobo-imu-build/native/debug/build/cmd/telemetry_unwrap/telemetry_unwrap.exe imu.csv examples/telemetry/ros2-imu-yaw-unwrap.json --max-gap-ms 500 > yaw.json
/tmp/moonrobo-imu-build/native/debug/build/cmd/telemetry_unwrap/telemetry_unwrap.exe imu.csv examples/telemetry/ros2-imu-yaw-unwrap.json --max-gap-ms 500 --csv > yaw.csv
/tmp/moonrobo-imu-build/native/debug/build/cmd/telemetry_plot/telemetry_plot.exe yaw.csv --channel imu.yaw.continuous.rad --unit rad --max-gap-ms 500 --svg > yaw.svg
```

Run from the source directory and check each exit status before consuming an
output. Redirect only to distinct files, never over an input or recipe. The
executable paths depend on the toolchain layout. `--help` displays usage. Unknown
options and input errors exit 2 with a single JSON error object, including when
CSV was requested; a late error produces no partial recording. Successful calls
exit 0. The API and CLI hold the entire recording in memory.

The six synthetic observations have headings 170°, 175°, -179°, -175°, -170°,
-165°. With the explicit 2π unwrap period and 500 ms gap cutoff, the first four
become 170°, 175°, 181°, 185°. The 2000 ms outage starts a new segment at -170°,
then -165°: no turn count is carried through missing observations. Values in the
files remain radians. The example deliberately contains scaled and sign-flipped
quaternions and 34567 discarded nanoseconds per stamp. The angular velocity is
independently synthetic, not a claim of consistency with the orientation trace.

## Explicit recipe and output order

```json
{
  "timestamp_policy": "floor-milliseconds",
  "quaternion_policy": "normalize",
  "frame_id": "imu_link",
  "groups": ["attitude", "angular_velocity", "linear_acceleration"]
}
```

All four fields are required. Unknown or duplicate keys, unknown groups, empty
groups and repeated groups are errors. `frame_id` must be nonblank and match
every message literally. Split different frames into separate recordings first;
matching names cannot prove that a publisher kept a stable coordinate reference.

Groups preserve recipe order and emit these fixed channels:

- `attitude`: `imu.roll.rad`, `imu.pitch.rad`, `imu.yaw.rad`
- `quaternion`: `imu.q.x`, `imu.q.y`, `imu.q.z`, `imu.q.w`
- `angular_velocity`: `imu.gyro.x.rad_s`, `imu.gyro.y.rad_s`, `imu.gyro.z.rad_s`
- `linear_acceleration`: `imu.accel.x.m_s2`, `imu.accel.y.m_s2`, `imu.accel.z.m_s2`

Both orientation groups may be selected. SI vector units are the message's
contract, not measured or converted by the importer. Acceleration can include
gravity according to the publisher. No geographic heading, ENU/NED mapping,
robot-axis convention or orientation reference frame is inferred.

## Orientation interpretation

ROS quaternion fields are read by name in x,y,z,w order. `require-unit` accepts
norms within 1e-6 of one; `normalize` explicitly accepts any nonzero finite
quaternion whose norm remains representable. Both produce a unit quaternion
before deriving or exporting orientation. The original components and norm are
retained. A scaled-norm algorithm avoids squaring overflow/underflow. Zero or
nonrepresentable norms fail when orientation is selected. A quaternion and its
negation produce equivalent attitude; quaternion signs are otherwise preserved,
with no continuity correction across rows.

Attitude uses radians and the explicitly defined matrix convention
R = Rz(yaw) Ry(pitch) Rx(roll), equivalently fixed-axis XYZ rotations. Roll/yaw
use atan2 principal angles; pitch uses asin in [-π/2, π/2]. Near Euler gimbal
lock, abs(2(wy-zx)) >= 1 - 1e-12, attitude selection fails because roll and yaw
cannot be uniquely separated. Retry with `quaternion` instead of `attitude` to
inspect that recording without inventing a heading. Quaternions are never
integrated or interpolated. Unwrapping Euler angles cannot resolve singularities
or recover turns hidden between samples; read the existing unwrap assumptions.

## Message, clock and covariance contract

Every nonblank line must contain one complete message object with header/stamp,
frame_id, four named orientation components, three angular_velocity components,
three linear_acceleration components, and all three length-nine covariance
arrays. All components/covariances must be finite JSON numbers even when their
group is unselected. Extra fields are ignored; duplicate keys anywhere fail.
Blank lines, CRLF and missing final newline are accepted. Multiline JSON fails.

The [official Imu message](https://raw.githubusercontent.com/ros2/common_interfaces/rolling/sensor_msgs/msg/Imu.msg)
defines SI angular velocity/acceleration, an unavailable measurement marker at
covariance[0] = -1, and unknown covariance as nine zeros. Selecting an unavailable
group fails, so its placeholder values never become observations. Unselected
unavailable groups are retained as such. Covariances are reported as
`unavailable`, `unknown` or `provided-unvalidated`; other entries are retained
literally, including negative off-diagonals. Symmetry, positive semidefiniteness
and physical uncertainty are not verified. Covariances are not transformed,
renormalized or propagated to Euler angles; never treat them as derived attitude
uncertainty.

ROS sec must be an integer 0..2147483647 and nanosec 0..999999999. Negative ROS
time is explicitly unsupported by the existing nonnegative pipeline.
`exact-milliseconds` rejects sub-millisecond parts; `floor-milliseconds` uses
sec*1000 + nanosec/1000000 and retains the discarded remainder. Timestamps must
strictly increase after conversion; collisions and reversals fail rather than
merge/drop samples. No clock domain, offset or synchronization is inferred.
JSON timestamps are Int64 decimal strings; CSV preserves exact decimal integers.

## API and retained traceability

`parse_imu_recipe(text)` and `import_imu_jsonl(text, recipe)` return Result values.
`ImuImport::to_csv()` emits existing reusable telemetry CSV. Default JSON format
is `moonrobo.ros2-imu-import.v1`, with recipe, convention, recording and one source
entry per sample: physical line number, original stamp, discarded nanoseconds,
frame, raw quaternion, optional original norm and original covariance metadata.
The norm is absent when neither orientation group is selected. JSON includes no
authenticated identity or raw-vector content hash.

Keep raw JSONL, recipe and JSON report alongside CSV: CSV alone lacks precision,
frame, covariance and processing choices. These are inspection metadata, not
immutable MoonData storage or command/robot/session identity. No PRD hardware or
cumulative qualification claim follows from importing a file. Export methods
expect an unmodified successful result; mutable public records can invalidate
that contract.
