# Explore repeated recorded-event responses

Compare the same measured channel around several explicitly selected events in
one local recording. This closes the gap between listing threshold episodes and
manually comparing them one pair at a time: inspect individual aligned traces,
the mean/range at each relative offset, and exactly which episodes support each
summary. Edit a saved recipe to revise the comparison, then export an original
event window for the existing telemetry tools.

This is offline recorded-data exploration. An event is an observed numeric
threshold episode, not a verified physical transition, command, trial outcome,
independent experiment or safety decision. The command never opens a device,
bridge, provider, network connection or robot runtime.

## Import, select, explore, revise, and reopen

Build `cmd/telemetry_responses` and `cmd/telemetry_plot` with the repository's
declared dependencies. Use an absolute external build target and a private
HOME/XDG/TMPDIR when running in a shared workspace. The qualified toolchain was
MoonBit 0.10.14+7d59c7ec9; module dependencies are unchanged. For example, after
setting an absolute `MOON`, `SOURCE` and `TARGET` and the private environment:

```sh
"$MOON" -C "$SOURCE" --target-dir "$TARGET" build --frozen --target native --strip -j 1 cmd/telemetry_responses cmd/telemetry_plot
```

In a shared build workspace, serialize native compilation using the workspace's
native-build lock. Set `RESPONSES` to the resulting
`$TARGET/native/debug/build/cmd/telemetry_responses/telemetry_responses.exe` and
`PLOT` to `$TARGET/native/debug/build/cmd/telemetry_plot/telemetry_plot.exe`.
From the source directory:

```sh
"$RESPONSES" examples/telemetry/repeated-responses.csv examples/telemetry/repeated-responses.recipe.json > responses.json
"$RESPONSES" examples/telemetry/repeated-responses.csv examples/telemetry/repeated-responses.recipe.json --format svg > responses.svg
"$RESPONSES" examples/telemetry/repeated-responses.csv examples/telemetry/repeated-responses.recipe.json --format csv > episode-points.csv
"$RESPONSES" examples/telemetry/repeated-responses.csv examples/telemetry/repeated-responses.recipe.json --format summary-csv > offset-summary.csv
"$RESPONSES" examples/telemetry/repeated-responses.csv examples/telemetry/repeated-responses.recipe.json --format clip-csv --clip-episode 1 > second-event.csv
"$PLOT" second-event.csv --channel load.n --unit N --max-gap-ms 200 --svg > second-event.svg
```

Use new output paths. Shell redirection can truncate an input before a command
starts. Check exit status before consuming output: success/help exits 0; errors
exit 2, emit one JSON error on stderr and no stdout. All calculation completes
before any output. The commands read files and write stdout only; neither inputs
nor product state are modified.

The fixture is entirely synthetic, containing ten numeric observations and three
qualifying episodes anchored at 1100, 2100 and 3100 recorded milliseconds. The
example recipe selects load and temperature on offsets −100, 0, 100, 200 ms:

- At −100: three supported episodes; load mean/min/max are 0/0/0 N.
- At 0: three exact observations; load mean/min/max are 4/2/6 N.
- At 100: two supported episodes; load values 4 and 6 N, mean 5 N. The second
  value is linear interpolation between 2100 and 2300 ms. The third episode is
  unavailable because its bracketing 3100–3400 interval exceeds the 200 ms limit.
- At 200: two exact observations, 2 and 8 N; mean 5 N. The third remains missing.

The overlay shows gray episode traces and blue mean dots/min–max bars. Mean dots
are not connected, because the supported episode set can change. Gray traces
break on missing points and on source-segment changes even if a coarse grid
contains no point inside a recording gap. Each panel has its own Y scale. Units
are supplied labels; no calibration or unit conversion is performed. Support
counts are displayed for small grids; every supported mean dot has a tooltip.
Missing points and their reasons are complete in JSON/CSV.

To revise the comparison, copy the recipe to a new file, change `episodes` to
`[0, 1]` and `max_gap_ms` to `"100"`, and rerun against the original recording.
At offset 100, only episode 0 now supports the mean, which becomes 4 N. The report
has a new recipe content hash. Keep both reports if you want both processing
choices. The tool does not write an immutable revision store for you.

The raw clip of episode 1 contains only original timestamps 2000, 2100 and 2300
and all original channels. It does not contain the estimate at 2200 or any mean.
The existing native plot and CSV explorer can reopen it. Absolute recorded times
and gaps remain; retain an explicit downstream gap limit. This clip is not the
aligned review table.

## Editable recipe and exact semantics

`examples/telemetry/repeated-responses.recipe.json` documents all 13 required
fields. Unknown/duplicate keys and invalid types fail. Millisecond fields are
Int64 decimal strings, so large timestamps are not rounded through binary64.

- `event_channel`, `direction`, `threshold`: use the existing strict `above` or
  `below` threshold detector. Equality breaks an episode. Consecutive matching
  observations join only within `event_max_gap_ms`. `event_min_span_ms` filters
  on last minus first matching observation, not inferred dwell time.
- `episodes`: 1–64 distinct zero-based indices AFTER the minimum-span and gap
  filters. Caller order is retained. No event is automatically selected or
  discarded. Use the existing `telemetry_events` command to inspect qualifying
  episodes first. JSON also retains all qualifying episode descriptors. Changing
  event rules can change indices; inspect the new anchors when editing them.
- `channels`, `unit_labels`: 1–32 distinct existing numeric channels and matching
  nonblank printable unit labels. Recorded numeric codes are supported as values
  but interpolation is meaningful only for channels where you deliberately accept
  a piecewise-linear model. Do not interpolate discrete modes as physical states.
- `before_ms`, `after_ms`, `step_ms`: nonnegative pre/post extents and a positive
  grid spacing. Both extents must be exact multiples of the spacing. The grid is
  inclusive, starts at `-before_ms`, ends at `after_ms`, and always contains zero.
  At most 10,001 offsets and 200,000 episode/offset/channel cells are allowed.
- `max_gap_ms`: a nonnegative source-interval limit for interpolation, separate
  from the event detector's limit. An exact observation is always available. A
  non-exact grid time requires two original bounding samples no farther apart
  than this limit. The entire original interval is checked; selecting a short
  window inside a long gap cannot make the gap acceptable. Zero allows exact
  observations only. No extrapolation, zero fill, smoothing or anti-alias filter.
- `overlap_policy`: `reject` refuses intersecting inclusive requested windows,
  including a shared endpoint. `allow-shared-observations` retains them and lists
  every overlapping selected pair. A measurement may then contribute to several
  episode-relative positions. Those trials are dependent; do not treat count as
  independent experimental replication. Window intersection is conservative and
  does not require identical sampled grid points.

Zero is the first matching recorded observation of each selected episode. It is
not an interpolated threshold crossing. An episode beginning with the first row
may already have been underway before capture; one following a gap may be a
continuation that was not observed. The detector cannot discover missed events.
Selection does not establish that episodes have the same cause or operating
conditions. No time-warping or duration normalization occurs.

Requested pre/post windows are never silently shortened. Every episode has the
same grid, with `outside-source-range`, `outside-timestamp-domain` or
`source-gap-exceeds-limit` for unsupported positions. The latter retains the
original bracketing source indices/timestamps. Out-of-domain timestamps are omitted from JSON
rather than wrapped or saturated. Boundary clipping applies only to the raw clip
export, which contains existing observations within the requested window.

At each offset, mean/minimum/maximum use one supported value per selected episode.
Missing episodes are excluded, never treated as zero. Exact/interpolated/missing
counts and the precise supported episode indices are retained. If support is
empty, optional summary value fields are omitted from JSON. Missing point values
and unavailable source-bracket fields are likewise omitted, never represented as
zero; their status and support counts remain explicit. CSV exports use empty
cells for unavailable values. This is neither time weighting nor weighting
by the number of raw observations in an episode. Min/max bars are descriptive
spread, not confidence intervals, control limits or significance tests. Means
and interpolation use binary64 arithmetic; decimal spelling is not preserved.

## Data and output contracts

The existing numeric CSV parser validates all source rows/channels before event
selection. It accepts unquoted rectangular CSV with `timestamp_ms` first, unique
nonblank channel names, finite numeric cells and strictly increasing nonnegative
Int64 timestamps. Blank lines and CRLF are accepted; missing cells, quotes,
nonfinite values and duplicate times fail. The CLI decodes UTF-8 strictly. There
is no clock-domain, Unix-time, robot/session or sensor-unit inference.

Default JSON envelope `moonrobo.recorded-event-response-file.v1` includes input
and recipe filenames, SHA-256 hashes of their exact bytes, the parsed recipe and
`moonrobo.recorded-event-responses.v1`. The response contains the full parsed
source, qualifying episodes, selected anchors, grid points, source brackets,
interpolation weights, source-segment IDs, overlaps and summaries. Sample indices
are zero-based in the complete recording, not physical file line numbers. Original
values and timestamps are recoverable from `source`; exact raw text remains in
the unmodified input. Hashes identify bytes, not authorship or truth.

`csv` is a long-form episode/offset/channel review table, including missing rows
and blank unavailable values. `summary-csv` contains support counts, supported
episode indices and summary values. Neither is raw telemetry. CSV quotes labels
and doubles embedded quotes; import caller-controlled labels as text in a
spreadsheet. Import timestamp fields as text if the spreadsheet cannot retain
Int64 values. Keep JSON and inputs beside these tables because CSV omits recipe
and file hashes. `clip-csv` is the separate reusable numeric-recording export.

SVG supports up to eight channels and 201 offsets; use JSON/CSV or a coarser grid
above that. Long channel/unit labels are shortened visually, but retained in
JSON/CSV. SVG has no external resources or executable content. Its structure,
escaping and discontinuities are tested; browser rendering/accessibility are not
qualified. Entire inputs/reports are held in memory, with no large-file or
streaming performance guarantee.

## Scope and verification

This is an adjacent local slice of PRD MR-W04 / MOONROBO-B06, with B07-oriented
source traceability and N03-inspired explicit gaps. It does not satisfy those
requirements' cockpit readiness, robot/command-bound MoonData capture lineage,
physical acknowledgement reconciliation or platform acceptance criteria. No
MoonData catalog, named reviewer, durable Book receipt, telemetry freshness,
physical authority, autonomous retry or hardware proof is created.

The focused package tests cover analytical responses, variable support,
source-bracket lineage, clipping/missing positions, explicit overlaps, exact
Int64 boundaries, extreme finite values, recipe errors, CSV/SVG output and raw
clip reopening. `scripts/verify_event_responses.mbtx` exercises the actual native
CLI, saved outputs, recipe revision, content hashes, eight negative cases, and
reopening through the existing native plot command. It requires absolute source
and target paths and a new output directory; it does not compile or contact a
device. Run it using the private environment and an absolute external script
target. Existing broader release blockers remain blocking.
