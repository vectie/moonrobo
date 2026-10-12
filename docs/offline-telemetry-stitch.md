# Reassemble rotated telemetry captures

An operator who receives several file fragments from the same recording can now
inspect the whole recorded session without pasting rows into a spreadsheet.
`telemetry-stitch.mjs` imports two to 64 same-schema numeric CSV fragments, sorts
their observed timestamps, accounts for overlap, and exports a recording that
MoonRobo's existing distribution explorer and numeric-CSV tools can read. The
report retains every source row reference, including rows collapsed at overlap.

This fills a different preparation step from [sensor merging](offline-sensor-merge.md):
that tool joins different channels on one primary sample grid. Stitching reunites
fragments of the same channel set and retains the union of observed timestamps.
No offset, interpolation, resampling or missing measurement is introduced.

The workflow is an offline slice of MR-W04/B06 observation inspection. B07 motivates
its content provenance, but this does not create MoonData artifacts, certify a
capture, bind observations to a robot/command, or qualify hardware. No bridge,
provider, device, network, Moon build or browser is used by this command.

## Complete local workflow

Run with Node from the repository root. Only Node built-in modules and the
existing numeric CSV module are used; there are no packages to install.

```sh
node scripts/telemetry-stitch.mjs --input examples/telemetry/rotated-part-a.csv --input examples/telemetry/rotated-part-b.csv --input examples/telemetry/rotated-part-c.csv --clock same-recorded-clock --overlap require-equal --max-gap-ms 100 > session.json
node scripts/telemetry-stitch.mjs --input examples/telemetry/rotated-part-a.csv --input examples/telemetry/rotated-part-b.csv --input examples/telemetry/rotated-part-c.csv --clock same-recorded-clock --overlap require-equal --max-gap-ms 100 --format csv > session.csv
node scripts/telemetry-distribution.mjs session.csv --channel load.n --unit N --edges 0,4,8 > session-distribution.json
node scripts/telemetry-stitch.mjs --input examples/telemetry/rotated-part-a.csv --input examples/telemetry/rotated-part-b.csv --input examples/telemetry/rotated-part-c.csv --clock same-recorded-clock --overlap require-equal --max-gap-ms 100 --format csv --segment 1 > later-segment.csv
node scripts/telemetry-distribution.mjs later-segment.csv --channel load.n --unit N --edges 0,4,8 --format svg > later-segment.svg
```

These synthetic files have nine input observations, seven unique recorded
timestamps, and equal overlaps at 1200 and 5100 ms. The second file deliberately
reorders columns. The whole-session distribution has three samples in [0,4) and
four in [4,8], with median load 4. The interval from 1300 to 5000 ms is 3700 ms,
so the cutoff creates two segments. Segment 1 contains times 5000, 5100 and 5200,
with loads 5, 6 and 7. It can be examined separately without bridging that gap.

Use distinct output paths: shell redirection to an input would truncate it before
the command starts. Check every exit status before consuming outputs. Success is
0; errors are 2, with one JSON `error` on stderr and no stdout. There is no partial
CSV before a late conflict. `--help` prints usage. The command reads sources and
writes stdout only. It never updates product state or source files. An SVG can be
opened with a viewer of your choice; the commands do not launch a browser.

## Explicit decisions and their limits

- `--input PATH` repeats for each fragment. Input order may be arbitrary; first
  input determines output column order, while chronological order determines rows.
  Names must be unique, nonblank and printable. No directory scan or glob expansion
  happens inside the command. Use `./` before a filename starting with `--`.
- `--clock same-recorded-clock` is required. This is your assertion that fragments
  share one unchanged recorded clock, robot/session, units and calibration. It is
  not verified by names or hashes. A recorder restart that resets timestamps must
  be handled separately; the tool does not detect every reset across files, infer
  offsets, repair drift, or distinguish two unrelated recordings with disjoint
  timestamps. Never stitch such files just to make their timestamps monotonic.
- `--overlap reject` fails whenever two fragments contain the same timestamp.
  Choose this when fragments should have no overlap.
- `--overlap require-equal` collapses a repeated timestamp only if all channel
  values are exactly equal after finite binary64 numeric parsing and column-name
  alignment. Different numeric spellings can agree, and positive/negative zero
  compare equal. There is no tolerance or first/last-file preference. Any conflict
  stops the operation and identifies its timestamp, channel and source. Distinct
  source decimals that round to the same binary64 number cannot be distinguished;
  this is not byte-equality verification.
- `--max-gap-ms MS` is required, a positive Int64 decimal millisecond value. An
  adjacent interval strictly greater than it splits a segment; equality does not.
  The combined timeline determines gaps: another fragment's real observation may
  fill a gap present in one file. The reported interval is between observations,
  not proven recorder downtime, sensor staleness, missing sample count or physical
  inactivity. No measurements are invented inside it.
- `--format json|csv` defaults to JSON. JSON always describes the complete stitch.
  `--segment INDEX` is permitted only with CSV, using the zero-based chronological
  segment indices from that JSON report. Missing segments are errors. The whole
  CSV retains gaps in timestamps but has no segment marker; use a suitable gap
  cutoff in downstream plotting or export one segment at a time.

All channels must be present in every fragment, with exactly matching names.
Column order may differ. Schema changes, unit changes or separate sensor streams
need explicit preparation elsewhere. A channel label does not certify its units.
All rows in all inputs are parsed before overlap processing; malformed rows are
not silently dropped. Within each fragment, timestamps must strictly increase.

## Source and output contract

The existing [numeric CSV format](offline-telemetry-csv.md) is used: unquoted
UTF-8 text, `timestamp_ms` first, unique printable nonblank channel names, finite
decimal/scientific numbers, and at least one row per fragment. Whitespace around
fields, blank lines, LF/CRLF and no trailing newline are accepted. Quoted/multiline
CSV and missing numeric values are unsupported. CLI UTF-8 decoding is strict.
Timestamps stay exact nonnegative Int64 strings, even above 2^53. They are never
converted to Number or shifted to elapsed zero.

JSON format `moonrobo.telemetry-stitch.v1` includes:

- Explicit clock/overlap/gap policies, output channels and interpretation
- `sources`: input-order indices, supplied names, SHA-256 of each UTF-8 source,
  original column order, sample counts and original first/last timestamps
- `samples`: timestamp, values in output channel order, zero-based output sample
  and segment indices, and all contributing `sources` references
- Each reference has `source_index`, zero-based `source_sample_index` and one-based
  physical `source_line`; blank lines do not consume sample indices
- Total input/output counts, collapsed extra overlap row count, and count of
  timestamps with overlap (these differ for a three-way overlap)
- Chronological segments with inclusive endpoints and sample counts, and gaps
  with adjacent output indices, exact timestamps and observed interval

Every input observation has exactly one retained source reference. Reordering
files can change source indices and output column order, but does not change the
observed timestamps or named values. CSV exports normalize numeric spellings and
omit lineage, policies and gaps. Keep the JSON and original files alongside it.
Content hashes identify bytes but cannot authenticate authorship, calibration,
clock compatibility or sensor accuracy. This report is not immutable MoonData
storage, a safety receipt, physical readiness, or full PRD B07 acceptance.

The reusable API is `stitch([{ name, text }, ...], { clock, overlap, maxGapMs })`,
with `maxGapMs` supplied as decimal text, and `stitchCsv(report, segmentIndex)`.
The latter expects an unmodified successful report and exports all samples when
the segment index is omitted. The API does not read files or contact anything.
Everything is held in memory and sorting is by unique observations; no streaming
or large-file performance guarantee is claimed. Numeric values use binary64, so
exact decimal spelling, very small values and negative zero may change on export.

## Verification

```sh
node --test scripts/test-telemetry-distribution.mjs scripts/test-telemetry-stitch.mjs
```

The new functional tests exercise rotated-file reconstruction, reordered headers,
three-way overlap lineage, exact Int64 timestamps, gap/segment inspection and
actual CLI JSON/CSV creation, reopening and reanalysis through the existing
product distribution CLI. The existing distribution regressions also run.
This qualifies the focused Node workflow only. MoonBit compilation, native
consumers, cockpit, browser rendering, provider and hardware are not exercised.
