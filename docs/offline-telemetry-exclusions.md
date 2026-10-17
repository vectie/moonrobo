# Edit recorded telemetry with annotated exclusions

Use this offline tool when you know a capture interval should be left out of a
derived analysis, such as a noted connector disturbance. It previews exactly
which observations are retained or excluded and exports separate retained
segments. The original recording and all its observations stay in the JSON
report. The tool does not detect corruption or certify that retained data is good.

## Try the complete workflow

From the MoonRobo source root, with the installed MoonBit toolchain:

```sh
moon run cmd/telemetry_exclude --target native -- examples/telemetry/exclusion-recording.csv examples/telemetry/exclusion-recipe.json > edit.json
moon run cmd/telemetry_exclude --target native -- examples/telemetry/exclusion-recording.csv examples/telemetry/exclusion-recipe.json --csv --segment 1 > retained-1.csv
moon run cmd/telemetry_csv --target native -- retained-1.csv
```

Always choose new output filenames. Never redirect output over either input.
For isolated verification, use a private HOME/XDG, an absolute external target
directory, the shared native-build lock and stripped single-job native builds.

The example has 11 observations. Two are excluded; overlapping notes both
appear on the 300 ms observation. Nine observations remain in four segments:

- Segment 0: 0–100 ms, 2 observations
- Segment 1: 400–600 ms, 3 observations
- Segment 2: 800–900 ms, 2 observations
- Segment 3: 2000–2100 ms, 2 observations

The 650–750 ms note contains no observed rows but still separates segments 1
and 2. The 900–2000 ms gap exceeds the explicitly selected 250 ms cutoff and
starts segment 3. The 3000–3100 ms note affects nothing: its zero row and
boundary counts help you spot a misplaced annotation. Segment 1 feeds the
existing exploration tool unchanged and has position values 4, 5 and 6.

## Write or revise a recipe

```json
{
  "editor_label": "Capture review draft",
  "max_gap_ms": "250",
  "intervals": [
    { "id": "disturbance", "start_ms": "150", "end_ms": "300", "reason": "Operator note at capture time" }
  ]
}
```

Times use the recording's original nonnegative millisecond timebase. All
millisecond fields are exact Int64 decimal strings, including values beyond
JavaScript's safe-integer range. `max_gap_ms` must be positive. Both interval
endpoints are included, so a zero-width interval excludes an observation at
that exact time or cuts continuity if it falls between two retained samples.

Interval order does not change retained rows. IDs must be unique; overlapping
intervals form a union for exclusion and retain all matching IDs in recipe
order. Intervals may be unsorted, partly outside the recording, or unmatched.
An empty interval list is a useful unedited comparison, still split at the
specified gap cutoff. Keep prior recipes and reports when editing a reason or
range: changing the recipe changes its SHA-256 identity in the next report.

The exact fields shown are required. Unknown, duplicate, missing or wrong-type
fields fail. Bounds: 128 intervals, 64 text units per ID, 1024 per reason and
256 for the editor label; labels/reasons must not be blank. The CLI reads at
most 4 MiB of CSV and 256 KiB of recipe into accepted input, checked after file
read; the API limits strings to 4 Mi and 256 Ki UTF-16 units. At most 100,000
source rows are supported. Every source field is validated before exclusion,
including excluded rows. This tool cannot repair malformed CSV or missing cells.

## Inspect and retain the result

Default JSON includes exact input-byte `source_sha256` and `recipe_sha256`, the
recipe, all parsed original observations/channels, per-row dispositions, all
matching interval IDs, interval coverage counts and retained segment bounds.
`source_sample_index` is a zero-based parsed observation index, not a physical
file line number. Excluded rows have no `segment` field. Segment indexes are
zero-based. Each boundary names the adjacent retained source indexes, crossed
interval IDs and whether their separation exceeds the maximum gap.

`matched_sample_count` is per interval; overlapping counts must not be added
to infer total exclusions. `crossed_boundary_count` counts cuts between retained
observations; notes at an excluded prefix/suffix can have matches and zero cuts.
The separately reported total excluded count counts each row once.

CSV exports all original channels and exact timestamps with canonical numeric
spellings. It omits the editing lineage. With multiple segments, `--csv` needs
`--segment INDEX`; no option exports across the removed intervals. With no
retained observations, JSON remains inspectable but CSV fails. Keep the raw
CSV, recipe and JSON together, and analyze each exported segment separately.
Do not concatenate segments and assume continuity. Downstream analyses retain
their own sample-count and spacing requirements.

`editor_label` and reasons are user-supplied annotations, not authenticated
review, a physical diagnosis, a readiness decision or a permission grant. A
digest identifies bytes, not their correctness. JSON preserves parsed values,
not the raw CSV's numeric spelling or whitespace; retain the raw file too.
There is no hardware, provider, network, bridge, retry or safety action.

## Verification

`src/telemetry_csv/exclusion_test.mbt` covers overlap, exact endpoints, empty and
all-excluded edits, no-observation cuts, source gaps, Int64 extremes, invalid
recipes, malformed excluded rows, downstream library use and exhaustive small
interval selections. `scripts/verify_exclusion_workflow.mbtx` exercises the
actual native edit and exploration executables, digest binding, deterministic
replay, unchanged input bytes, JSON/CSV export and 11 CLI negative cases.
