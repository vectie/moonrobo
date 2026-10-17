///|
/// Persisted, editable selection recipe for repeated-event inspection.
pub(all) struct EventResponseRecipe {
  event_channel : String
  direction : String
  threshold : Double
  episodes : Array[Int]
  channels : Array[String]
  unit_labels : Array[String]
  before_ms : Int64
  after_ms : Int64
  step_ms : Int64
  event_min_span_ms : Int64
  event_max_gap_ms : Int64
  max_gap_ms : Int64
  overlap_policy : String
} derive(Debug, Eq, ToJson, FromJson)

///|
/// Unknown and duplicate keys fail; Int64 millisecond fields are JSON strings.
/// Selection and numeric constraints are checked by event_responses_csv.
pub fn parse_event_response_recipe(
  text : String,
) -> Result[EventResponseRecipe, String] {
  let json = @json.parse(text) catch {
    _ => return Err("recipe must be valid JSON")
  }
  match jsonl_unique_object_keys(text) {
    Err(message) => return Err("recipe: " + message)
    Ok(_) => ()
  }
  let keys = [
    "event_channel", "direction", "threshold", "episodes", "channels", "unit_labels",
    "before_ms", "after_ms", "step_ms", "event_min_span_ms", "event_max_gap_ms",
    "max_gap_ms", "overlap_policy",
  ]
  guard json is Object(fields) && fields.length() == keys.length() else {
    return Err("recipe requires exactly the 13 documented fields")
  }
  for key in fields.keys() {
    if !keys.contains(key) {
      return Err("unknown recipe field: " + key)
    }
  }
  let recipe : EventResponseRecipe = @json.from_json(json) catch {
    _ =>
      return Err(
        "invalid recipe fields or types; millisecond fields must be Int64 strings",
      )
  }
  Ok(recipe)
}
