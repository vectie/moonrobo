///|
/// Held-out one-step integration residuals, never fitted and never a release gate.
pub async fn run_model_consistency(
  study : String,
  provider_source : String,
) -> Json {
  let report = @artifacts.load_json(study + "/report.json")
  let config = json_field(report, "config")
  let results : Array[Json] = []
  for seed_value in json_array(json_field(config, "seeds")) {
    let seed = json_integer(seed_value)
    let prefix = study + "/model-based/seed-\{seed}/policy/dynamics-cycle-3"
    let model_path = if @fs.exists(prefix + ".json") {
      prefix + ".json"
    } else {
      prefix + ".pt"
    }
    let (model, metadata) = load_reference_dynamics(model_path)
    let fitted : Array[String] = @json.from_json(
      json_field(metadata, "training_episode_ids"),
    )
    let mut physics_joint = 0.0
    let mut learned_joint = 0.0
    let mut physics_root = 0.0
    let mut learned_root = 0.0
    let mut count = 0
    let ids : Array[String] = []
    for record in json_array(json_field(report, "physical_records")) {
      if json_text(json_field(record, "role")) != "model-diagnostic" ||
        json_integer(json_field(record, "seed")) != seed {
        continue
      }
      let id = json_text(json_field(record, "episode_id"))
      guard !fitted.contains(id) else { fail("model diagnostic was fitted") }
      let arrays = load_record_arrays(study, record)
      let state = numeric_matrix(arrays, "state")
      let action = numeric_matrix(arrays, "applied_action")
      let target = numeric_matrix(arrays, "next_state")
      let context : Array[Double] = @json.from_json(
        json_field(record, "context"),
      )
      for i, s in state {
        let predicted = model.predict(s, action[i], context)
        let actual_joint = trapezoid_residual(s, target[i])
        let model_joint = trapezoid_residual(s, predicted)
        let actual_root = trapezoid_residual(s, target[i], root=true)
        let model_root = trapezoid_residual(s, predicted, root=true)
        physics_joint += dot(actual_joint, actual_joint)
        learned_joint += dot(model_joint, model_joint)
        physics_root += dot(actual_root, actual_root)
        learned_root += dot(model_root, model_root)
        count += 1
      }
      ids.push(id)
    }
    guard count > 0 else { fail("no held-out model diagnostic transitions") }
    let actual = (physics_joint / (count * 29).to_double()).sqrt()
    let learned = (learned_joint / (count * 29).to_double()).sqrt()
    results.push({
      "seed": seed,
      "diagnostic_episode_ids": ids,
      "transitions": count,
      "physics_joint_trapezoid_residual_rmse_rad": actual,
      "model_joint_trapezoid_residual_rmse_rad": learned,
      "joint_residual_ratio": learned / actual.max(1.0e-12),
      "physics_root_trapezoid_residual_rmse_m": (physics_root /
      (count * 3).to_double()).sqrt(),
      "model_root_trapezoid_residual_rmse_m": (learned_root /
      (count * 3).to_double()).sqrt(),
      "model_sha256": source_digest(model_path),
    })
  }
  let result : Json = {
    "format": "moonrobo.g1-reference-model-consistency.v1",
    "results": results,
    "source_report_sha256": source_digest(study + "/report.json"),
    "provider_sha256": source_digest(provider_source),
    "scope": "Post-training held-out one-step integration diagnostic. No source-control labels or refitting. Residual ratios do not prove physical Jacobian accuracy or policy stability.",
    "physical_execution_allowed": false,
    "numeric_backend": "MoonBit Double; float32 Torch output parity remains a deferred test",
  }
  ignore(@artifacts.save_json(study + "/model-consistency.json", result))
  result
}
