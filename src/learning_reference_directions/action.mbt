///|
fn replay_snapshots(
  runtime : @physics.Runtime,
  reference : @ref.ReferenceArchive,
  case : Json,
  arrays : Map[String, @artifacts.NumericArray],
  offsets : Array[Int32],
  count : Int32,
  dt : Double,
) -> (Map[Int32, Snapshot], Int32) raise {
  runtime.reset_data()
  runtime.set_friction(number(case, "friction"))
  runtime.set_integration(reference.matrix("integration")[0])
  let states = matrix(arrays, "state")
  let next = matrix(arrays, "next_state")
  let controls = matrix(arrays, "applied_action")
  let available = offsets.filter(o => o >= 0 && o + count <= states.length())
  let mut end = 0
  for o in available {
    if o + count > end {
      end = o + count
    }
  }
  let snapshots : Map[Int32, Snapshot] = {}
  let (_, _, _, nu) = runtime.dimensions()
  let mut previous = last_previous(reference.matrix("observation")[0], nu)
  let substeps = runtime.control_substeps(dt)
  for i in 0..<end {
    let actual = runtime.state()
    exact_source(
      actual,
      states[i],
      tensor(arrays, "state").dtype,
      "source control replay differs before snapshot",
    )
    if available.contains(i) {
      let observation = if i == 0 {
        reference.matrix("observation")[0].copy()
      } else {
        runtime.observation(previous)
      }
      snapshots[i] = {
        integration: runtime.integration(),
        state: actual,
        observation,
        actions: Array::makei(count, j => controls[i + j].copy()),
        context: [number(case, "friction"), 1.0],
      }
    }
    let action = controls[i].copy()
    let after = runtime.step(action, substeps)
    exact_source(
      after,
      next[i],
      tensor(arrays, "next_state").dtype,
      "source control replay differs after snapshot",
    )
    previous = action
  }
  (snapshots, end)
}

///|
pub async fn run_action_response(
  source : String,
  output : String,
  scene : String,
  library : String,
) -> Unit {
  let started = @env.now()
  let config = read(output + "/config.json")
  if digest(source + "/report.json") != text(config, "source_report_sha256") {
    fail("wrong frozen last-cycle source")
  }
  let previous = read(source + "/report.json")
  let refs_path = text(previous, "references")
  let (manifest, references) = @ref.load_references(refs_path)
  if digest(refs_path + "/manifest.json") !=
    text(previous, "reference_manifest_sha256") {
    fail("reference manifest changed")
  }
  let dt = number(field(manifest, "layout"), "dt_s")
  let runtime = @physics.Runtime::open(library, scene)
  let (lower, upper) = runtime.control_bounds()
  let by_id : Map[String, Json] = {}
  for record in array(previous, "physical_records") {
    by_id[text(record, "episode_id")] = record
  }
  for name in ["physics", "snapshots", "directions"] {
    @fs.mkdir(output + "/" + name, recursive=true)
  }
  let records : Array[Json] = []
  let conditions : Array[Json] = []
  let missing : Array[Json] = []
  let mut replayed = 0
  let horizons = integers(config, "horizons")
  let gamma = number(config, "gamma")
  let amplitudes = numbers(config, "action_rms_amplitudes_rad")
  if amplitudes.is_empty() {
    fail("action amplitudes required")
  }
  let mut maximum_amplitude = 0.0
  for a in amplitudes {
    if a > maximum_amplitude {
      maximum_amplitude = a
    }
  }
  for method in strings(config, "methods") {
    for seed in integers(config, "seeds") {
      guard array(previous, "runs")
        .filter(r => text(r, "method") == method && integer(r, "seed") == seed)
        .get(0)
        is Some(row) else {
        fail("missing source method/seed")
      }
      let model_path = text(row, "model_checkpoint")
      let actor_path = text(row, "before_checkpoint")
      if digest(model_path) != text(row, "model_sha256") ||
        digest(actor_path) != text(row, "before_sha256") {
        fail("frozen model or tape actor changed")
      }
      let (model, _) = @ref.load_reference_dynamics(model_path)
      let (_, actor_meta) = @ref.load_reference_actor(actor_path)
      let geometry = @ref.kinematics_from_spec(actor_meta.kinematics)
      let frozen = model_state_digest(model)
      for clip_index in integers(config, "probe_clip_indices") {
        if clip_index < 0 || clip_index >= references.length() {
          fail("probe clip index out of bounds")
        }
        guard array(row, "comparisons")
          .filter(c => integer(c, "clip_index") == clip_index)
          .get(0)
          is Some(comparison) else {
          fail("missing source clip comparison")
        }
        guard by_id.get(text(comparison, "before_episode_id")) is Some(record) else {
          fail("missing physical control tape")
        }
        let tape_path = resolve(source, text(record, "file"))
        if digest(tape_path) != text(record, "sha256") ||
          text(field(record, "behavior"), "sha256") !=
          text(row, "before_sha256") {
          fail("source physical control tape changed")
        }
        let arrays = @artifacts.load_npz(tape_path)
        let reference = references[clip_index]
        let clip = reference.metadata
        let (snapshots, count) = replay_snapshots(
          runtime,
          reference,
          field(clip, "case"),
          arrays,
          integers(config, "offset_steps"),
          integer(config, "maximum_branch_steps"),
          dt,
        )
        replayed += count
        for offset in integers(config, "offset_steps") {
          guard snapshots.get(offset) is Some(s) else {
            missing.push({
              "method": method,
              "seed": seed,
              "clip_index": clip_index,
              "offset": offset,
              "reason": "source ends before complete maximum-horizon window",
              "source_steps": integer(record, "steps"),
            })
            continue
          }
          let label = "\{method}-seed-\{seed}-clip-\{clip_index}-offset-\{offset}"
          let snapshot_file = "snapshots/" + label + ".npz"
          let snapshot_sha = @artifacts.save_npz(
            output + "/" + snapshot_file,
            s.arrays(),
          )
          let target = targets(
            reference,
            offset,
            integer(config, "maximum_branch_steps"),
          )
          let baseline = physics_branch(
            runtime,
            s,
            s.actions,
            target,
            geometry,
            dt,
          )
          let next = matrix(arrays, "next_state")
          for i, state in baseline.next_state {
            exact_source(
              state,
              next[offset + i],
              tensor(arrays, "next_state").dtype,
              "restoring full solver snapshot changes baseline physics",
            )
          }
          let metadata : Json = {
            "method": method,
            "seed": seed,
            "clip_index": clip_index,
            "offset": offset,
            "source_family": field(clip, "source_family"),
            "source_episode_id": field(record, "episode_id"),
            "source_physics_sha256": field(record, "sha256"),
            "source_actor_sha256": field(row, "before_sha256"),
            "geometry_checkpoint": actor_path,
            "context": s.context,
            "snapshot": snapshot_file,
            "snapshot_sha256": snapshot_sha,
          }
          let base = save_branch(
            output,
            label + "-baseline",
            baseline,
            merge(metadata, { "role": "baseline-replay", "amplitude": 0.0 }),
            horizons,
            gamma,
          )
          records.push(base)
          let direction_rows : Array[Json] = []
          for horizon in horizons {
            if horizon < 1 || horizon > s.actions.length() {
              fail("action response horizon exceeds branch tape")
            }
            let (objective, gradient) = first_objective(
              model,
              geometry,
              s,
              target,
              horizon,
              s.actions[0],
              gamma,
              dt,
            )
            if gradient.any(v => !@numeric.finite(v)) {
              fail("nonfinite action-response gradient")
            }
            let feasible = @ref.control_direction(
              [gradient],
              [[s.actions[0]]],
              lower,
              upper,
              maximum_amplitude,
            )
            let direction = feasible.direction[0]
            let direction_file = "directions/" + label + "-h\{horizon}.npz"
            let direction_sha = @artifacts.save_npz(
              output + "/" + direction_file,
              {
                "direction": numeric([direction.length()], direction),
                "gradient": numeric([gradient.length()], gradient),
              },
            )
            let epsilon = number(config, "finite_difference_epsilon_rad")
            if epsilon <= 0 {
              fail("positive finite difference epsilon required")
            }
            let predicted = (amount : Double) => {
              let controls = @ref.first_action_tape(
                s.actions,
                direction,
                amount,
                lower,
                upper,
              )
              first_objective(
                model,
                geometry,
                s,
                target,
                horizon,
                controls[0],
                gamma,
                dt,
              ).0
            }
            let mut analytic = 0.0
            for i, g in gradient {
              analytic += g * direction[i]
            }
            let numeric_derivative = (predicted(epsilon) - predicted(-epsilon)) /
              (2 * epsilon)
            if !@ref.autodiff_consistent(
                analytic,
                numeric_derivative,
                absolute_tolerance=0.00001,
                relative_tolerance=0.001,
              ) {
              fail("model action gradient fails finite difference")
            }
            let outcomes : Array[Json] = []
            for amplitude in amplitudes {
              if amplitude <= 0 {
                fail("positive perturbation amplitude required")
              }
              let pair : Json = { "amplitude_rad": amplitude }
              guard pair is Object(p) else { fail("pair object") }
              for (sign, name) in [(-1.0, "minus"), (1.0, "plus")] {
                let controls = @ref.first_action_tape(
                  s.actions,
                  direction,
                  sign * amplitude,
                  lower,
                  upper,
                )
                let branch = physics_branch(
                  runtime, s, controls, target, geometry, dt,
                )
                let extra : Json = {
                  "role": "counterfactual",
                  "amplitude": sign * amplitude,
                  "direction_horizon": horizon,
                  "direction_file": direction_file,
                  "direction_sha256": direction_sha,
                }
                let result = save_branch(
                  output,
                  label + "-h\{horizon}-amp\{amplitude}-sign\{sign}",
                  branch,
                  merge(metadata, extra),
                  horizons,
                  gamma,
                )
                records.push(result)
                let mut mse = 0.0
                for i, v in controls[0] {
                  let d = v - s.actions[0][i]
                  mse += d * d / controls[0].length().to_double()
                }
                p[name] = {
                  "episode_id": field(result, "episode_id"),
                  "model_return": predicted(sign * amplitude),
                  "physics_return": number(
                    field(result, "returns"),
                    horizon.to_string(),
                  ),
                  "achieved_first_action_rms_rad": mse.sqrt(),
                }
              }
              let plus = field(pair, "plus")
              let minus = field(pair, "minus")
              p["physics_directional"] = ((
                number(plus, "physics_return") - number(minus, "physics_return")
              ) /
              (2 * amplitude)).to_json()
              p["model_directional"] = ((
                number(plus, "model_return") - number(minus, "model_return")
              ) /
              (2 * amplitude)).to_json()
              p["positive_physics_gain"] = (number(plus, "physics_return") -
              number(field(base, "returns"), horizon.to_string())).to_json()
              outcomes.push(pair)
            }
            direction_rows.push({
              "horizon": horizon,
              "gradient_rms": feasible.gradient_rms,
              "interior_action_coordinates": feasible.interior_coordinates,
              "analytic_directional": analytic,
              "model_finite_difference_directional": numeric_derivative,
              "finite_difference_error": (analytic - numeric_derivative).abs(),
              "model_baseline_return": objective,
              "physics_baseline_return": number(
                field(base, "returns"),
                horizon.to_string(),
              ),
              "outcomes": outcomes,
            })
          }
          conditions.push(
            merge(metadata, {
              "model_checkpoint": model_path,
              "model_sha256": digest(model_path),
              "baseline": field(base, "episode_id"),
              "exact_float32_source_replay": tensor(arrays, "state").dtype ==
              "<f4",
              "source_replay_dtype": tensor(arrays, "state").dtype,
              "directions": direction_rows,
            }),
          )
        }
      }
      if model_state_digest(model) != frozen {
        fail("action response changed model tensors")
      }
    }
  }
  let report : Json = {
    "format": "moonrobo.g1-reference-action-response.v1",
    "config": config,
    "source_study": source,
    "source_report_sha256": digest(source + "/report.json"),
    "references": refs_path,
    "reference_manifest_sha256": field(previous, "reference_manifest_sha256"),
    "physical_records": records,
    "conditions": conditions,
    "missing_conditions": missing,
    "source_transitions_replayed": replayed,
    "counterfactual_episodes": records
    .filter(r => text(r, "role") == "counterfactual")
    .length(),
    "baseline_replay_episodes": records
    .filter(r => text(r, "role") == "baseline-replay")
    .length(),
    "provider_seconds": (@env.now() - started).to_double() / 1000,
    "physical_execution_allowed": false,
    "release_qualified": false,
    "scope": field(config, "scope"),
  }
  if report is Object(m) {
    m["provider_sha256"] = provider_digest("action.mbt").to_json()
  }
  ignore(@artifacts.save_json(output + "/report.json", report))
}
