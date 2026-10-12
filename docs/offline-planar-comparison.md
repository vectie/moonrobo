# Compare two declared-comparable XY routes

`telemetry_planar BASELINE.csv CANDIDATE.csv RECIPE.json` compares two planar
recordings at baseline observation times. It extends the offline telemetry
inspection and derived-lineage work associated with MR-W04/B06/B07. It does not
establish robot/session identity, hardware readiness or a physical outcome.

Independent `telemetry_compare` channel deltas do not express coupled spatial
separation. `telemetry_path` plots one recording. This command produces paired
XY positions, Euclidean separation, aggregate separation and an overlaid route
without changing either source. Existing bounded comparison machinery supplies
alignment and interpolation; no new dependency or alternate parser is used.

## Explicit recipe

See `examples/telemetry/planar-recipe.json`. All nine fields are required:

- `baseline_x`, `baseline_y`, `candidate_x`, `candidate_y`: distinct X and Y
  position columns in each recording. Names can differ between recordings.
- `baseline_frame`, `candidate_frame`: identical, nonblank printable frame assertions.
- `baseline_units`, `candidate_units`: identical, nonblank printable units assertions,
  applying to both axes of each recording.
- `alignment`: `first-sample` or `absolute-timestamp`, explicitly chosen.

Equal labels are declarations, not verification of physical compatibility.
There is no automatic axis discovery, unit scaling, clock correction or frame
transform. Use the separate frame transform/normalization workflows first when
needed, retaining their recipes and original sources. Duplicate/unknown keys,
missing fields, invalid types, identical axis names and mismatched declarations
are errors. The ordinary telemetry parser validates all rows and all numeric
columns, even outside the selected window.

## Alignment and sampling

`first-sample` subtracts each full recording's first timestamp before selecting
an inclusive `--window START_MS END_MS`. It is useful for comparable starts of
separate runs, but does not detect whether those starts describe the same event.
`absolute-timestamp` uses the clocks as recorded, with zero origins; the caller
must already know those clocks are comparable. Default window is all times.

Every selected baseline observation yields one row. A candidate observation at
that aligned instant is `exact`. Otherwise, a candidate bracket no longer than
`--max-gap-ms MS` produces one linearly interpolated XY pair using the same
fraction for both coordinates. No extrapolation is allowed. Default cutoff zero
means exact matches only. Candidate samples not at baseline times are source
lineage, not additional comparison rows. This is time-aligned separation, not
nearest-route distance, dynamic time warping or a geometric Hausdorff metric.

`candidate-gap-exceeds-limit` and `outside-candidate-range` rows retain baseline
coordinates and available candidate bracket indices/timestamps, with null
candidate/separation. Zero separation means an actual matching pair, never a
missing observation. An empty baseline window is an error; a window with only
unmatched baseline observations is valid and has no summary.

## Separation and summaries

Separation is sqrt((candidate.x - baseline.x)^2 +
(candidate.y - baseline.y)^2), computed with a scaled norm to avoid squaring
large values. Nonfinite differences or norms fail explicitly. Mean, root mean
square and maximum separation weight each paired baseline observation equally,
including interpolated ones. They are not time-weighted. The earliest maximum
wins ties. Unmatched observations contribute nothing to those statistics.
Summary and all paired coordinates use the explicitly declared units.

Timestamps remain exact Int64 integers throughout alignment. Pinned JSON encodes
Int64 values as decimal strings, including optional timestamp fields. CSV writes
exact decimal integers. JSON embeds both complete numeric source recordings in
original channel/sample order and source indices are zero-based numeric sample
indices (not physical CSV line numbers). This preserves numeric lineage, not
original whitespace, float spelling, arbitrary-precision decimals or capture
authentication. Keep the original files and recipe with the report.

## Exports and gaps

Default JSON includes the recipe, origins, timebase, window, cutoff, counts,
summary, numeric sources and every row. CLI adds the three input filenames.
`--csv` emits one rectangular row per selected baseline observation with paired
coordinates, separation, status, indices, brackets and declared context. Missing
values are blank. All quotes in labels are doubled, including labels containing
commas or several quoted words. SVG label metacharacters are escaped individually.
Retain JSON alongside CSV for complete source/window context.

`--svg` emits standalone equal-aspect XY with Y upward. Blue is baseline, pink
is the candidate sampled at baseline times, and orange marks unmatched baseline
positions. Every marker has a source/time tooltip. Route connections require
adjacent paired rows, a baseline interval within the cutoff, and no candidate
source interval over the cutoff across the traversed brackets. Thus exact
matches on either side of an outage do not hide the outage. A gap row breaks
both drawn routes. Zero cutoff produces points only. Lines are visual guides,
not evidence of a continuous physically traversed path. Full candidate raw
sample paths are not drawn. Large finite coordinate extents that cannot be
represented safely in SVG return an error rather than invalid coordinates.

## Example

With the example recipe and a 1000 ms cutoff, the included baseline/candidate
fixtures yield 5 pairs, 1 interpolated pair and 3 unmatched observations.
All paired separations are 5 m, so mean/RMS/maximum are 5 m. Two candidate-gap
rows and one outside-range row stay visible. Different column orders and the
unselected battery channel remain intact in the source records.

```sh
telemetry_planar examples/telemetry/planar-baseline.csv examples/telemetry/planar-candidate.csv examples/telemetry/planar-recipe.json --max-gap-ms 1000
# Add --csv or --svg and redirect stdout only to a new file.
```

`--csv` and `--svg` are mutually exclusive. Invalid options, recipes, files or
numeric operations emit JSON errors and exit 2 even in export modes. Help exits
0. Inputs are only read. Choose new destination paths: shell redirection can
truncate a file before the program opens it. All inputs/outputs fit in memory;
there is no streaming, real-time ROS, hardware or provider integration. Double
precision may lose small offsets at very large coordinates; choose sensible
origins and units. Browser rendering and external consumers are separate from
the native CLI and structural SVG checks.
