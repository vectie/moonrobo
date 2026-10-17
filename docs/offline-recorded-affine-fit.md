# Fit a recorded relationship, then inspect held-out rows

An integration engineer comparing two numeric channels can select a fit window,
inspect an affine relationship, and evaluate it on a separate recorded window.
Export the residuals into the existing telemetry plot, revise the windows, or
export a candidate recipe for the existing explicit normalizer.

The normalizer already accepts supplied coefficients, tracking-error reports
same-row differences, and lag scans compare shifted shapes. None of those steps
estimates an affine relationship while keeping a separate holdout and exporting
the selected candidate into the native normalization workflow.

This is a narrow recorded-data inspection slice contextual to MR-W04/B06. It
does not complete those cockpit requirements, B07 MoonData proof or physical
calibration. The selected response is a caller-declared comparison channel,
not certified ground truth. No device, bridge, control, clock calibration,
readiness, trial grant or hardware qualification is involved.

## Complete synthetic journey

`examples/telemetry/affine-recording.csv` contains eight synthetic rows. The first
four fit `reference.n = 2 * sensor.raw + 1`. The three holdout rows have residuals
1, -1 and 2 N. The final row is outside both windows and is retained in source
provenance and the normalization output. It never enters the fit or summaries.

Build `cmd/telemetry_affine`, `cmd/telemetry_normalize` and `cmd/telemetry_plot`
with the native target. Use the binary locations reported by your Moon toolchain:

```sh
telemetry_affine examples/telemetry/affine-recording.csv examples/telemetry/affine-recording.recipe.json > affine.json
telemetry_affine examples/telemetry/affine-recording.csv examples/telemetry/affine-recording.recipe.json --format holdout-csv > holdout.csv
telemetry_plot holdout.csv --channel residual --unit N --max-gap-ms 100 --svg > holdout.svg
telemetry_affine examples/telemetry/affine-recording.csv examples/telemetry/affine-recording.recipe.json --format normalization-recipe > candidate.json
telemetry_normalize examples/telemetry/affine-recording.csv candidate.json > normalized.json
telemetry_normalize examples/telemetry/affine-recording.csv candidate.json --csv > normalized.csv
telemetry_plot normalized.csv --channel predicted.n --unit N --channel reference.n --unit N --max-gap-ms 100 --svg > normalized.svg
```

The initial fit has scale 2 and offset 1 within binary64 rounding. The held-out
bias is 2/3 N, MAE is 4/3 N, RMSE is sqrt(2) N and maximum absolute residual is
2 N. The holdout predictor 4 is outside the fit predictor range [0,3]; it is
explicitly flagged as extrapolation, without clipping or an acceptance verdict.

Copy the recipe and exchange the two windows: fit 2000–2200 ms and hold out
1000–1300 ms. Running that edited recipe yields scale 2.5 and offset 0.5. This
illustrates sensitivity to the chosen rows, not an improvement claim. If you
repeatedly tune against the holdout, it ceases to be independently held out.

`scripts/verify_affine_workflow.mbtx ABSOLUTE_SOURCE ABSOLUTE_TARGET NEW_OUTPUT`
runs this entire journey against actual native binaries, saves JSON/CSV/SVG and
stdout/stderr, edits the recipe and exercises eight CLI negative cases. It
does not compile, contact a provider or modify inputs. Give it absolute paths.

## Recipe and data contract

All nine fields shown in `affine-recording.recipe.json` are required. Unknown,
duplicate, missing and incorrectly typed fields fail. The four timestamp fields
are exact nonnegative Int64 decimal strings; windows are inclusive and must be
disjoint even at their endpoints. Holdout can precede fit. At least three fit
rows and one holdout row are required. No random split or auto-selection occurs.

- `predictor` and `response` select different existing channels from one CSV.
- `predictor_unit` and `response_unit` are explicit nonblank labels; no units
  are inferred, converted or checked for physical compatibility.
- `output_channel` must be a new valid unquoted CSV name. Existing names,
  `timestamp_ms`, commas, quotes, newlines and surrounding whitespace fail.
- All original CSV rows and channels are validated, including excluded rows.
  Existing strict numeric CSV rules apply: complete finite numeric cells,
  strictly increasing nonnegative Int64 times, unique channel names, no quoted
  cells. Blank lines and CRLF are accepted. No interpolation or gap filling.
- The native CLI accepts at most 4 MiB of input and 64 KiB of recipe, validates
  UTF-8 strictly and writes only stdout. Files are read before the caps are
  checked, so this is not a streaming-memory limit. Use new output paths and
  inspect exit status; redirecting onto the input would truncate it in the shell.
- Success/help exit 0. Any error exits 2 with JSON on stderr and empty stdout.
  The existing normalizer has its own contract: errors go to stdout, exit 2.

## Meaning and numerical limits

Ordinary least squares with intercept minimizes the sum of squared response
residuals over the fit rows. Each observation gets equal weight irrespective of
irregular cadence. Residual = observed response - (predictor * scale + offset).
Fit and holdout summaries independently report signed bias, MAE, RMSE, maximum
absolute residual, sample count and count outside the fit predictor range.

The algorithm scales both columns, centers the scaled values and scales the
centered predictor again, using compensated means to reduce avoidable sum/square
overflow. A constant predictor is unidentifiable and fails; a constant response
can produce scale zero. Tiny unresolved predictor variation fails. Coefficients,
predictions and residuals must be finite. The candidate is evaluated using the
existing normalizer's exact `input * scale + offset` arithmetic, including all
excluded input rows, before any report is emitted. An overflow anywhere fails.

All arithmetic remains binary64. Extreme dynamic ranges can underflow, and
near-constant predictors, large offsets and cancellation can make a fitted
relationship unreliable. Some intermediate overflow may reject an otherwise
representable mathematical result. There is no arbitrary-precision, confidence
interval, robust regression, uncertainty, causation, fit-quality threshold or
physical calibration claim. No outlier is silently dropped. Same-row values do
not establish simultaneous physical acquisition. Sampling density can bias a
sample-weighted summary, and holdout extrapolation is not validated prediction.

## Preserve provenance and make application a separate choice

Default JSON is `moonrobo.recorded-affine-file.v1`; it binds exact input and
recipe bytes by SHA-256 and includes the versioned fit method, recipe, all raw
parsed source rows, fitted coefficients, domain bounds, selected original sample
indices, exact timestamps, observed/predicted values, residuals and summaries.
Hashes identify content, not authenticity, a robot/session, a command or truth.

`fit-csv` and `holdout-csv` export only their own rows, retaining exact timestamps
with fixed columns `predictor,observed,predicted,residual`. Keep JSON, recipe and
raw input beside them; CSV alone omits roles, original indices, units and hashes.
There is no combined export that silently joins the two selected windows.

`normalization-recipe` produces the existing six-field mapping array. Applying
it explicitly renames/replaces the predictor column with `output_channel`,
preserves all other columns and every timestamp, and transforms the entire input,
including excluded rows. Preserve the raw file separately. The tool never applies
the recipe to another recording or hardware. A second dataset needs its own
review; a holdout score here is no promise of generalization.

Public entry points: `parse_affine_recipe`, `fit_affine_csv`,
`AffineFit::residual_csv` and `AffineFit::normalization_recipe`. Export methods
expect the unmodified successful result. Arbitrarily constructed/mutated public
records are not a trusted report import. Library functions have no I/O.

## Verification scope

Focused tests cover hand calculations, separate holdout, edited windows,
constants, negative slope, malformed inputs/recipes, output collisions,
exact Int64 times, irregular cadence, extreme finite values, overflow, exports
and the actual normalizer arithmetic. Native CLI verification reopens exports
with the existing native plot and produces structurally checked SVG files.

The inherited full-module all-target host_api/native-only design_workbench
dependency blocker remains. Physical, SDK, cockpit/browser, release, installed
distribution and SVG pixel-rendering qualification are not claimed. The known
missing SVG rendering dependency was not bypassed or retried with Chromium.
