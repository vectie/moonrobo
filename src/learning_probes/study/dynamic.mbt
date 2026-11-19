///|
fn refit_compare(
  runtime : @physics.Runtime,
  model : @training.Dynamics,
  actor : @temporal.TemporalPolicy,
  origins : Array[TemporalOrigin],
  baselines : Array[Json],
  config : Json,
) -> (Json, Array[Double]) raise {
  let points = origins.map(o => temporal_point(o, config))
  let before = temporal_objective(
      model,
      actor,
      None,
      points,
      actor.parameters(),
      config,
      false,
    ).0
  let update = temporal_direction(model, actor, None, points, config, false)
  let outcomes : Map[String, Array[Json]] = {}
  let predicted : Map[String, Array[Double]] = {}
  let records : Array[Json] = []
  for scale in nums(config, "multipliers") {
    let next = temporal_candidate(actor, update.delta, scale)
    predicted[scale.to_string()] = temporal_objective(
        model,
        next,
        None,
        points,
        next.parameters(),
        config,
        false,
      ).0
    let values : Array[Json] = []
    for i, o in origins {
      let outcome = if scale == 0 {
        baselines[i]
      } else {
        temporal_physical(runtime, o, next, config).0
      }
      values.push(outcome)
      records.push({
        "multiplier": scale,
        "origin": i,
        "predicted_before": before[i],
        "predicted_after": predicted[scale.to_string()][i],
        "baseline": baselines[i],
        "candidate": outcome,
      })
    }
    outcomes[scale.to_string()] = values
  }
  let summaries : Array[Json] = []
  let center = num(config, "centered_scale")
  if center <= 0 {
    fail("positive centered_scale required")
  }
  for subset in ["all", "dynamic", "stand", "late"] {
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
    let slopes = ids.map(i => {
      (predicted[center.to_string()][i] - predicted[(-center).to_string()][i]) /
      (2 * center)
    })
    let row : Json = {
      "subset": subset,
      "origins": ids.length(),
      "gradient_norm": update.gradient_norm,
      "predicted_change": average(
        ids.map(i => predicted[1.0.to_string()][i] - before[i]),
      ),
      "local_physical_change": average(
        ids.map(i => {
          num(outcomes[1.0.to_string()][i], "local_return") -
          num(baselines[i], "local_return")
        }),
      ),
      "full_physical_change": average(
        ids.map(i => {
          num(outcomes[1.0.to_string()][i], "full_return") -
          num(baselines[i], "full_return")
        }),
      ),
      "mean_steps_change": average(
        ids.map(i => {
          (int(outcomes[1.0.to_string()][i], "steps") -
          int(baselines[i], "steps")).to_double()
        }),
      ),
      "full_improves_fraction": average(
        ids.map(i => {
          if num(outcomes[1.0.to_string()][i], "full_return") >
            num(baselines[i], "full_return") {
            1.0
          } else {
            0.0
          }
        }),
      ),
      "centered_model_slope": average(slopes),
    }
    if row is Object(m) {
      for key in ["local_return", "full_return"] {
        let physical_slopes = ids.map(i => {
          (
            num(outcomes[center.to_string()][i], key) -
            num(outcomes[(-center).to_string()][i], key)
          ) /
          (2 * center)
        })
        let mut denominator = 0
        let mut agree = 0
        for j in 0..<ids.length() {
          if slopes[j].abs() > 1.0e-5 && physical_slopes[j].abs() > 1.0e-5 {
            denominator += 1
            if slopes[j] * physical_slopes[j] > 0 {
              agree += 1
            }
          }
        }
        m["centered_" + key] = average(physical_slopes).to_json()
        m["sign_" + key] = { "denominator": denominator, "agree": agree }
      }
    }
    summaries.push(row)
  }
  (
    {
      "summaries": summaries,
      "records": records,
      "open_loop_predictions": open_loop(model, origins, config),
    },
    update.delta,
  )
}

///|
/// Refit models reuse original bound physical origins, policy artifacts and baselines.
pub async fn run_dynamic_refit(options : Map[String, String]) -> Unit {
  let probe = option(options, "--probe")
  let study = option(options, "--study")
  let output = option(options, "--output")
  if !@fs.exists(output) {
    @fs.mkdir(output, recursive=true)
  }
  let config = merged(read(probe + "/config.json"), { "dt_s": 0.02 })
  let runtime = @physics.Runtime::open(
    option(options, "--library"),
    option(options, "--scene"),
  )
  let initial_path = option(options, "--initial")
  let (initial, _) = load_dynamics(initial_path)
  let initial_sha = digest(initial_path)
  let prior : Map[String, Json] = {}
  let prior_digests : Map[String, String] = {}
  for method in ["frame", "preview"] {
    let path = probe + "/" + method + "/report.json"
    let report = read(path)
    if str(report, "dynamics_sha256") != initial_sha ||
      num(report, "maximum_restore_error") > 0.00000001 {
      fail("dynamic refit origins do not match original physics probe")
    }
    prior[method] = report
    prior_digests[method] = digest(path)
  }
  let results : Array[Json] = []
  let rows : Array[Json] = []
  let latest_predictions : Array[Json] = []
  for arm in ["old-only", "mixed"] {
    for fit_seed in [0, 1, 2] {
      let path = checkpoint_path(study + "/" + arm, "dynamics-seed-\{fit_seed}")
      let latest_path = checkpoint_path(
        study + "/" + arm,
        "latest-dynamics-seed-\{fit_seed}",
      )
      let (model, metadata) = load_dynamics(path)
      let (latest, latest_metadata) = load_dynamics(latest_path)
      if str(
          field(field(metadata, "config"), "refit"),
          "initial_dynamics_sha256",
        ) !=
        initial_sha {
        fail("refit does not originate from this model")
      }
      for
        (a, b) in [
          (model.state_stats, initial.state_stats),
          (model.action_stats, initial.action_stats),
          (model.context_stats, initial.context_stats),
        ] {
        if a.mean != b.mean || a.scale != b.scale {
          fail("refit prediction scale differs")
        }
      }
      let frozen = model.network.parameters.copy()
      for method in ["frame", "preview"] {
        let old = prior[method]
        for group in arr(old, "origins") {
          let seed = int(group, "seed")
          let actor_path = checkpoint_path(
            option(options, "--policies") + "/" + method + "/policy",
            "actor-seed-\{seed}",
          )
          guard arr(old, "bindings").filter(r => int(r, "seed") == seed).get(0)
            is Some(binding) else {
            fail("missing incoming actor binding")
          }
          if digest(actor_path) != str(binding, "incoming_sha256") {
            fail("probe incoming actor differs")
          }
          let actor = @temporal.load_temporal(actor_path)
          let origins = arr(group, "origins").map(raw => {
            temporal_origin(runtime, raw, actor, config)
          })
          latest_predictions.push({
            "arm": arm,
            "fit_seed": fit_seed,
            "method": method,
            "policy_seed": seed,
            "update": field(latest_metadata, "selected_update"),
            "checkpoint_sha256": digest(latest_path),
            "records": open_loop(latest, origins, config),
          })
          let zero = arr(old, "records").filter(r => {
            int(r, "seed") == seed &&
            str(r, "direction") == "on_policy_adam" &&
            num(r, "multiplier") == 0
          })
          let baselines : Array[Json] = []
          for i in 0..<origins.length() {
            guard zero.filter(r => int(r, "origin") == i).get(0) is Some(row) else {
              fail("missing paired physical baseline")
            }
            baselines.push(field(row, "baseline"))
          }
          let (comparison, delta) = refit_compare(
            runtime, model, actor, origins, baselines, config,
          )
          let key : Json = {
            "arm": arm,
            "fit_seed": fit_seed,
            "method": method,
            "policy_seed": seed,
            "selected_model_update": field(metadata, "selected_update"),
            "checkpoint_sha256": digest(path),
          }
          results.push(merged(key, comparison))
          for row in arr(comparison, "summaries") {
            rows.push(merged(key, row))
          }
          let checkpoint = @artifacts.Checkpoint::new(
            "parameter-direction",
            merged(key, { "actor_sha256": digest(actor_path) }),
          )
          checkpoint.put("parameters", [delta.length()], delta)
          ignore(
            @artifacts.save_checkpoint(
              output +
              "/direction-\{arm}-\{fit_seed}-\{method}-\{seed}.moon.json",
              checkpoint,
            ),
          )
        }
      }
      if model.network.parameters != frozen {
        fail("refit probe changed frozen model")
      }
    }
  }
  let summary : Json = {
    "format": "moonrobo.g1-dynamic-refit-probe.v1",
    "config": config,
    "summaries": rows,
    "original_probe_sha256": prior_digests,
    "initial_dynamics_sha256": initial_sha,
    "dynamics_unchanged": true,
    "physical_execution_allowed": false,
    "scope": "Same saved bound training origins, incoming temporal actors and fixed normalization. Native float64 analytic Adam directions; physical full returns stop at fall/original end. No policy selection.",
  }
  write(output + "/summary.json", summary)
  write(
    output + "/report.json",
    merged(summary, {
      "results": results,
      "latest_predictions": latest_predictions,
    }),
  )
}
