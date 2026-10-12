# Import a recorded ROS 2 odometry path

`telemetry_import_odometry` imports exported `nav_msgs/Odometry` JSONL and emits
MoonRobo numeric telemetry CSV. An integration engineer can inspect the recorded
route, compare pose channels or plot body-frame velocity without manually
flattening nested messages or silently mixing their coordinate frames.

The existing generic JSONL, JointState, IMU and LaserScan tools do not provide
this format's two-frame contract and 6×6 covariance metadata. This is an offline
observation/lineage slice of MR-W04 and B06/B07. It does not bind command/session
identity to MoonData or qualify a device, bridge, calibration or physical result.

## Command and recipe

Build `cmd/telemetry_import_odometry` and `cmd/telemetry_path` in the selected,
pinned environment. Use an absolute target outside the source checkout. The
round's `BUILD.md`, `phase.sh` and `run-smoke.sh` give the bounded frozen commands.

```text
telemetry_import_odometry INPUT.jsonl RECIPE.json [--csv]
```

The default JSON report includes input/recipe filenames, versioned import
format, recording, per-channel frame labels and source metadata. `--csv` prints
numeric CSV accepted by existing `telemetry_path`, `telemetry_plot`,
`telemetry_compare` and other scalar tools. Errors print a JSON error and exit 2;
check status before treating redirected stdout as a valid CSV. No input file is
changed; the entire recording is validated before output.

The example recipe is `examples/telemetry/ros2-odometry-recipe.json`:

```json
{
  "timestamp_policy": "exact-milliseconds",
  "quaternion_policy": "require-unit",
  "frame_id": "odom",
  "child_frame_id": "base_link",
  "groups": ["position", "attitude", "linear_velocity", "angular_velocity"]
}
```

These five keys are required, with no extras or duplicates. Groups are ordered,
nonempty and unique. Frame names are matched literally for every message and
must be nonblank. They are labels, not authenticated robot/session identities.

Available groups and generated channels:

- `position`: `odom.pose.x.m`, `odom.pose.y.m`, `odom.pose.z.m`
- `quaternion`: `odom.pose.q.x`, `.y`, `.z`, `.w`
- `attitude`: `odom.pose.roll.rad`, `.pitch.rad`, `.yaw.rad`
- `linear_velocity`: `odom.twist.linear.x.m_s`, `.y.m_s`, `.z.m_s`
- `angular_velocity`: `odom.twist.angular.x.rad_s`, `.y.rad_s`, `.z.rad_s`

The `odom` channel prefix identifies this importer; it does not claim that the
actual frame is named `odom`. JSON `channel_frames` records the literal recipe
frame for each channel. CSV cannot carry that metadata; keep its JSON report and
raw recording together. Units follow the supplied ROS data; no unit conversion
or independent calibration verification occurs.

## Input contract and interpretation

One direct Odometry message object per nonblank line, with no topic envelope,
array wrapper, YAML, rosbag or CDR decoding. LF and CRLF work; physical source
line numbers include blank lines. Duplicate keys anywhere in a row are errors.
Additional message fields are accepted but are not copied into the report.
Input and output are in-memory, with no streaming/downsampling guarantee.

Required nesting is `header.stamp.{sec,nanosec}`, `header.frame_id`,
`child_frame_id`, `pose.pose.{position,orientation}`, `pose.covariance`,
`twist.twist.{linear,angular}` and `twist.covariance`. Position/linear/angular
require finite numeric x/y/z; orientation also requires w. Both covariances must
contain exactly 36 finite numbers. All these fields are checked even when their
groups are unselected. Malformed later rows reject the whole recording.

Pose channels use `header.frame_id`. Linear and angular twist channels stay in
`child_frame_id`, even when the robot has turned. The importer never rotates,
integrates or reconciles twist with position. This matches the upstream
[Odometry message contract](https://github.com/ros2/common_interfaces/blob/rolling/nav_msgs/msg/Odometry.msg).

Each source record preserves the full raw pose/twist covariance arrays in their
original row-major order. Their six coordinates are translation X/Y/Z followed
by fixed-axis rotations X/Y/Z, as specified by
[PoseWithCovariance](https://github.com/ros2/common_interfaces/blob/rolling/geometry_msgs/msg/PoseWithCovariance.msg)
and [TwistWithCovariance](https://github.com/ros2/common_interfaces/blob/rolling/geometry_msgs/msg/TwistWithCovariance.msg).
Covariance symmetry, positivity, statistical validity and sensor conventions
are not checked. Zero arrays are not reclassified as certain or unknown; -1 is
not borrowed as an IMU unavailable sentinel. They are labelled raw/unvalidated,
never converted into confidence bands or transformed into derived Euler errors.

## Time and orientation choices

- `exact-milliseconds` refuses nanoseconds not divisible by 1,000,000.
- `floor-milliseconds` explicitly discards sub-millisecond remainders. Exact
  original sec/nanosec and `discarded_nanoseconds` remain in every JSON source.
- sec must be an integer in 0…2,147,483,647 and nanosec in 0…999,999,999. Negative
  ROS times are outside this numeric-telemetry subset. Converted milliseconds
  must strictly increase. Duplicates, reversals and flooring collisions fail;
  no rows are silently sorted, merged or dropped. ROS clock domain is unknown.
- `require-unit` requires quaternion norm within 1e-6 of 1; accepted quaternions
  are normalized before quaternion/attitude output. `normalize` explicitly
  permits another nonzero finite norm, with scale-stable normalization. Raw
  quaternion and original norm remain in the source metadata. Invalid or
  unreportable norms fail even for a position-only selection.
- Attitude uses fixed-axis XYZ radians with R = Rz(yaw) Ry(pitch) Rx(roll).
  Euler singularities within 1e-12 of absolute sine(pitch)=1 fail only when
  attitude is selected; select quaternion or position instead. No continuous
  yaw unwrapping is inferred; use the existing explicit unwrap tool if needed.

## End-to-end example

The supplied synthetic recording has five positions at seconds 10, 11, 12, 15
and 16. Blank lines make their physical source lines 1, 3, 5, 7 and 9. XY points
are (0,0), (3,4), (3,4), (100,100), (100,103). The quarter-turn orientation does
not rotate the recorded body-frame linear velocity of (1,0,0).

After exporting CSV, invoke the existing command:

```text
telemetry_path imported.csv odom.pose.x.m odom.pose.y.m --units m
```

Its default 1000 ms gap cutoff yields two segments, one gap, 8 m of observed
chord distance over 3000 ms and a peak interval speed of 5 m/s. The unobserved
jump across the three-second gap contributes no distance. A stationary interval
remains explicit. Add `--svg` for the existing spatial view or `--csv` for its
interval table. Position-derived speed and supplied child-frame velocity are
separate estimates and are not asserted to agree.

Retain raw input and JSON metadata alongside derived CSV/route outputs. Review
filenames and frame labels before sharing. No hardware, middleware, provider,
remote access, physical control or proof-of-completion claim is involved.
