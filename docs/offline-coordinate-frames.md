# Express a recorded route in a chosen planar frame

An integration engineer may have a local odometry route and a separately known
relationship between that frame and a survey map. `telemetry_frame` applies that
one fixed, explicit relationship to a numeric recording. It appends two new
position columns, so the original coordinates and other sensor channels remain
available alongside the derived route.

This is an offline editing/output workflow. The source CSV carries no frame
metadata: selecting source channels and naming their frame and units is the
user's assertion. The tool does not discover or verify a transform, calibrate a
robot, localize it, or establish a physical outcome.

## Invocation

The native executable accepts:

```text
telemetry_frame INPUT.csv RECIPE.json [--csv]
```

Without `--csv`, stdout is a JSON report containing `input_file`, `recipe_file`
and `transform`. The transform includes its version, convention, complete
recipe, numeric source recording and output recording. With `--csv`, stdout is
the reusable numeric recording. Errors are a JSON object with an `error` field
and process exit status 2, including when CSV output was selected. Help exits 0.
The command reads both files and never writes or overwrites either input.
Redirect output to a new file and check the exit status before consuming it.

Use `examples/telemetry/frame-route.csv` and `frame-recipe.json` as a complete
starting example. The batch GUIDE provides a pinned, externally targeted build
and wrappers. There is no ROS installation, hardware, provider or account setup.

## Recipe and direction

Exactly these ten fields are required, with no duplicate or unknown keys:

```json
{
  "source_x": "x",
  "source_y": "y",
  "target_x": "map.x",
  "target_y": "map.y",
  "source_frame": "odom",
  "target_frame": "survey-map",
  "units": "m",
  "yaw_degrees": 90,
  "translation_x": 10,
  "translation_y": -2
}
```

The convention is:

```text
target_x = cos(yaw) * source_x - sin(yaw) * source_y + translation_x
target_y = sin(yaw) * source_x + cos(yaw) * source_y + translation_y
```

Positive yaw rotates counterclockwise from +X toward +Y. It is expressed in
degrees within [-180, 180]. Translation is the source origin expressed in target
coordinates, applied after rotation. Input X/Y and both translation components
must already share the declared units. Unit labels are descriptive, with no
automatic conversion. Convert units explicitly before this step when needed.

The example maps (0,0) to (10,-2), (3,4) to (6,1), (100,100) to (-90,98), and
(100,103) to (-93,98). Exact 0, ±90 and ±180 degree recipes use exact cardinal
rotation coefficients; other angles use double-precision trigonometry.

Do not invert a transform by merely negating translation. Its inverse has angle
`-yaw` and translation `-R(-yaw) * translation`, expressed in the new target
frame. Use a new recipe and new output channel names for another conversion.

## Source retention and downstream exploration

Every input sample maps to exactly one output sample, in the same order and at
the exact recorded integer millisecond timestamp. All original channels remain
in their original order; target X then target Y are appended. Target names must
be distinct and absent from every source column. Source and target frame labels
must be nonblank and different. Each pair of selected source axes must be distinct.

The JSON `source.samples[i]` and `recording.samples[i]` are the numeric source and
derived row pair. Retain the original input file too: this is numeric lineage,
not preservation of CSV whitespace or number spellings. CSV alone cannot carry
the frame labels, units or recipe. The report is local provenance, not an
authenticated robot/session/MoonData capture receipt.

Feed the emitted CSV to `telemetry_path OUTPUT.csv map.x map.y --units m`.
The example keeps its four-second recording outage: the existing default
1000-ms path-gap limit reports two segments, 8 m observed distance, 2000 ms
connected duration and 5 m/s peak interval speed. Conversion neither adds
samples nor fills outages. A rigid transform preserves distances apart from
floating-point rounding.

## Boundaries

- Position coordinates only. Original velocity, heading, Z and covariance
  columns pass through unchanged and remain in their original frames. Do not
  interpret them as converted because target position columns were appended.
- One fixed 2D transform over the entire recording; no dynamic transform tree,
  3D rotation, time alignment, interpolation or motion compensation.
- All input rows and arithmetic are checked before output. Invalid numeric
  cells, repeated/out-of-order timestamps and non-finite transformed values
  reject the complete operation. Intermediate overflow is rejected even if an
  ideal arbitrary-precision calculation could cancel it later.
- Existing unquoted numeric CSV rules apply. All files and both numeric
  recordings fit in memory. Large translations can lose small increments due
  to ordinary floating-point precision; keep suitable units/origins and inspect
  the result before making quantitative claims.
- This supplies the PRD MR-W04/B06/B07 offline observation/derived-lineage slice.
  It grants no device authority and is not physical or cumulative qualification.
