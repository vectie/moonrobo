# Compare runs around an observed event

Use `telemetry_event_compare` when recording starts do not describe the same
phase of two offline runs. Select an observed threshold episode in each file,
then compare channels in a pre/post-event window. This joins the existing
[observed episode finder](observed-threshold-events.md) and
[run comparison](offline-run-comparison.md), keeping both original clocks.

## Example: skip a candidate warm-up cycle

The synthetic `event-baseline.csv` and `event-candidate.csv` have different
recording starts and a warm-up episode in the candidate. Baseline episode 0 starts
at 1200 ms; candidate episode 1 starts at 5500 ms. Inspect both files with the
existing event finder first if you do not know which episodes correspond.
Episodes are zero-based in chronological order **after** gap/span filtering.

In the retained reproduction kit, first run `verify-native.sh` as described by
its BUILD.md. These example commands use the retained, isolated native target:

```sh
R=/workspace/scratch/665adc5202cf/.moonsuite-background/r356-360/work/r356-moonrobo
. "$R/environment.sh"
test "$(df -B1 --output=avail "$R" | tail -1)" -gt 4294967296
flock "$MOON_NATIVE_LOCK" "$R/target/native/debug/build/cmd/telemetry_events/telemetry_events.exe" \
  "$R/source/examples/telemetry/event-candidate.csv" trigger above 0.5 \
  --min-span-ms 100 --max-gap-ms 150
flock "$MOON_NATIVE_LOCK" "$R/target/native/debug/build/cmd/telemetry_event_compare/telemetry_event_compare.exe" \
  "$R/source/examples/telemetry/event-baseline.csv" "$R/source/examples/telemetry/event-candidate.csv" \
  --event-channel trigger --direction above --threshold 0.5 --episodes 0 1 \
  --event-min-span-ms 100 --event-max-gap-ms 150 --window 300 600 \
  --channels joint.rad,temp.c --max-gap-ms 150
```

The report compares seven baseline observations, including two interpolated
candidate values, with joint bias 0.5 rad and temperature bias 2 degrees C.
One time lies inside a 200 ms candidate gap beyond the 150 ms comparison limit;
one lies after the candidate recording. Both remain explicit unmatched rows.
Add `--csv` to export long-form values and gaps. Save JSON as well: CSV retains
original paired timestamps and signed elapsed time, but omits anchor configuration
and summary metadata. CSV is compatible with the existing comparison CSV schema,
not the numeric recording parser's wide schema.

## Exact behavior

- Required `--event-channel`, `--direction above|below`, `--threshold`,
  `--episodes BASELINE_INDEX CANDIDATE_INDEX`, `--window BEFORE_MS AFTER_MS`, and
  `--event-max-gap-ms` make event selection explicit. `--event-min-span-ms`
  defaults to 0. Both event limits are inclusive and nonnegative.
- Strict above/below comparison excludes equality, which breaks an episode.
  Matching adjacent source observations join only within the event gap limit.
  Minimum span is last minus first observed timestamp, not continuous dwell time.
- Elapsed zero is the selected episode's **first actual sample**, not a threshold
  crossing estimate. The JSON anchor retains index, qualifying episode count,
  full episode endpoints/source positions/statistics, and actual anchor value.
- `--window 300 600` includes baseline times from -300 through +600 ms around
  its anchor. Both arguments are nonnegative. Selection does not move the anchor.
  All rows/channels in both recordings are validated before selecting events.
- Channel matching, sample-weighted summaries, candidate-minus-baseline deltas,
  earliest peak tie, and interpolation are inherited from the comparison engine.
  Without `--channels`, common channels follow baseline order (including the
  event channel if common). Explicit lists preserve their order.
- `--max-gap-ms` controls **candidate value interpolation**, independently of
  `--event-max-gap-ms`, which only groups threshold observations. The default 0
  compares exact elapsed matches only. No extrapolation occurs before or after
  candidate coverage. Interpolated rows retain both original bracket timestamps.
- Every timestamp remains exact Int64, represented as a JSON decimal string.
  Registration subtracts each origin without rewriting either source timestamp.
  Negative elapsed values are valid, even when clocks exceed 2^53.
- Missing episodes, nonexistent channels, malformed input, numeric overflow,
  duplicate/unknown options, invalid values, or missing required options produce
  one JSON error and exit 2, also in CSV mode. There is no first-sample fallback.
  Successful reports exit 0; source files are only read.

## API and integration

`src/telemetry_csv.compare_event_csv` takes CSV texts, event channel, direction,
threshold, explicit baseline/candidate episode indices, before/after milliseconds,
event minimum span and maximum gap, comparison maximum gap, and optional channels.
It returns `Result[EventComparison, String]`; `EventComparison::to_csv` emits the
same long-form export as `Comparison::to_csv`. The public `compare_csv` and its
`moonrobo.telemetry-comparison.v1` first-sample behavior remain unchanged.

The new outer JSON format is `moonrobo.observed-event-comparison.v1`. Nested
comparison values use `moonrobo.event-comparison-values.v1` and timebase
`milliseconds-since-each-selected-observed-event`. Do not interpret the nested
origins as file starts. Input paths are context, not content hashes or immutable
evidence IDs. Keep the original recordings and JSON with derived CSV.

## Interpretation and limits

The user chooses whether two episodes correspond. A shared threshold, sample or
channel name cannot establish common units, clock rate, calibration, or physical
meaning. Normalize units explicitly before comparison. Event registration shifts
origins only: it does not correct drift, align every repeated cycle, interpolate
crossing times, infer latency/causality, or establish physical success/readiness.
Different sampling intervals can change the first observed event time. Gaps and
sampling can hide actual onset and excursions. Interpolation is a linear estimate,
and statistics give each compared baseline sample equal weight, not equal time.
The complete recordings and outputs must fit in memory; floating rounding applies.
This is offline analysis, with no hardware, provider, bridge or control operation.
It does not claim durable MoonData storage or full PRD B07 acceptance.
