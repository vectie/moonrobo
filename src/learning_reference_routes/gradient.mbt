///|
/// Paired full/stopped policy-input parameter gradients, strict logit-RMS calibration and actual physics returns.
pub async fn run_gradient_route(
  diagnostic_path : String,
  library : String,
  scene : String,
  output : String,
) -> Unit {
  let diagnostic_path = @fs.realpath(diagnostic_path)
  let output = @fs.realpath(output)
  let started = @async.now()
  let charter = @artifacts.load_json(output + "/config.json")
  verify_hash(
    diagnostic_path + "/report.json",
    text(charter, "diagnostic_report_sha256"),
  )
  let diagnostic = @artifacts.load_json(diagnostic_path + "/report.json")
  let action_path = @fs.realpath(text(diagnostic, "source_study"))
  verify_hash(
    action_path + "/report.json",
    text(diagnostic, "source_report_sha256"),
  )
  let action_report = @artifacts.load_json(action_path + "/report.json")
  let baseline_path = @fs.realpath(text(action_report, "source_study"))
  verify_hash(
    baseline_path + "/report.json",
    text(charter, "baseline_report_sha256"),
  )
  let baselines = @artifacts.load_json(baseline_path + "/report.json")
  let source = @fs.realpath(text(baselines, "source_study"))
  verify_hash(source + "/report.json", text(charter, "source_report_sha256"))
  let previous = @artifacts.load_json(source + "/report.json")
  let learning = merge(field(previous, "config"), { "actor_critic_tail": false })
  let config = merge(learning, charter)
  let references_path = @fs.realpath(text(baselines, "references"))
  let (manifest, references) = @reference.load_references(references_path)
  verify_hash(
    references_path + "/manifest.json",
    text(previous, "reference_manifest_sha256"),
  )
  let dt = number(field(manifest, "layout"), "dt_s")
  let runtime = @native_physics.Runtime::open(library, scene)
  let source_records = record_map(previous)
  let baseline_records = record_map(baselines)
  let methods : Array[String] = @json.from_json(field(charter, "methods"))
  let seeds : Array[Int32] = @json.from_json(field(charter, "seeds"))
  let gradient_routes : Array[String] = @json.from_json(
    field(charter, "gradient_routes"),
  )
  guard gradient_routes.contains("full") &&
    gradient_routes.contains("stop-policy-inputs") else {
    fail("gradient-route comparison requires both declared routes")
  }
  let clip_ids : Array[Int32] = @json.from_json(
    field(charter, "probe_clip_indices"),
  )
  let amplitudes : Array[Double] = @json.from_json(
    field(charter, "logit_rms_steps"),
  )
  let signs : Array[Double] = @json.from_json(field(charter, "probe_signs"))
  @fs.mkdir(output + "/directions", recursive=true)
  let records : Array[Json] = []
  let rows : Array[Json] = []
  let baseline_trials : Array[Json] = []
  let mut new_records = 0
  let mut reused_records = 0
  for method in methods {
    for seed in seeds {
      let original = @reference.select_run(previous, method, seed)
      let old = @reference.select_run(baselines, method, seed)
      let actor_path = child(baseline_path, text(old, "before_checkpoint"))
      let model_path = child(baseline_path, text(old, "model_checkpoint"))
      verify_hash(actor_path, text(old, "before_sha256"))
      verify_hash(model_path, text(old, "model_sha256"))
      let (actor, metadata) = @reference.load_reference_actor(actor_path)
      let geometry = @reference.kinematics_from_spec(metadata.kinematics)
      let (model, _) = @reference.load_reference_dynamics(model_path)
      let frozen_model = model.network.parameters.copy()
      let base_state = actor.to_json()
      let base = actor.parameters()
      let schedule = @reference.ReferenceSchedule::new(
        references.map(r => try! r.clip()),
        geometry,
        [0, 500, 1000],
        dt,
      )
      let cycles = array(original, "cycles")
      let training_ids : Array[String] = @json.from_json(
        field(cycles[cycles.length() - 1], "training_episode_ids"),
      )
      let training = @reference.restore_record_group(
        source,
        training_ids.map(id => source_records[id]),
        actor,
        schedule,
        number(learning, "gamma"),
      )
      let origin_ids = Sampler::new(
        integer(charter, "gradient_origin_seed_base") + seed,
        optional_adapter(config),
      ).indices(
        training.points.length(),
        integer(charter, "gradient_origin_samples"),
      )
      let calibration_ids = Sampler::new(
        integer(charter, "calibration_origin_seed_base") + seed,
        optional_adapter(config),
      ).indices(
        training.points.length(),
        integer(charter, "calibration_origin_samples"),
      )
      let gradient_batch = origin_ids.map(i => training.points[i])
      let calibration = calibration_ids.map(i => training.points[i])
      let (full_forward, full_active, full_gradient) = objective(
        model,
        actor,
        gradient_batch,
        geometry,
        schedule,
        learning,
        @reference.Full,
        true,
      )
      let (stopped_forward, stopped_active, stopped_gradient) = objective(
        model,
        actor,
        gradient_batch,
        geometry,
        schedule,
        learning,
        @reference.StopPolicyInputs,
        true,
      )
      guard full_forward == stopped_forward && full_active == stopped_active else {
        fail("backward-route ablation changed forward controller")
      }
      let full_norm = norm(full_gradient)
      let stopped_norm = norm(stopped_gradient)
      guard @numeric.finite(full_norm) &&
        @numeric.finite(stopped_norm) &&
        full_norm > 0 &&
        stopped_norm > 0 else {
        fail("invalid actor parameter direction")
      }
      let cosine = dot(full_gradient, stopped_gradient) /
        (full_norm * stopped_norm)
      let comparisons : Map[Int32, Json] = Map([])
      for comparison in array(old, "comparisons") {
        comparisons[integer(comparison, "clip_index")] = comparison
      }
      let baseline_returns : Array[Json] = []
      for clip in clip_ids {
        let comparison = comparisons[clip]
        let record = @reference.inherited_record(
          baseline_records[text(comparison, "before_episode_id")],
          baseline_path,
        )
        guard text(field(record, "behavior"), "sha256") ==
          text(old, "before_sha256") else {
          fail("baseline actor mismatch")
        }
        records.push(record)
        reused_records += 1
        baseline_trials.push(field(comparison, "before_trial"))
        baseline_returns.push(field(comparison, "actual_before"))
      }
      for route_string in gradient_routes {
        let feedback = route(route_string)
        let gradient = if feedback == @reference.Full {
          full_gradient
        } else {
          stopped_gradient
        }
        let gradient_norm = norm(gradient)
        let direction = gradient.map(v => v / gradient_norm)
        actor.set_parameters(base)
        let direction_path = output +
          "/directions/" +
          method +
          "-seed-" +
          seed.to_string() +
          "-" +
          route_string +
          ".moon.json"
        let direction_sha = save_direction(
          direction_path,
          actor,
          direction,
          text(old, "before_sha256"),
          {
            "gradient_route": route_string.to_json(),
            "gradient_norm": gradient_norm.to_json(),
          },
        )
        let initial_means = raw_means(actor, calibration, schedule)
        actor.set_parameters(
          Array::makei(base.length(), i => base[i] + 0.001 * direction[i]),
        )
        let response = rms_difference(
            raw_means(actor, calibration, schedule),
            initial_means,
          ) /
          0.001
        guard @numeric.finite(response) && response >= 0.00000001 else {
          fail("parameter direction has no calibration response")
        }
        actor.set_parameters(base)
        let outcomes : Array[Json] = []
        let all_trials : Array[Json] = []
        for amplitude in amplitudes {
          for sign in signs {
            let (coefficient, achieved, iterations) = @reference.calibrate_direction(
              base,
              direction,
              amplitude,
              sign,
              response,
              parameters => {
                actor.set_parameters(parameters)
                raw_means(actor, calibration, schedule)
              },
            )
            let (predicted_after, _, _) = objective(
              model,
              actor,
              gradient_batch,
              geometry,
              schedule,
              learning,
              @reference.Full,
              false,
            )
            let behavior : Json = {
              "checkpoint": actor_path.to_json(),
              "sha256": text(old, "before_sha256").to_json(),
              "direction_file": direction_path.to_json(),
              "direction_sha256": direction_sha.to_json(),
              "coefficient": coefficient.to_json(),
            }
            let role = "gradient-" +
              route_string +
              "-amp-" +
              amplitude.to_string() +
              "-sign-" +
              sign.to_string()
            let folder = output + "/" + method + "/seed-" + seed.to_string()
            let group = @reference.physical_group(
              runtime,
              references,
              schedule,
              actor,
              geometry,
              learning,
              seed,
              5,
              role,
              folder,
              output,
              behavior,
              [0],
              clip_ids,
              method,
            )
            records.append(group.records)
            all_trials.append(group.trials)
            new_records += group.records.length()
            let returns = physical_returns(
              group.batch,
              clip_ids,
              number(learning, "gamma"),
            )
            let mut prefix_change = 0.0
            let mut full_change = 0.0
            for i in 0..<returns.length() {
              prefix_change += number(returns[i], "prefix_return") -
                number(baseline_returns[i], "prefix_return")
              full_change += number(returns[i], "full_return") -
                number(baseline_returns[i], "full_return")
            }
            outcomes.push({
              "target_logit_rms": amplitude.to_json(),
              "achieved_logit_rms": achieved.to_json(),
              "sign": sign.to_json(),
              "coefficient": coefficient.to_json(),
              "calibration_iterations": iterations.to_json(),
              "predicted_after": predicted_after.to_json(),
              "predicted_change": (predicted_after - full_forward).to_json(),
              "trials": group.trials.to_json(),
              "returns": returns.to_json(),
              "mean_prefix_change": (prefix_change /
              returns.length().to_double()).to_json(),
              "mean_full_change": (full_change / returns.length().to_double()).to_json(),
            })
          }
        }
        actor.set_parameters(base)
        rows.push({
          "method": method.to_json(),
          "seed": seed.to_json(),
          "gradient_route": route_string.to_json(),
          "base_actor": actor_path.to_json(),
          "base_actor_sha256": text(old, "before_sha256").to_json(),
          "model_checkpoint": model_path.to_json(),
          "model_sha256": text(old, "model_sha256").to_json(),
          "training_episode_ids": training_ids.to_json(),
          "gradient_origin_indices": origin_ids.to_json(),
          "calibration_origin_indices": calibration_ids.to_json(),
          "equal_forward_objective": true,
          "forward_objective": full_forward.to_json(),
          "active_imagined_steps": full_active.to_json(),
          "gradient_norm": gradient_norm.to_json(),
          "route_gradient_cosine": cosine.to_json(),
          "full_gradient_projection": dot(full_gradient, direction).to_json(),
          "surrogate_gradient_projection": dot(stopped_gradient, direction).to_json(),
          "direction_file": direction_path.to_json(),
          "direction_sha256": direction_sha.to_json(),
          "outcomes": outcomes.to_json(),
          "trials": all_trials.to_json(),
          "baseline_returns": baseline_returns.to_json(),
        })
      }
      guard model.network.parameters == frozen_model &&
        actor.to_json() == base_state else {
        fail("gradient probe did not restore frozen base")
      }
    }
  }
  ignore(
    @artifacts.save_json(output + "/report.json", {
      "format": "moonrobo.moonbit-reference-gradient-route.v1",
      "config": config,
      "source_study": source.to_json(),
      "source_report_sha256": text(charter, "source_report_sha256").to_json(),
      "diagnostic_study": diagnostic_path.to_json(),
      "diagnostic_source_sha256": text(charter, "diagnostic_report_sha256").to_json(),
      "baseline_study": baseline_path.to_json(),
      "baseline_report_sha256": text(charter, "baseline_report_sha256").to_json(),
      "references": references_path.to_json(),
      "reference_manifest_sha256": field(previous, "reference_manifest_sha256"),
      "initial": {
        "role": "same-seed-cycle-5-starting-policies",
        "trials": baseline_trials.to_json(),
      },
      "runs": rows.to_json(),
      "physical_records": records.to_json(),
      "new_physical_records": new_records.to_json(),
      "reused_physical_records": reused_records.to_json(),
      "provider_seconds": ((@async.now() - started).to_double() / 1000).to_json(),
      "physical_execution_allowed": false,
      "release_qualified": false,
      "scope": field(charter, "budget_and_selection"),
    }),
  )
}
