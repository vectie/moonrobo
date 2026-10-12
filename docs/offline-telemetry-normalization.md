# Normalize an offline recording explicitly

Use `cmd/telemetry_normalize` before comparing differently named or scaled numeric
recordings. You supply every mapping and coefficient. This local operation never
infers units, calibration, coordinate-frame equivalence, device readiness or a
hardware outcome. A plausible-looking result is not physical validation.

## Synthetic example

Build the normalizer and existing consumers, then run the binaries at the paths
reported by your Moon version:

```sh
moon build cmd/telemetry_normalize cmd/telemetry_compare cmd/telemetry_path --target native
./_build/native/debug/build/cmd/telemetry_normalize/telemetry_normalize.exe examples/telemetry/normalize-raw.csv examples/telemetry/normalize-recipe.json > normalization.json
./_build/native/debug/build/cmd/telemetry_normalize/telemetry_normalize.exe examples/telemetry/normalize-raw.csv examples/telemetry/normalize-recipe.json --csv > normalized.csv
./_build/native/debug/build/cmd/telemetry_compare/telemetry_compare.exe examples/telemetry/normalize-baseline.csv normalized.csv > comparison.json
./_build/native/debug/build/cmd/telemetry_path/telemetry_path.exe normalized.csv x.m y.m --units m > trajectory.json
```

The three rows describe a synthetic 10 m route. The comparator finds three exact
elapsed-time pairs with zero position deltas and temperature rounding error near
machine precision. The CSV's original timestamps exceed JavaScript's exact
Number range; they remain exact Int64 values in the library and decimal text in
CSV. JSON encodes them as strings. The comparator separately aligns each run's
first sample to elapsed zero according to its existing contract.

## Recipe contract

The recipe is a JSON array. Every object requires exactly six fields:

```json
[{"source":"east_cm","target":"x.m","scale":0.01,"offset":0,"source_unit":"cm","target_unit":"m"}]
```

- `source` matches an input name exactly, after the existing CSV parser trims
  surrounding header whitespace. No guessed aliases or suffix interpretation.
- `target` is a nonempty unique final CSV name. No surrounding whitespace, comma,
  quote, CR or LF; `timestamp_ms` is reserved. Unicode names are supported.
- `scale` and `offset` are required finite numbers. The formula is
  `output = input * scale + offset`, using Double arithmetic. Negative and zero
  scales are allowed. Nonfinite inputs, coefficients and results are rejected.
  Finite rounding, underflow or lost precision are not calibration checks.
- `source_unit` and `target_unit` are required nonblank strings, retained exactly
  as supplied, including whitespace/escapes. Use an explicit label such as
  `unspecified` when needed. They are metadata only; misleading labels are not
  detected and no conversion is derived from them.
- Each source may be mapped once. Renames happen simultaneously, so swaps work.
  Collisions with either mapped or untouched columns fail. Unknown sources fail.
- All input columns and rows remain in original order. Unlisted columns retain
  their values and names; their unknown unit-label fields are omitted in JSON
  (`None` in the library). An empty recipe is
  explicit identity. There is no channel drop, reordering, resampling or time
  shift. Applying a recipe twice is a new transformation, not automatically
  detected or made idempotent.

Both entire files are loaded into memory. All rows and arithmetic are validated
before output. JSON is the default report (`moonrobo.telemetry-normalization.v1`),
with input/recipe path labels, formula, ordered source/target names, coefficients,
explicit-versus-passthrough flags, supplied unit labels and the output recording.
Keep the raw input, recipe and JSON together: CSV alone loses that provenance.
Paths are context labels, not content hashes or immutable evidence identities.
The report does not duplicate raw numeric values or raw CSV lexical formatting.

`--csv` emits a reusable numeric CSV for the existing explorer, comparator, merge
and trajectory APIs. Numeric spelling can change; integer timestamps cannot.
The existing unquoted CSV contract applies. Unknown/duplicate options, invalid
recipes or input produce a JSON error on stdout and exit 2, even in CSV mode;
success exits 0. Check exit status before treating redirected output as CSV.
The command writes only stdout and never overwrites inputs itself.

Library entry points are `parse_normalization_recipe`, `normalize_csv` and
`TelemetryNormalization::to_csv` in `src/telemetry_csv`. They perform no filesystem,
network, provider or bridge operations. Choose physically comparable source data
and review the recipe yourself before interpreting downstream differences.
