///|
/// Reject original arguments that have no implemented native meaning.
fn validate_options(
  entry : String,
  options : Map[String, String],
  flags : Array[String],
) -> Unit raise {
  let allowed : Array[String] = match entry {
    "aligned_export.py" =>
      [
        "--checkpoint", "--checkpoint-sha256", "--motion-dir", "--scene", "--report",
      ]
    "reference_initialization.py" =>
      [
        "--config", "--quality", "--references", "--feedback", "--scene", "--output",
      ]
    "reference_learning_study.py" =>
      [
        "--config", "--quality", "--references", "--actor", "--scene", "--output",
        "--reuse-study",
      ]
    "reference_learning_probe.py" => ["--study", "--method", "--offset"]
    "reference_root_decomposition.py" => ["--study"]
    "reference_last_cycle.py"
    | "reference_final_route_training.py"
    | "reference_gradient_route.py"
    | "reference_root_integration.py"
    | "reference_feedback_response.py" => ["--source", "--scene", "--output"]
    "reference_tail_directions.py" => ["--models", "--scene", "--output"]
    "reference_action_response.py" => ["--source", "--scene", "--output"]
    "reference_root_export.py"
    | "reference_feedback_response_export.py"
    | "reference_learning_export.py"
    | "reference_learning_export-final-verify.py" => ["--study", "--scene"]
    "reference_initialization_export.py" =>
      ["--study", "--references", "--scene"]
    "reference_registry_export.py" =>
      ["--study", "--references", "--verification", "--scene", "--output"]
    "reference_learning_registry_export.py" =>
      ["--study", "--verification", "--method", "--scene", "--output"]
    "full_body_reference_study.py" =>
      ["--config", "--collection", "--teacher-study", "--scene", "--output"]
    _ => fail("unmapped historical entry: " + entry)
  }
  for key, _ in options {
    guard key == "--library" || allowed.contains(key) else {
      fail("unsupported native option " + entry + ": " + key)
    }
  }
  guard flags.is_empty() ||
    (entry == "reference_action_response.py" && flags == ["--export"]) else {
    fail("unsupported native flags")
  }
}
