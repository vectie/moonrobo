///|
/// Residual CSV preserves exact recorded timestamps and only the chosen partition.
/// Keep the JSON and raw input beside it for original identities and unit labels.
pub fn AffineFit::residual_csv(
  self : AffineFit,
  partition : String,
) -> Result[String, String] {
  if partition != "fit" && partition != "holdout" {
    return Err("partition must be fit or holdout")
  }
  let output = StringBuilder::new()
  output.write_string("timestamp_ms,predictor,observed,predicted,residual\n")
  for row in self.rows {
    if row.partition == partition {
      output.write_string(
        "\{row.timestamp_ms},\{row.predictor},\{row.observed},\{row.predicted},\{row.residual}\n",
      )
    }
  }
  Ok(output.to_string())
}

///|
/// Export an explicit recipe consumed by normalize_csv / telemetry_normalize.
/// Applying it is a separate caller decision. The source predictor is renamed.
pub fn AffineFit::normalization_recipe(
  self : AffineFit,
) -> Array[ChannelMapping] {
  [
    {
      source: self.recipe.predictor,
      target: self.recipe.output_channel,
      scale: self.scale,
      offset: self.offset,
      source_unit: self.recipe.predictor_unit,
      target_unit: self.recipe.response_unit,
    },
  ]
}
