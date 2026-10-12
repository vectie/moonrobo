# Inspect the value distribution of a recorded channel

An operator can now answer “which measured load ranges appear most often in this
recording?” without manually counting a plot. The dependency-free Node command
reads MoonRobo's numeric telemetry CSV, counts samples in explicitly chosen bins,
reports empirical quantiles, and exports an inspectable SVG or reusable selected
window CSV. Existing importers, normalizers, merge and resampling tools produce
this same CSV shape. This complements their time-domain views; it is not a
replacement for the MoonBit parser or a native cockpit feature.

To compare one measured channel across a second recorded mode channel, use
[state-conditioned measurement comparison](offline-state-conditioned-distribution.md).
It groups same-row observations across repeated state runs, retains undeclared
codes, and requires explicit selection before exporting a group's numeric CSV.

For explicitly declared discrete codes, the same command also provides
[bounded recorded-state durations and run exports](offline-recorded-state-duration.md).
That opt-in mode keeps raw observation counts separate from a left-hold duration
model, with unknown codes and recording gaps reported explicitly. The histogram
behavior documented below is unchanged.

This is a bounded offline slice of PRD MR-W04 and MOONROBO-B06 inspection, with
B07-oriented source traceability. It does not implement durable MoonData lineage,
robot/session/command identity, calibration, incident classification, device
readiness or safety proof. No bridge, SDK, provider or network is used.

## Try the synthetic recording

Run from the repository root with a current Node runtime (tested with the runtime
recorded in the round logs; only built-in modules are used):

```sh
node scripts/telemetry-distribution.mjs examples/telemetry/load-distribution.csv --channel load.n --unit N --edges 0,2,4 > load-report.json
node scripts/telemetry-distribution.mjs examples/telemetry/load-distribution.csv --channel load.n --unit N --edges 0,2,4 --format svg > load-distribution.svg
node scripts/telemetry-distribution.mjs examples/telemetry/load-distribution.csv --channel load.n --unit N --edges 0,2,4 --window 1002 9000 --format csv > selected-load.csv
```

Open the SVG in a viewer or browser of your choice. No browser is launched by
the command. Use distinct output paths so shell redirection cannot truncate an
input. Check exit status before consuming an output: errors exit 2 with a JSON
error on stderr and no stdout; success exits 0. `--help` prints usage. Repeated,
unknown or missing options fail. These commands do not compile MoonBit.

The full example has seven observations. Counts are one below 0, two in [0,2),
three in [2,4], and one above 4. The median is 2, Q25 is 0 and Q75 is 4. The
large timestamp gap does not weight either neighboring observation differently
or produce new samples. The inclusive window 1002 through 9000 exports three
rows with both original numeric channels and exact timestamps.

The exported CSV can be passed directly to the existing `telemetry_csv`,
`telemetry_plot`, or other numeric-CSV command when those compiled products are
available. Their execution is not required or claimed by this Node workflow.
The focused tests exercise reopening and reanalysis through this command and
read the pre-existing `examples/telemetry/joints.csv` fixture.

## Interpretation and options

- `--channel NAME`: exactly one existing channel. No channel or unit discovery.
- `--unit UNIT`: required caller-declared label; never verified or converted.
- `--edges E0,E1,...`: 2 to 65 strictly increasing finite decimal values. Unequal
  widths are permitted. Each bin includes its lower bound and excludes its
  upper, except the final bin includes the final upper endpoint. Internal edge
  values belong to the bin on their right. Underflow/overflow are always shown.
- `--window START_MS END_MS`: optional inclusive nonnegative Int64 timestamps,
  supplied as decimal text. Bounds use the recorded clock, without Unix-time,
  clock-domain, offset or synchronization assumptions. Omitting selects all.
- `--format json|svg|csv`: defaults to JSON. JSON gives counts, fractions,
  quantiles and selected raw numeric observations. SVG uses horizontal count
  bars including tails. CSV exports all original columns for selected rows,
  with normalized number spellings; it is not a histogram table.

Fractions divide by all selected samples, including both tails. They are sample
fractions, not density per bin width, time occupancy or probability of safety.
Every sample gets weight one even for irregular cadence and large gaps. Missing
values are errors; they are never zero-filled, interpolated or silently removed.
There is no inferred threshold, alarm, pass/fail result or automatic bin choice.

Quantiles use nearest-rank order statistics over all selected values including
underflow/overflow: rank=max(1,ceil(p*n)) for p=0,.25,.5,.75,.9,.95,1. There is no
interpolation or averaging between ranks; an even-count median is the lower
central sample. An empty window returns zero counts, null fractions and null
quantile values in JSON, and zero bars in SVG. Empty-window CSV is refused because
it could not be reopened by the numeric recording tools that require a sample.

## Input and lineage

The accepted input is UTF-8 unquoted numeric CSV: first column `timestamp_ms`,
at least one unique nonblank channel, equal-length rows, finite decimal/scientific
numbers, nonnegative Int64 strictly increasing timestamps. Quotes/multiline CSV
are unsupported. Whitespace around fields, LF/CRLF, blank lines and no final
newline are accepted. Printable channel names cannot contain control characters.
The complete source is validated before applying a window, even unselected
channels and out-of-window rows. Invalid UTF-8 fails rather than being replaced.

The JSON report format is `moonrobo.telemetry-distribution.v1`. `source_sha256`
is the SHA-256 of the UTF-8 source content (the CLI decodes strictly, preserving
BOM and line endings for this hash). `samples` preserve exact timestamp strings,
zero-based original numeric sample indices, one-based physical source line numbers
and all numeric channel values. Channel order, selected channel/unit, bin edges,
window and statistical method accompany the observations. Retain the source,
JSON and SVG together; CSV alone cannot preserve these metadata. Numeric values
use JavaScript finite binary64 precision, so lexical spelling and negative zero
may change on export; timestamps never pass through Number.

This is content provenance, not an authenticated capture, immutable record,
processing registry, robot identity or durable MoonData receipt. A hash does not
prove the observations are accurate. Everything is held in memory; no streaming
or large-file performance guarantee exists. SVG label layout is optimized for
short channel/unit labels; long labels may exceed the displayed canvas. The
underlying JSON remains complete.

## Focused verification

```sh
node --test scripts/test-telemetry-distribution.mjs
```

Tests cover hand-computed counts/quantiles, exact Int64 windows, physical source
lineage, irregular-time nonweighting, empty/singleton selection, whole-source
validation, SVG escaping, existing telemetry-fixture import, and actual CLI file
creation/reopen/reanalysis. No dependency installation, Moon command, native
product, browser rendering, provider or hardware qualification is claimed.
