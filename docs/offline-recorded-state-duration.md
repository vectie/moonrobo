# Inspect modeled time in declared recorded states

The existing [recorded distribution explorer](offline-telemetry-distribution.md)
now supports a discrete-state view. An operator reviewing a numeric mode channel
can compare observation counts with modeled duration, locate recorded code
changes, see excluded recording gaps and unknown codes, and export contiguous
modeled state runs for a review spreadsheet. This answers a different question
from the original sample histogram: irregularly spaced samples do not represent
equal amounts of time.

This is an offline inspection slice of PRD MR-W04 and MOONROBO-B06. Explicit gaps
support the uncertainty boundary in MOONROBO-N03; source anchors support part of
the B07 review need. It does not satisfy full cockpit, incident reconciliation,
MoonData storage or physical proof requirements. State names are supplied by the
reviewer, not validated against a device. Even a name such as `ready` conveys no
hardware readiness, task authority, safety or actual physical state.

## Try the synthetic recording

From the repository root, using Node and built-in modules only:

```sh
node scripts/telemetry-distribution.mjs examples/telemetry/recorded-states.csv --channel mode --states '0=idle,1=working,2=held' --max-gap-ms 300 > state-report.json
node scripts/telemetry-distribution.mjs examples/telemetry/recorded-states.csv --channel mode --states '0=idle,1=working,2=held' --max-gap-ms 300 --format svg > state-duration.svg
node scripts/telemetry-distribution.mjs examples/telemetry/recorded-states.csv --channel mode --states '0=idle,1=working,2=held' --max-gap-ms 300 --format csv > state-runs.csv
```

The nine synthetic observations span 1000–3200 recorded ms. Counts are three
idle, three working, two held and one unknown code (9). The model yields:

- Idle: 400 ms, from [1000,1300) and [3100,3200)
- Working: 400 ms, from [1300,1700)
- Held: 100 ms, from [3000,3100)
- Unknown code: 100 ms, from [1700,1800)
- Excluded recording gap: all 1200 ms of [1800,3000)

The final observation at 3200 is working and contributes one observation but
zero duration. The sum of modeled, unknown and gap durations is 2200 ms, exactly
the recording span. Five adjacent recorded value changes are shown; changes
involving code 9 have `unknown-code-boundary` status.

The state-run CSV contains four modeled runs with state labels, exact endpoints,
durations, interval indices, bounding source sample indices/lines/timestamps,
source SHA-256, gap limit and model version. It is a review table, not numeric
telemetry: do not feed it to the raw telemetry parser or interpret its endpoints
as newly captured samples. Import timestamp/duration columns as text to preserve
Int64 values in spreadsheet software, and caller-controlled labels as text.
Keep the JSON and original recording beside the CSV; exclusions, changes and
full processing choices are in JSON. Header-only CSV is valid when no modeled
runs exist. CSV quotes commas and quotes in API-supplied labels.

To inspect the original observations bounding the working run [1300,1700),
continue through the existing histogram mode using the ORIGINAL recording:

```sh
node scripts/telemetry-distribution.mjs examples/telemetry/recorded-states.csv --channel mode --unit recorded-code --edges 0,1,2,10 --window 1300 1700 > working-run-observations.json
node scripts/telemetry-distribution.mjs examples/telemetry/recorded-states.csv --channel mode --unit recorded-code --edges 0,1,2,10 --window 1300 1700 --format csv > working-run-observations.csv
```

The existing histogram window is inclusive: it selects timestamps 1300, 1400
AND the right endpoint 1700, whose recorded code is unknown (9). Bin counts are
[0,2,1], from codes 1, 1 and 9. These are three original observations bounding
the run, not three working observations and not a duration histogram. The run
model excludes its right endpoint; its duration remains 400 ms. This second
CSV is raw numeric telemetry with every original channel and can be reopened
by the existing explorer. It is distinct from the state-run review table.

SVG shows modeled-state duration bars plus separate unknown-code and excluded-gap
bars. It also reports outside-recording time, sample/change counts and the chosen
gap limit. No browser is launched. Long labels can exceed the fixed canvas; the
JSON remains complete. SVG XML structure/escaping are tested, but graphical
rendering and cockpit integration are not qualified.

Use distinct output paths: shell redirection can truncate an input before this
read-only command starts. Success/help exits 0; errors exit 2 with a JSON error
on stderr and no stdout. Validate exit status before using any output. All
validation/calculation completes before output. Unknown/repeated options fail.

## Explicit model and window semantics

For each adjacent pair of original observations at `t0 < t1`:

1. Form the half-open interval `[t0,t1)`. There is no interval before the first
   or after the last observation, and no assumed session-end time.
2. Compare the ORIGINAL gap `t1-t0` with the required `--max-gap-ms` bound. If
   the gap is larger, exclude the entire interval. Do not keep its first
   max-gap milliseconds. A gap exactly equal to the bound is permitted.
3. If the gap is permitted, assign the interval to the declared code recorded
   at the LEFT endpoint. If that code is undeclared, classify its duration as
   unknown. Gap exclusion takes precedence over an unknown code, avoiding
   double counting. A known code followed by an unknown code still holds up to
   the latter observation; the unknown code's own following interval is unknown.
4. Clip the interval to the requested window. A short window inside a long gap
   cannot make that original gap acceptable. Source anchors can lie outside the
   window. Nothing is interpolated and no missing observation is invented.

`--window START_MS END_MS` uses absolute recorded nonnegative Int64 timestamps.
Raw observation counts and changed-right observations include both endpoints;
modeled duration uses `[START_MS,END_MS)`. This deliberately distinguishes point
observations from elapsed intervals. A point window can contain an observation
and a recorded change but contributes zero duration. A window between samples
can contain positive modeled duration with zero selected observations.

```sh
node scripts/telemetry-distribution.mjs examples/telemetry/recorded-states.csv --channel mode --states '0=idle,1=working,2=held' --max-gap-ms 300 --window 1150 1350
```

This contains only the 1300 observation, but models 150 ms idle and 50 ms working
using original 1100/1300/1400 anchors. A window of 1900–1950 yields 50 ms excluded
gap, not held time. A window of 3100–9000 yields 100 ms idle and 5800 ms outside
the recorded span; the final working observation never extends to 9000.

Without a window, use the first through last source timestamp. A singleton has
zero duration. `coverage` partitions time inside the clipped recording span into
modeled, unknown-code and excluded-gap milliseconds; `outside_recording_span_ms`
accounts for requested time before the first or after the last sample. State
fractions divide by MODELED duration only, excluding unknown/gap/outside time;
all fractions are null if modeled duration is zero. Exact durations are decimal
strings; fractions and SVG widths are approximate binary64 calculations.

Contiguous intervals of the same declared code merge into a run. Unknown/gap
intervals always split runs, even if the same known code appears on both sides.
Runs carry first/last interval indices; JSON intervals preserve every original
bounding pair. Run endpoints can be window-clipped and are model boundaries,
not asserted physical transition times.

## Recorded changes are observations

`changes` reports differing adjacent numeric codes when the RIGHT observation
is within the inclusive window. Both endpoint timestamps, source indices/lines,
values and declared labels (or null for unknown) are retained. A left predecessor
outside the window is retained for context. Equal adjacent values are not a
change observation, including across a gap; the gap is still explicitly excluded.

`observed_at_ms` is the right sample's recorded timestamp, not the time a device
changed state. A change crossing a gap has `continuity: gap-excluded`. A change
within the limit has `within-gap-limit`; this is a modeling choice, not proof
that no packets or intermediate changes were missed. The tool cannot count
unobserved transitions, infer physical events or prove that a state persisted.

## Options, input and provenance

- `--channel NAME` selects one existing numeric channel.
- `--states CODE=LABEL,...` explicitly declares 1–64 unique finite numeric codes
  and distinct nonblank printable labels. Shell-quote spaces/metacharacters.
  CLI labels cannot contain commas; the API accepts them. Splitting occurs at
  the first `=`, so a label may contain another `=`. Leading/trailing CLI label
  whitespace is trimmed. Numeric equality is exact equality AFTER binary64
  parsing, without tolerance or automatic rounding. Prefer small integer codes;
  decimal lexical precision and unsafe integers are not retained, and distinct
  spellings may refer to the same numeric code. Duplicate numeric codes fail.
- `--max-gap-ms MS` is required, a positive decimal Int64 integer. Choose it
  deliberately for the recording; there is no inferred cadence or safe default.
- `--format json|svg|csv` defaults to JSON. State mode rejects `--unit` and
  `--edges`, because state labels have caller-declared meanings rather than
  histogram units/bins. Existing histogram commands remain unchanged.

The shared existing parser validates the complete recording before selection:
strict UTF-8 unquoted numeric CSV, `timestamp_ms` first, unique printable channel
labels, finite numeric values and strictly increasing nonnegative Int64 times.
All channels and out-of-window rows are validated; blanks are never zero-filled.
LF/CRLF, blank lines and no final newline are supported. Timestamps, bounds,
durations and gap sizes use BigInt internally and strings externally. All channel
values use JavaScript binary64 precision. No clock-domain or Unix-time assumption
is made. Missing cells, duplicates and nonfinite values fail.

JSON schema `moonrobo.telemetry-state-duration.v1` includes the source SHA-256,
channel, original span, window, gap limit, full duration/observation rules,
declarations and summaries, coverage, changes, intervals, runs and selected raw
rows including other channels. Source sample indices are zero-based; physical
source lines are one-based. Hashing preserves valid source UTF-8 bytes including
BOM and line endings. A content hash proves neither origin nor source truth.

This does not create authenticated capture lineage, robot/session/command
identity, a processing registry or a durable MoonData receipt. It never modifies
source data, contacts a provider or device, sets readiness, reconciles outcomes,
issues alarms, grants authority or sends commands. Entire files/reports remain
in memory; no streaming or large-recording performance guarantee exists.

Reusable exports from `scripts/telemetry-state-duration.mjs` are
`stateDuration(text, { channel, states, maxGapMs, window })`,
`stateRunsCsv(report)` and `stateDurationSvg(report)`. Each state is
`{ value: number, label: string }`; gap/window inputs are decimal strings. Export
helpers accept a successful unmodified report and do not revalidate arbitrary
objects. The recording parser is shared in `telemetry-recording.mjs` and remains
re-exported from `telemetry-distribution.mjs` for existing consumers.

## Focused verification

```sh
node --test scripts/test-telemetry-distribution.mjs scripts/test-telemetry-state-duration.mjs scripts/test-telemetry-stitch.mjs scripts/test-telemetry-lag.mjs
```

Twelve new focused tests check hand-calculated durations and observed changes,
run merging/splitting, gap precedence, clipping and outside anchors, singleton
and final-sample behavior, exact Int64 accounting, explicit declarations, whole
source validation, SVG/CSV escaping, and actual CLI artifact creation/reopening.
Existing distribution, stitching and lag tests run unchanged. No dependencies,
Moon command, native product, browser, SDK, provider or hardware qualification
is part of this Node verification.
