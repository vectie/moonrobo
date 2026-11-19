///|
async fn temporal_metadata(path : String) -> Json {
  if path.has_suffix(".pt") {
    let payload = @artifacts.load_torch_checkpoint(path)
    let base = torch_metadata(payload)
    guard base is Object(m) else { fail("invalid temporal metadata") }
    m["model_ref"] = payload.field("model_ref").plain_json()
    base
  } else {
    @artifacts.load_checkpoint(path, "temporal-actor").metadata
  }
}

///|
fn collect_temporal(
  runtime : @physics.Runtime,
  actor : @temporal.TemporalPolicy,
  experiment : Json,
  config : Json,
) -> (Array[Json], Array[Json]) raise {
  let origins : Array[Json] = []
  let omitted : Array[Json] = []
  let dt = num(config, "dt_s")
  let duration = num(experiment, "duration_s")
  let count = @math.round(duration / dt).to_int()
  let case_ids : Array[String] = @json.from_json(field(config, "case_ids"))
  for case_json in arr(experiment, "cases") {
    let case : @physics.Case = @json.from_json(case_json)
    if !case_ids.contains(case.id) {
      continue
    }
    if case.split != "train" ||
      !["stand", "random_joint_sines"].contains(case.motion) {
      fail("temporal probe accepts declared training motions only")
    }
    for seed in ints(config, "reset_seeds") {
      let rng = @numeric.Rng::new(seed.to_uint() + 1U)
      let names = runtime.joint_names()
      let schedule : @physics.JointSines? = if case.motion ==
        "random_joint_sines" {
        let limits = field(case_json, "goal_offset_rad")
        let stream = @numeric.Rng::new(seed.to_uint() + 2718U)
        let amplitudes = @physics.pose_offset(
          names,
          num(limits, "lower"),
          num(limits, "waist"),
          num(limits, "upper"),
          Array::make(names.length(), 1.0),
        )
        Some({
          amplitude: amplitudes.map(a => a * (0.3 + 0.7 * stream.uniform())),
          bias: amplitudes.map(a => a * (-0.2 + 0.4 * stream.uniform())),
          frequency_hz: names.map(_ => 0.15 + 0.5 * stream.uniform()),
          phase_rad: names.map(_ => -@math.PI + 2 * @math.PI * stream.uniform()),
        })
      } else {
        None
      }
      let history : Array[Array[Double]] = []
      let mut nominal : Array[Double] = []
      let mut index = 0
      let captured : Map[Int32, Json] = {}
      let predict = (obs : Array[Double], goal : Array[Double]) => {
        if history.is_empty() {
          nominal = Array::makei(goal.length(), i => obs[i])
          for _ in 0..<actor.temporal.history_length {
            history.push(obs.copy())
          }
        } else {
          ignore(history.remove(0))
          history.push(obs.copy())
        }
        let future = Array::makei(actor.temporal.future_length, i => {
          try! runtime.reference(
            nominal,
            case.motion,
            (index + i + 1).to_double() * dt,
            schedule?,
          )
        })
        index += 1
        actor.predict(history, goal, future)
      }
      let trace = (i : Int32, _ : Array[Double], _ : Array[Double]) => {
        if (try! ints(config, "snapshot_steps")).contains(i) {
          captured[i] = {
            "case": case_json,
            "reset_seed": seed,
            "start_step": i,
            "state": runtime.state(),
            "integration": runtime.integration(),
            "history": history.map(h => h.copy()),
            "nominal": nominal.copy(),
            "reference_schedule": schedule,
            "context": [case.friction, 1.0],
            "remaining_steps": count - i,
          }
        }
      }
      let (episode, _) = runtime.rollout(
        case,
        seed,
        "policy",
        duration,
        dt,
        () => rng.normal(),
        policy=predict,
        trace~,
        schedule?,
        fall_height=num(config, "fall_height_m"),
        fall_upright=num(config, "fall_upright_z"),
      )
      for start in ints(config, "snapshot_steps") {
        if captured.get(start) is Some(raw) {
          let end = if start + int(config, "horizon") > episode.steps.length() {
            episode.steps.length()
          } else {
            start + int(config, "horizon")
          }
          guard raw is Object(m) else { fail("invalid captured origin") }
          m["reference"] = Array::makei(end - start, i => {
            episode.steps[start + i]
          }).to_json()
          m["reference_full_steps"] = (episode.steps.length() - start).to_json()
          origins.push(raw)
        } else {
          omitted.push({
            "case": case.id,
            "reset_seed": seed,
            "start_step": start,
          })
        }
      }
    }
  }
  (origins, omitted)
}

///|
fn subset_ids(
  origins : Array[TemporalOrigin],
  subset : String,
) -> Array[Int32] raise {
  let ids : Array[Int32] = []
  for i, o in origins {
    let motion = str(field(o.raw, "case"), "motion")
    if subset == "all" ||
      (subset == "dynamic" && motion == "random_joint_sines") ||
      (subset == "stand" && motion == "stand") ||
      (subset == "late" && int(o.raw, "start_step") >= 100) {
      ids.push(i)
    }
  }
  ids
}

///|
/// Original temporal_probe.py study, including saved origins consumed by refit studies.
pub async fn run_temporal_probe(options : Map[String, String]) -> Unit {
  let experiment = read(option(options, "--experiment"))
  let config = merged(read(option(options, "--config")), {
    "dt_s": num(experiment, "control_dt_s"),
  })
  let model_path = option(options, "--dynamics")
  let (model, metadata) = load_dynamics(model_path)
  let model_sha = digest(model_path)
  let frozen = model.network.parameters.copy()
  let runtime = @physics.Runtime::open(
    option(options, "--library"),
    option(options, "--scene"),
  )
  let output = option(options, "--output")
  if !@fs.exists(output) {
    @fs.mkdir(output, recursive=true)
  }
  let records : Array[Json] = []
  let summaries : Array[Json] = []
  let origins_by_seed : Array[Json] = []
  let predictions : Array[Json] = []
  let bindings : Array[Json] = []
  let centered : Array[Json] = []
  let mut maximum_restore_error = 0.0
  for seed in ints(config, "policy_seeds") {
    let incoming_path = checkpoint_path(
      option(options, "--incoming"),
      "actor-seed-\{seed}",
    )
    let refined_path = checkpoint_path(
      option(options, "--refined"),
      "actor-seed-\{seed}",
    )
    let actor = @temporal.load_temporal(incoming_path)
    let refined = @temporal.load_temporal(refined_path)
    let actor_meta = temporal_metadata(incoming_path)
    let refined_meta = temporal_metadata(refined_path)
    let incoming_sha = digest(incoming_path)
    let initialization = field(refined_meta, "initialization")
    if str(initialization, "sha256") != incoming_sha ||
      str(initialization, "dynamics_sha256") != model_sha ||
      field(actor_meta, "model_ref") !=
      field(field(metadata, "layout"), "model_ref") ||
      num(field(metadata, "layout"), "dt_s") != num(config, "dt_s") {
      fail(
        "temporal checkpoint/dynamics origin differs from declared refinement",
      )
    }
    for
      (a, b) in [
        (actor.base.obs_stats, refined.base.obs_stats),
        (actor.base.goal_stats, refined.base.goal_stats),
      ] {
      if a.mean != b.mean || a.scale != b.scale {
        fail("selected refinement changed frozen normalization")
      }
    }
    if actor.base.lower != refined.base.lower ||
      actor.base.upper != refined.base.upper {
      fail("selected refinement changed action bounds")
    }
    let (raw_origins, omitted) = collect_temporal(
      runtime, actor, experiment, config,
    )
    if raw_origins.is_empty() {
      fail("no temporal origins")
    }
    let origins = raw_origins.map(raw => {
      temporal_origin(runtime, raw, actor, config)
    })
    let points = origins.map(o => temporal_point(o, config))
    let baselines : Array[Json] = []
    for o in origins {
      let (base, states, actions) = temporal_physical(runtime, o, actor, config)
      if int(base, "steps") != int(o.raw, "reference_full_steps") {
        fail("resumed temporal rollout length differs")
      }
      let a = max_error(states, o.reference.map(r => nums(r, "next_state")))
      let b = max_error(
        actions,
        o.reference.map(r => nums(r, "applied_action")),
      )
      let error = if a > b { a } else { b }
      if error > 0.00000001 {
        fail("resumed temporal trajectory differs")
      }
      if error > maximum_restore_error {
        maximum_restore_error = error
      }
      baselines.push(base)
    }
    let predicted_before = temporal_objective(
        model,
        actor,
        None,
        points,
        actor.parameters(),
        config,
        false,
      ).0
    let adam = temporal_direction(model, actor, None, points, config, false)
    let selected = refined.parameters()
    let original = actor.parameters()
    if selected.length() != original.length() {
      fail("refined architecture differs")
    }
    let actual = Array::makei(original.length(), i => selected[i] - original[i])
    let directions = @artifacts.Checkpoint::new(
      "parameter-direction-collection",
      {
        "incoming_sha256": incoming_sha,
        "refined_sha256": digest(refined_path),
        "config": config,
      },
    )
    directions.put("on_policy_adam", [adam.delta.length()], adam.delta)
    directions.put("selected_refinement", [actual.length()], actual)
    ignore(
      @artifacts.save_checkpoint(
        output + "/directions-seed-\{seed}.moon.json",
        directions,
      ),
    )
    predictions.push({
      "seed": seed,
      "records": open_loop(model, origins, config),
    })
    for
      (label, delta) in [
        ("on_policy_adam", adam.delta),
        ("selected_refinement", actual),
      ] {
      let nonzero = delta.any(v => v != 0)
      let by_scale : Map[String, Array[Json]] = {}
      let predicted_by_scale : Map[String, Array[Double]] = {}
      for multiplier in nums(config, "multipliers") {
        let next = temporal_candidate(actor, delta, multiplier)
        let predicted = temporal_objective(
            model,
            next,
            None,
            points,
            next.parameters(),
            config,
            false,
          ).0
        let outcomes = if multiplier != 0 && nonzero {
          origins.map(o => temporal_physical(runtime, o, next, config).0)
        } else {
          baselines
        }
        by_scale[multiplier.to_string()] = outcomes
        predicted_by_scale[multiplier.to_string()] = predicted
        for i, before in baselines {
          records.push({
            "seed": seed,
            "direction": label,
            "multiplier": multiplier,
            "origin": i,
            "predicted_before": predicted_before[i],
            "predicted_after": predicted[i],
            "baseline": before,
            "candidate": outcomes[i],
          })
        }
        for subset in ["all", "dynamic", "stand", "late"] {
          let ids = subset_ids(origins, subset)
          summaries.push({
            "seed": seed,
            "direction": label,
            "multiplier": multiplier,
            "subset": subset,
            "origins": ids.length(),
            "nonzero_direction": nonzero,
            "predicted_change": average(
              ids.map(i => predicted[i] - predicted_before[i]),
            ),
            "local_physical_change": average(
              ids.map(i => {
                num(outcomes[i], "local_return") -
                num(baselines[i], "local_return")
              }),
            ),
            "full_physical_change": average(
              ids.map(i => {
                num(outcomes[i], "full_return") -
                num(baselines[i], "full_return")
              }),
            ),
            "full_improves_fraction": average(
              ids.map(i => {
                if num(outcomes[i], "full_return") >
                  num(baselines[i], "full_return") {
                  1.0
                } else {
                  0.0
                }
              }),
            ),
            "mean_steps_change": average(
              ids.map(i => {
                (int(outcomes[i], "steps") - int(baselines[i], "steps")).to_double()
              }),
            ),
            "baseline_falls": ids
            .filter(i => boolean(baselines[i], "failed", false))
            .length(),
            "candidate_falls": ids
            .filter(i => boolean(outcomes[i], "failed", false))
            .length(),
          })
        }
      }
      let scale = num(config, "centered_scale")
      if scale <= 0 {
        fail("positive centered_scale required")
      }
      for i in 0..<origins.length() {
        let plus = by_scale[scale.to_string()][i]
        let minus = by_scale[(-scale).to_string()][i]
        centered.push({
          "seed": seed,
          "direction": label,
          "origin": i,
          "nonzero_direction": nonzero,
          "model_slope": (
            predicted_by_scale[scale.to_string()][i] -
            predicted_by_scale[(-scale).to_string()][i]
          ) /
          (2 * scale),
          "local_physics_slope": (
            num(plus, "local_return") - num(minus, "local_return")
          ) /
          (2 * scale),
          "full_physics_slope": (
            num(plus, "full_return") - num(minus, "full_return")
          ) /
          (2 * scale),
        })
      }
    }
    bindings.push({
      "seed": seed,
      "incoming_sha256": incoming_sha,
      "refined_sha256": digest(refined_path),
      "selected_update": field(refined_meta, "selected_update"),
      "history_length": actor.temporal.history_length,
      "future_length": actor.temporal.future_length,
      "actor_gradient_norm": adam.gradient_norm,
      "origins": origins.length(),
      "omitted": omitted,
    })
    origins_by_seed.push({ "seed": seed, "origins": raw_origins })
  }
  if model.network.parameters != frozen {
    fail("probe changed frozen world model")
  }
  let summary : Json = {
    "format": "moonrobo.g1-temporal-probe.v1",
    "config": config,
    "experiment": experiment,
    "bindings": bindings,
    "summaries": summaries,
    "centered": centered,
    "open_loop_predictions": predictions,
    "maximum_restore_error": maximum_restore_error,
    "dynamics_sha256": model_sha,
    "dynamics_training_batch_sha256": field(metadata, "training_batch_sha256"),
    "dynamics_unchanged": true,
    "physical_execution_allowed": false,
    "scope": "Training-only causal dynamic/control origins, fresh analytic Adam and actual selected refinement deltas, local H and remaining task physics returns; no value bootstrap or new selection. Native float64 and declared xorshift32 sampling await cross-runtime comparison.",
  }
  write(output + "/summary.json", summary)
  write(
    output + "/report.json",
    merged(summary, { "origins": origins_by_seed, "records": records }),
  )
  write(output + "/config.json", config)
}
