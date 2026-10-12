///|
/// Explicit user assertions. Both XY pairs must already use the same Cartesian
/// frame and units; this workflow never discovers or transforms either.
pub(all) struct PlanarRecipe {
  baseline_x : String
  baseline_y : String
  candidate_x : String
  candidate_y : String
  baseline_frame : String
  candidate_frame : String
  baseline_units : String
  candidate_units : String
  alignment : String
} derive(Debug, Eq, ToJson, FromJson)

///|
fn validate_planar_recipe(recipe : PlanarRecipe) -> Result[Unit, String] {
  if recipe.baseline_x == recipe.baseline_y ||
    recipe.candidate_x == recipe.candidate_y {
    return Err("select distinct X/Y channels for each recording")
  }
  for
    name in [
      recipe.baseline_x,
      recipe.baseline_y,
      recipe.candidate_x,
      recipe.candidate_y,
    ] {
    if !normalization_label_valid(name) {
      return Err("invalid coordinate channel: " + name)
    }
  }
  if recipe.baseline_frame.trim().is_empty() ||
    recipe.baseline_units.trim().is_empty() {
    return Err("explicit nonblank frame and units are required")
  }
  for label in [recipe.baseline_frame, recipe.baseline_units] {
    for c in label {
      if c.to_int() < 32 || c.to_int() == 65534 || c.to_int() == 65535 {
        return Err("frame and units must be printable labels")
      }
    }
  }
  if recipe.baseline_frame != recipe.candidate_frame ||
    recipe.baseline_units != recipe.candidate_units {
    return Err(
      "both XY pairs must explicitly declare identical frame and units; convert separately first",
    )
  }
  if recipe.alignment != "first-sample" &&
    recipe.alignment != "absolute-timestamp" {
    return Err("alignment must be first-sample or absolute-timestamp")
  }
  Ok(())
}

///|
pub fn parse_planar_recipe(text : String) -> Result[PlanarRecipe, String] {
  let json = @json.parse(text) catch {
    _ => return Err("recipe must be valid JSON")
  }
  match jsonl_unique_object_keys(text) {
    Err(message) => return Err("recipe: " + message)
    Ok(_) => ()
  }
  guard json is Object(fields) && fields.length() == 9 else {
    return Err(
      "recipe requires exactly baseline_x, baseline_y, candidate_x, candidate_y, baseline_frame, candidate_frame, baseline_units, candidate_units and alignment",
    )
  }
  let recipe : PlanarRecipe = @json.from_json(json) catch {
    _ => return Err("invalid planar recipe fields or types")
  }
  match validate_planar_recipe(recipe) {
    Err(message) => Err(message)
    Ok(_) => Ok(recipe)
  }
}
