# Inspect a recorded GNSS RMC log

`telemetry_import_nmea` opens a local, checksummed GP/GN RMC recording, preserves
every parsed sentence and its status, and exports selected geographic position,
ground-speed and true-course channels into MoonRobo's numeric explorer and plot.
An editable recipe makes a missing channel visible and lets the operator choose
a different channel set without rewriting the recording.

This is an offline data-format bridge. It does not connect a receiver, alter
device configuration, establish receiver accuracy or datum, fuse measurements,
infer a travelled route, or grant control or physical readiness. Latitude and
longitude are geographic degrees: never pass them as Cartesian metres to the
trajectory, planar or path tools. A checksum detects some corruption; it does
not authenticate the source or prove that a receiver observed a real position.

## Run the complete synthetic journey

Build `cmd/telemetry_import_nmea`, `cmd/telemetry_csv` and `cmd/telemetry_plot`
using the pinned environment, private HOME/XDG, absolute external target, shared
native build lock, `--target native --strip -j 1`, and the 4 GiB reserve policy
in the accompanying R675 guide. Do not build into `source`.

The source-portable verification script accepts absolute source and built-target
directories, then creates a new output directory. It runs the actual native
programs, saves stdout/stderr, checks raw and recipe digests, edits a separate
recipe and reopens both exports. It never overwrites either source input.

```sh
moon run /absolute/source/scripts/verify_nmea_rmc_workflow.mbtx --target-dir /absolute/external-script-target -- /absolute/source /absolute/built-target /absolute/new-output
```

For manual use, substitute the actual executable paths. Run from the source
directory and send outputs to distinct new files; verify exit status before
consuming output. No command sends data to a provider.

```sh
/absolute/built-target/native/debug/build/cmd/telemetry_import_nmea/telemetry_import_nmea.exe examples/telemetry/nmea-rmc.nmea examples/telemetry/nmea-rmc.recipe.json > import.json
/absolute/built-target/native/debug/build/cmd/telemetry_import_nmea/telemetry_import_nmea.exe examples/telemetry/nmea-rmc.nmea examples/telemetry/nmea-rmc.recipe.json --csv > gnss.csv
/absolute/built-target/native/debug/build/cmd/telemetry_csv/telemetry_csv.exe gnss.csv > exploration.json
/absolute/built-target/native/debug/build/cmd/telemetry_plot/telemetry_plot.exe gnss.csv --channel gnss.speed.knots --unit knots --max-gap-ms 1000 --svg > speed.svg
```

The six synthetic sentences straddle UTC midnight into 2024-02-29. They mix GP
and GN talkers, contain one void fix with missing measurements and one active
fix with absent course. The initial recipe exports original lines 1, 2, 5 and 6.
Remove `course` from a copy of the recipe to inspect position and speed from
lines 1, 2, 4, 5 and 6. The void sentence remains excluded and inspectable.
Both plots have two segments at the demonstrated 1000 ms gap cutoff. That
cutoff is an example choice, not a universally appropriate recording cadence.
The synthetic course crosses 359° to 1°: it is circular, not a -358° physical
turn. No unwrap or interpolation is performed by the importer.

## Editable recipe

```json
{
  "year_century": 2000,
  "channels": ["latitude", "longitude", "speed", "course"],
  "row_policy": "eligible-only"
}
```

All three fields are required. Missing, duplicate, unknown fields and incorrect
types fail. `year_century` must have the exact mathematical decimal value 1900
or 2000; equivalent JSON spellings such as `2000.0` and `2e3` are accepted.
The original numeric token is checked before binary64 decoding can erase a
fractional tail, so `2000.00000000000001` is rejected. The chosen century adds
to the recorded two-digit year. There is no pivot-year rule, host-clock inference,
rollover correction or century guess. Review the recording's provenance before
choosing a century, and use separate imports across a century boundary.

`channels` is a nonempty, ordered, duplicate-free selection:

- `latitude` → `gnss.latitude.deg`: north positive, south negative
- `longitude` → `gnss.longitude.deg`: east positive, west negative
- `speed` → `gnss.speed.knots`: recorded speed over ground, no unit conversion
- `course` → `gnss.course.true_deg`: recorded true track angle in [0, 360)

`eligible-only` explicitly authorizes numerical row exclusion, while the report
retains all parsed rows and reasons. An eligible row requires recorded status
`A`, complete date and time, and all selected channels. A legacy sentence with
no position-mode field is eligible on that basis. If a mode field exists, only
`A`, `D`, `F` or `R` is eligible. Missing mode, `N`, `E`, `M`, `P` and `S` remain
visible but are excluded. These are import-policy categories, not certification
of fix quality, safety, or the truth of the producer's status labels.

Void (`V`) and empty statuses are retained and excluded. Missing measurements
are optional values, never zero-filled or copied forward. An absent unselected
channel does not prevent export. Every provided field is validated even if the
row or channel will be excluded. All-excluded input still produces an
inspectable JSON report; CSV export fails because no numeric observation exists.

## Deliberately narrow accepted format

Each nonempty line is one `$GPRMC` or `$GNRMC` sentence. Accept LF, CRLF, blank
lines and a missing final newline. No outer spaces, log prefixes, comments,
mixed sentence types, multipart input, tag blocks or other talker IDs. Source
line numbers refer to the original file, including blank lines.

The comma fields after the header are time, status, latitude, N/S, longitude,
E/W, speed, course, date, magnetic variation and E/W, with optionally one
position-mode field. Thus the body has exactly 12 or 13 comma fields including
the header. Newer layouts adding a navigation-status field are rejected, never
silently ignored. Null fields still need their delimiters.

Every sentence requires one `*HH` uppercase two-hex-digit checksum. Verify XOR
of the printable ASCII body between `$` and `*`, including commas, before
parsing. The implementation accepts up to 256 ASCII characters per sentence
as an explicit local bound, not an assertion of standard message-length
compliance. Unknown fields/layouts or checksums fail the entire import, including
late failures; the CLI never emits a partial JSON/CSV recording.

Latitude uses `ddmm[.fraction]`, longitude `dddmm[.fraction]`, with the appropriate
hemisphere. Minutes are below 60; the maxima ±90° and ±180° require zero minutes.
Nonempty decimal fields are unsigned, have 1–9 integer digits and optional 1–9
fractional digits, and accept no exponent, sign, `NaN`, or infinity. Coordinates
have their stricter fixed integer widths. Degree/minute conversion uses binary64
and may round. A missing coordinate requires both number and hemisphere empty;
partial pairs are malformed. Magnetic variation is retained as an optional
east-positive value bounded to ±180°, without changing true course.

UTC time is `hhmmss` with an optional 1–3 fractional digits. Date is `ddmmyy`
under the explicit century. Gregorian calendar validation covers 1970–2099;
timestamps before the Unix epoch are outside the numeric telemetry contract.
Convert calendar days and milliseconds with integer arithmetic and emit exact
Int64 decimal strings in JSON and decimal integers in CSV. Leap seconds,
`24:00`, and precision beyond milliseconds are rejected without truncation.
Missing date or time is retained and excludes a row; a supplied malformed
date/time fails. The clock is interpreted as recorded UTC, not independently
verified UTC or receiver freshness.

Exported timestamps must strictly increase. Never sort, merge duplicate fixes
or invent time from arrival order. Excluded sentences can repeat or move
backward in time and remain visible; they cannot become numeric observations.
The full recording is parsed before success. CLI limits are 4 MiB input and
64 KiB recipe, checked after local file read; processing is in memory rather
than streaming, so this is not a large-log service.

## Retain the inspection report

The native JSON envelope carries exact-byte SHA-256 for both input and recipe,
their paths, full raw text, the interpreted recipe, every original sentence,
source line numbers, nullable timestamp/measurements, recorded status/mode,
exclusion reasons, and the exported-row mapping. The pure API retains text and
structured lineage; file-byte hashes belong to the native envelope.

CSV deliberately contains only timestamp and selected numeric channels. Keep
raw input, recipe and JSON together so a filtered-out void interval cannot be
mistaken for continuous reception. A plot's gap cutoff must be chosen for the
recording; CSV alone does not carry an invalidity mask. Existing exploration
labels its timebase generically; the import report is the UTC interpretation.
Neither hashes nor imported observations substitute for MoonData ingestion,
robot/session/command identity, human review, physical proof or release gates.

Success exits 0. Input, recipe, layout and argument errors exit 2 with one JSON
error on stderr and empty stdout, including CSV mode. `--help` exits 0. Unknown,
duplicate or misplaced options fail. Original inputs are read-only.

## Format references and evidence boundary

This is a vendor-documented RMC subset, not an implementation or qualification
of the entire licensed NMEA 0183 standard. The following official references
were inspected on 2026-10-13:

- [Trimble R780 RMC](https://help.fieldsystems.trimble.com/r780/nmea0183-messages-rmc.htm)
  documents GP/GN talkers, UTC, active/void status, geographic coordinates,
  knots, true track angle, date and magnetic variation, and gives the classic
  `*6A` example used as an independent checksum/coordinate test vector.
- [Trimble message overview](https://help.fieldsystems.trimble.com/r780/nmea0183-messages-overview.htm)
  documents ASCII framing, null fields and XOR checksum coverage. Local text-file
  newline acceptance is an importer choice rather than a receiver wire protocol.
- [Trimble port configuration](https://help.fieldsystems.trimble.com/r980/help-io-config-configuration.htm)
  explains that a receiver can report an old position and time with appropriate
  status. The importer consequently keeps status and exclusions rather than
  interpreting every numeric coordinate as a current fix.
- [u-blox F9 HPS 1.30 interface description, UBX-22010984 R03](https://content.u-blox.com/sites/default/files/documents/u-blox-F9-HPS-1.30_InterfaceDescription_UBX-22010984.pdf)
  sections 2.5.3–2.5.6 (pages 24–26) and 2.7.17 (page 37) document degree/minute
  representation, position flags, empty invalid fields, `ddmmyy`, the optional
  position mode from NMEA 2.3, and added navigation status from NMEA 4.10.
  The last variant is intentionally unsupported here. A/D and F/R are recognized
  recorded GNSS-mode symbols, without inferring a receiver protocol version or
  accuracy. Other accepted one-letter modes are preserved and excluded by local
  policy. The receiver can select a datum, so the importer does not assume WGS84.

Tests cover the documented checksum vector, geographic signs/bounds, exact UTC,
leap/calendar boundaries, explicit century, missing/void/mode states, malformed
unselected values, late corruption, row ordering, strict recipes, native errors,
and reuse in the existing explorer and gap-aware plot. No GNSS hardware, NMEA
conformance lab, ROS bridge, provider, browser cockpit, physical accuracy or
production release was tested.
