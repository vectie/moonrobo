# Find observed threshold episodes

Use `telemetry_events` to locate consecutive recorded samples strictly above or
below a threshold on one explicitly selected numeric channel. This is offline
inspection for MR-W04/MR-W06, not incident classification or physical proof.

```sh
moon run cmd/telemetry_events -- recording.csv temperature above 70 --max-gap-ms 1000 --min-span-ms 200
moon run cmd/telemetry_events -- recording.csv temperature below 10 --max-gap-ms 1000 --csv
```

The same operation is available as `@telemetry_csv.threshold_events_csv(text,
channel, direction, threshold, min_span_ms~, max_gap_ms~)`. Results expose
`to_json()` and `to_csv()`.

- `above` means `value > threshold`; `below` means `value < threshold`.
  Equality is excluded and ends an episode.
- A nonmatching source sample always ends an episode. Adjacent matching samples
  join only if the timestamp difference is at most `--max-gap-ms`.
- The default maximum gap is Int64 maximum, meaning no gap-based splits. Choose
  an explicit gap appropriate to the recording. A zero maximum makes singletons.
- `--min-span-ms` defaults to zero. Keep an episode if its last recorded timestamp
  minus its first is at least this value. A singleton has a zero observed span.
- Limits must be nonnegative Int64 integers, and the threshold must be finite.
- Output positions are zero-based sample positions in the input (excluding the
  header and blank lines), not physical CSV line numbers. Min/max/count include
  only the matching samples in that episode.
- JSON timestamps and spans are decimal strings to preserve exact Int64 values,
  including beyond JavaScript's Number precision. CSV contains decimal text;
  import timestamp/span fields as text or Int64 in downstream tools.
- JSON keeps channel, threshold, direction, gap/span settings and source sample
  count even for zero episodes. CSV repeats this metadata per episode; an empty
  CSV result has only its header. Keep the JSON report for empty-result context.

Input is the existing unquoted numeric telemetry CSV format: `timestamp_ms`
followed by unique channel names, nonnegative strictly increasing timestamps,
finite numeric values and rectangular rows. Every row and every channel is
validated, including nonmatching rows and unselected channels. Errors return
exit 2 with JSON even when `--csv` was selected. Input is read without mutation.

## Interpretation and limits

Endpoints are first and last observed matching samples, not crossing times.
Observed span is not proof the predicate remained true between samples. Gaps
below the chosen cutoff still contain unknown states. No interpolation,
hysteresis, calibration, unit conversion, incident/readiness inference or device
dispatch is performed. Very small or large finite floating-point values remain
ordinary Double comparisons. The report does not identify an immutable source;
keep the source recording and command options alongside exported results.
Whole-file parsing is in-memory. No live stream, UI or provider path is added.
