///|
/// Post-hoc decomposition of already tested directions. No fitting, new directions, or physics is performed by this command; the physical central secants remain finite-amplitude measurements.
pub async fn run_decomposition(
  study : String,
  provider_source : String,
) -> Json {
  let report = @artifacts.load_json(study + "/report.json")
  let source = text(report, "source_study")
  let source_report = @artifacts.load_json(source + "/report.json")
  let learning = field(source_report, "config")
  let (_, references) = @ref.load_references(text(report, "references"))
  let config = field(report, "config")
  let clips : Array[Int32] = @json.from_json(
    field(config, "probe_clip_indices"),
  )
  let amplitudes : Array[Double] = @json.from_json(
    field(config, "logit_rms_steps"),
  )
  let results : Array[Json] = []
  let initial_path = checkpoint_path(study + "/initial/actor-zero-output")
  for row in rows(report, "runs") {
    let (actor, metadata) = @ref.load_reference_actor(initial_path)
    let geometry = @ref.kinematics_from_spec(metadata.kinematics)
    let schedule = @ref.ReferenceSchedule::new(
      references.map(fn(r) { r.clip() }),
      geometry,
      [0],
      metadata.dt_s,
    )
    let training = archived_batch(
      source,
      rows(row, "training_records"),
      actor,
      schedule,
      number(learning, "gamma"),
    )
    let first = first_points(training)
    guard clips.all(fn(i) { i >= 0 && i < first.length() }) else {
      fail("decomposition probe origin absent")
    }
    let batch = clips.map(fn(i) { first[i] })
    let model_path = child(study, text(row, "checkpoint"))
    let (model, _) = @ref.load_reference_dynamics(
      model_path,
      expected_sha256=text(row, "checkpoint_sha256"),
    )
    let (value, _) = load_value(source, integer(row, "seed"), source_report)
    let raw_direction = @ref.load_parameter_direction(
      child(study, text(row, "direction_file")),
      text(row, "direction_sha256"),
      actor,
      digest(initial_path),
    )
    let response = number(row, "calibration_response")
    guard response >= 1.0e-8 else {
      fail("invalid existing calibration response")
    }
    let direction = raw_direction.map(fn(v) { v / response })
    let frozen_model = model_digest(model)
    let frozen_value = value_digest(value)
    let base = actor.parameters()
    let parts : Map[String, Json] = {}
    for name in ["prefix", "full"] {
      let critic = if name == "prefix" { None } else { Some(value) }
      let tape = @numeric.Tape::new()
      let bound = tape.vector(base)
      let (objective_value, active) = @ref.imagined_objective(
        tape,
        model,
        actor,
        bound,
        critic,
        batch,
        geometry,
        schedule,
        integer(learning, "imagination_horizon"),
        number(learning, "gamma"),
        feedback_gradient=if @ref.config_default(
            learning, "actor_feedback_gradient", "full",
          ) ==
          "stop-policy-inputs" {
          StopPolicyInputs
        } else {
          Full
        },
        critic_tail=true,
      )
      tape.backward(objective_value)
      let mut analytic = 0.0
      for i, p in bound {
        analytic += tape.gradient(p) * direction[i]
      }
      guard @numeric.finite(analytic) else {
        fail("nonfinite derivative decomposition")
      }
      let sweep : Array[Json] = []
      let mut numeric = 0.0
      for epsilon in [1.0e-6, 1.0e-7, 1.0e-8] {
        apply_direction(actor, base, direction, epsilon)
        let (plus, plus_active) = objective(
          model, actor, critic, batch, geometry, schedule, learning,
        )
        apply_direction(actor, base, direction, -epsilon)
        let (minus, minus_active) = objective(
          model, actor, critic, batch, geometry, schedule, learning,
        )
        actor.set_parameters(base)
        numeric = (plus - minus) / (2.0 * epsilon)
        sweep.push({
          "epsilon": epsilon.to_json(),
          "derivative": numeric.to_json(),
          "absolute_error": (analytic - numeric).abs().to_json(),
          "base_active_steps": active.to_json(),
          "plus_active_steps": plus_active.to_json(),
          "minus_active_steps": minus_active.to_json(),
        })
      }
      parts[name] = {
        "value": objective_value.value.to_json(),
        "derivative_per_raw_logit_rms": analytic.to_json(),
        "finite_difference_derivative": numeric.to_json(),
        "absolute_error": (analytic - numeric).abs().to_json(),
        "step_size_sweep": sweep.to_json(),
        "autodiff_consistent": ((analytic - numeric).abs() <
        1.0e-4 + 1.0e-3 * numeric.abs()).to_json(),
      }
    }
    let outcomes = rows(row, "outcomes")
    let secants : Array[Json] = []
    for amplitude in amplitudes {
      let plus = outcomes.filter(fn(o) {
        number(o, "sign") == 1.0 && number(o, "logit_rms_target") == amplitude
      })
      let minus = outcomes.filter(fn(o) {
        number(o, "sign") == -1.0 && number(o, "logit_rms_target") == amplitude
      })
      guard plus.length() == 1 && minus.length() == 1 && amplitude > 0.0 else {
        fail("missing or ambiguous existing physical central secants")
      }
      secants.push({
        "logit_rms_amplitude": amplitude.to_json(),
        "physical_prefix_secant": ((
          number(plus[0], "prefix_change_mean") -
          number(minus[0], "prefix_change_mean")
        ) /
        (2.0 * amplitude)).to_json(),
        "physical_full_secant": ((
          number(plus[0], "full_change_mean") -
          number(minus[0], "full_change_mean")
        ) /
        (2.0 * amplitude)).to_json(),
      })
    }
    guard model_digest(model) == frozen_model &&
      value_digest(value) == frozen_value &&
      actor.parameters() == base else {
      fail("decomposition mutated model/value or left actor perturbed")
    }
    results.push({
      "seed": field(row, "seed"),
      "variant": field(row, "variant"),
      "parts": parts.to_json(),
      "tail_derivative_per_raw_logit_rms": (number(
        parts["full"],
        "derivative_per_raw_logit_rms",
      ) -
      number(parts["prefix"], "derivative_per_raw_logit_rms")).to_json(),
      "physical_secants": secants.to_json(),
      "frozen_model_value_unchanged": true,
      "model_sha256": digest(model_path).to_json(),
      "direction_sha256": field(row, "direction_sha256"),
    })
  }
  let result : Json = {
    "format": "moonrobo.g1-reference-root-decomposition.v1",
    "results": results.to_json(),
    "source_report_sha256": digest(study + "/report.json").to_json(),
    "provider_sha256": digest(provider_source).to_json(),
    "scope": "Post-hoc decomposition of existing directions on three known reset clips. Finite physical secants are not exact derivatives. No tail-free actor direction was physically tested.",
    "physical_execution_allowed": false,
    "numerical_backend": "moonbit-float64",
    "parity_verified": false,
  }
  ignore(@artifacts.save_json(study + "/gradient-decomposition.json", result))
  result
}
