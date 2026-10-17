# Explore noisy threshold episodes with hysteresis

MoonRobo operators can inspect a recorded high-state episode without fragmenting
it whenever a noisy signal dips slightly below its entry threshold. This offline
CLI builds on the existing numeric telemetry format. It never connects to robots.

From the repository root, with Node.js:

```sh
node scripts/telemetry-hysteresis.mjs examples/telemetry/hysteresis-noisy.csv --channel load --unit N --enter 10 --exit 5 --max-gap-ms 1000 > episodes.json
node scripts/telemetry-hysteresis.mjs examples/telemetry/hysteresis-noisy.csv --channel load --unit N --enter 10 --exit 5 --max-gap-ms 1000 --format csv > states.csv
```

The sample produces three episodes: 100–400 ms, the singleton at 700 ms, and
2100–2200 ms. Values 9 and 7 remain active after entering at 10. A value of 5
exits. The 1300 ms gap resets the classifier, so the observation of 8 at 2000 ms
starts inactive. The final episode is open at the end of the recording.

Feed states.csv into the existing telemetry CSV explorer or plot command with
channel hysteresis_active, unit recorded-state, and the same max-gap-ms cutoff.
The hysteresis_segment column identifies disconnected observation segments.
Keep episodes.json and the input alongside CSV for thresholds, unit and source
hash. CSV alone carries no threshold metadata.

For a ready-to-view SVG and bounded duration summary, reuse the existing
distribution CLI:

```sh
node scripts/telemetry-distribution.mjs states.csv --channel hysteresis_active --states 0=inactive,1=active --max-gap-ms 1000 --format svg > states.svg
```

That consumer explicitly adds its bounded left-hold duration model. Here it
models 500 ms active and 400 ms inactive, excludes the 1300 ms gap, and does not
extend the final observation. These modeled durations differ from episode
observed spans; neither estimates an actual physical crossing time.

## Semantics

- Required finite levels satisfy exit < enter. This detects high-state episodes;
  below-threshold hysteresis is not provided.
- Every recording segment starts inactive. A value >= enter activates; a value
  <= exit deactivates. Values strictly between levels retain the previous state.
- A gap strictly greater than the positive max-gap-ms starts a new segment.
  A gap equal to the cutoff is retained. No interpolation or gap filling occurs.
- Episode span is last active timestamp minus first active timestamp. The exit
  sample is inactive and is recorded separately as boundary_timestamp_ms.
  A gap boundary is also a later observation, not an inferred crossing time.
  Recording-end episodes have a null boundary timestamp.
- Millisecond times remain exact nonnegative Int64 decimal strings. Samples
  include original source line and zero-based sample index.
- The whole input is validated, including unrelated channels; malformed input
  yields exit code 2 and a JSON error on stderr, with no partial stdout.
- Input is unquoted numeric CSV, at most 4 MiB, finite numeric channels and
  strictly increasing timestamps. The CLI reads the whole file into memory.
- The unit is the operator's declaration, not calibration or conversion.

This deterministic classifier describes observations, not continuous physical
state, incident classification, readiness, successful execution or safety.
No native API, UI or hardware interface is changed. Run the focused tests with:

```sh
node --test scripts/test-telemetry-hysteresis.mjs
```
