///|
/// Explicit same-row channel roles and disjoint inclusive recorded windows.
/// Units are labels only; this recipe cannot authorize or calibrate hardware.
pub(all) struct AffineRecipe {
  predictor : String
  response : String
  predictor_unit : String
  response_unit : String
  output_channel : String
  fit_start_ms : Int64
  fit_end_ms : Int64
  holdout_start_ms : Int64
  holdout_end_ms : Int64
} derive(Debug, Eq, ToJson, FromJson)

///|
/// Unknown/duplicate fields fail. Millisecond fields use exact Int64 strings.
pub fn parse_affine_recipe(text : String) -> Result[AffineRecipe, String] {
  let value = @json.parse(text) catch {
    _ => return Err("recipe must be valid JSON")
  }
  match jsonl_unique_object_keys(text) {
    Err(message) => return Err("recipe: " + message)
    Ok(_) => ()
  }
  let keys = [
    "predictor", "response", "predictor_unit", "response_unit", "output_channel",
    "fit_start_ms", "fit_end_ms", "holdout_start_ms", "holdout_end_ms",
  ]
  guard value is Object(fields) && fields.length() == keys.length() else {
    return Err("recipe requires exactly the nine documented fields")
  }
  for key in fields.keys() {
    if !keys.contains(key) {
      return Err("unknown recipe field: " + key)
    }
  }
  let recipe : AffineRecipe = @json.from_json(value) catch {
    _ =>
      return Err(
        "invalid recipe types; millisecond fields must be Int64 strings",
      )
  }
  Ok(recipe)
}
