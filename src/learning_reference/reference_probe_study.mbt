///|
pub async fn run_imagination_probe(
  study : String,
  method_name : String,
  offset : Int32,
) -> Json {
  let report = @artifacts.load_json(study + "/report.json")
  let charter = @artifacts.load_json(study + "/charter.json")
  let config = json_field(report, "config")
  let selected = select_run(report, method_name, 0)
  let checkpoint = json_field(selected, "checkpoint")
  let path = path_child(study, json_text(json_field(checkpoint, "checkpoint")))
  let (actor, metadata) = load_reference_actor(
    path,
    expected_sha256=json_text(json_field(checkpoint, "sha256")),
  )
  let cycles = json_array(json_field(selected, "cycles"))
  let cycle = json_integer(json_field(cycles[cycles.length() - 1], "cycle"))
  let (model, _) = load_reference_dynamics(
    sibling_checkpoint(path, "dynamics", cycle),
  )
  let value = load_reference_value(sibling_checkpoint(path, "value", cycle))
  let references_path = json_text(json_field(charter, "references"))
  let (_, references) = load_references(references_path)
  let geometry = kinematics_from_spec(metadata.kinematics)
  let mut record = Json::null()
  for item in json_array(json_field(report, "physical_records")) {
    if json_text(json_field(item, "role")) == "common-first-collection" &&
      json_integer(json_field(item, "seed")) == 0 &&
      json_integer(json_field(item, "clip_index")) == 0 {
      record = item
      break
    }
  }
  let origin = json_integer(json_field(record, "origin_step"))
  let schedule = ReferenceSchedule::new(
    references.map(reference => reference.clip()),
    geometry,
    [origin],
    metadata.dt_s,
  )
  let batch = restore_record_group(
    study,
    [record],
    actor,
    schedule,
    json_number(json_field(config, "gamma")),
  )
  guard offset >= 0 && offset < batch.points.length() else {
    fail("probe offset outside physical episode")
  }
  let points = [batch.points[offset]]
  let tail = method_name == "model-based"
  let horizon = json_integer(json_field(config, "imagination_horizon"))
  let gamma = json_number(json_field(config, "gamma"))
  let model_before = model.checkpoint(Json::null()).to_json()
  let value_before = value.to_json()
  let base = actor.parameters()
  let tape = @numeric.Tape::new()
  let parameters = tape.vector(base)
  let (objective, _) = imagined_objective(
    tape,
    model,
    actor,
    parameters,
    Some(value),
    points,
    geometry,
    schedule,
    horizon,
    gamma,
    critic_tail=tail,
  )
  tape.backward(objective)
  let start = parameters.length() - actor.nu
  let gradient = parameters[start:].map(parameter => tape.gradient(parameter))
  let direction = Array::makei(actor.nu, i => {
    -1.0 + 2.0 * i.to_double() / (actor.nu - 1).to_double()
  })
  let epsilon = 0.000001
  let evaluate = (sign : Double) => {
    let values = base.copy()
    for i in 0..<actor.nu {
      values[start + i] += sign * epsilon * direction[i]
    }
    actor.set_parameters(values)
    let t = @numeric.Tape::new()
    imagined_objective(
      t,
      model,
      actor,
      t.vector(values),
      Some(value),
      points,
      geometry,
      schedule,
      horizon,
      gamma,
      critic_tail=tail,
    ).0.value
  }
  let plus = evaluate(1.0)
  let minus = evaluate(-1.0)
  actor.set_parameters(base)
  let analytic = dot(gradient, direction)
  let numeric = (plus - minus) / (2.0 * epsilon)
  let unchanged = model_before == model.checkpoint(Json::null()).to_json() &&
    value_before == value.to_json()
  let passed = gradient.all(value => finite(value)) &&
    dot(gradient, gradient) > 0.0 &&
    autodiff_consistent(analytic, numeric) &&
    unchanged
  let result : Json = {
    "format": "moonrobo.g1-reference-imagination-gradient.v1",
    "passed": passed,
    "method": method_name,
    "source_record": json_field(record, "episode_id"),
    "source_offset_steps": offset,
    "checkpoint_cycle": cycle,
    "horizon": horizon,
    "precision": "float64 check of float32 learned artifacts and recorded origin",
    "analytic_directional": analytic,
    "finite_difference_directional": numeric,
    "absolute_error": (analytic - numeric).abs(),
    "gradient_norm": dot(gradient, gradient).sqrt(),
    "frozen_model_value_unchanged": unchanged,
    "critic_tail_used": tail,
    "scope": "Autodiff consistency through world model, restored policy history and causal EMA" +
    (if tail {
      " and physical-return critic tail"
    } else {
      " with no critic tail"
    }) +
    "; not a physical-Jacobian accuracy test",
    "physical_execution_allowed": false,
  }
  let name = if method_name == "model-based" {
    "gradient-verification.json"
  } else {
    "gradient-verification-\{method_name}.json"
  }
  ignore(@artifacts.save_json(study + "/" + name, result))
  result
}
