///|
fn schedule_for(
  references : Array[@ref.ReferenceArchive],
  geometry : @balance.Kinematics,
  dt : Double,
) -> @ref.ReferenceSchedule raise {
  let clips = references.map(r => r.clip())
  @ref.ReferenceSchedule::new(clips, geometry, [0], dt)
}

///|
fn restored_inputs(
  snapshot_arrays : Map[String, @artifacts.NumericArray],
  original_arrays : Map[String, @artifacts.NumericArray],
  actor : @ref.ReferenceActor,
  clip : Int32,
  offset : Int32,
) -> Map[String, @artifacts.NumericArray] raise {
  let inputs = snapshot_arrays.copy()
  let obs = matrix(original_arrays, "observation")
  let history = Array::makei(actor.history_length, i => {
    obs[(offset - actor.history_length + 1 + i).max(0)].copy()
  })
  let flat : Array[Double] = []
  for h in history {
    flat.append(h)
  }
  inputs["history"] = numeric(
    [1, actor.history_length, actor.obs_mean.length()],
    flat,
  )
  let features = matrix(original_arrays, "actual_features")[offset]
  let planned = matrix(original_arrays, "reference_features")[offset]
  inputs["actual_features"] = numeric([1, features.length()], features)
  inputs["reference_features"] = numeric([1, planned.length()], planned)
  inputs["clip"] = numeric([], [clip.to_double()])
  inputs["phase"] = numeric([], [offset.to_double()])
  inputs
}

///|
pub async fn run_feedback_response(
  source : String,
  output : String,
  scene : String,
  library : String,
) -> Unit {
  let started = @env.now()
  let config = read(output + "/config.json")
  if digest(source + "/report.json") != text(config, "source_report_sha256") {
    fail("action-response source changed")
  }
  let prior = read(source + "/report.json")
  let old_source = text(prior, "source_study")
  if digest(old_source + "/report.json") != text(prior, "source_report_sha256") {
    fail("physical tape source changed")
  }
  let old_report = read(old_source + "/report.json")
  let old_records : Map[String, Json] = {}
  let prior_records : Map[String, Json] = {}
  for r in array(old_report, "physical_records") {
    old_records[text(r, "episode_id")] = r
  }
  for r in array(prior, "physical_records") {
    prior_records[text(r, "episode_id")] = r
  }
  let refs_path = text(prior, "references")
  let (manifest, references) = @ref.load_references(refs_path)
  if digest(refs_path + "/manifest.json") !=
    text(prior, "reference_manifest_sha256") {
    fail("reference manifest changed")
  }
  let dt = number(field(manifest, "layout"), "dt_s")
  let gamma = number(config, "gamma")
  let runtime = @physics.Runtime::open(library, scene)
  let (lower, upper) = runtime.control_bounds()
  for name in ["physics", "inputs", "directions"] {
    @fs.mkdir(output + "/" + name, recursive=true)
  }
  let records : Array[Json] = []
  let conditions : Array[Json] = []
  let amplitudes = numbers(config, "action_rms_amplitudes_rad")
  if amplitudes.is_empty() {
    fail("positive action amplitudes required")
  }
  let mut maximum_amplitude = 0.0
  for a in amplitudes {
    if a > maximum_amplitude {
      maximum_amplitude = a
    }
  }
  let modes = strings(config, "execution_modes")
  if !modes.contains("feedback") {
    fail("feedback controls are required for shared feasible interior")
  }
  for condition in array(prior, "conditions") {
    let model_path = text(condition, "model_checkpoint")
    let actor_path = text(condition, "geometry_checkpoint")
    if digest(model_path) != text(condition, "model_sha256") ||
      digest(actor_path) != text(condition, "source_actor_sha256") {
      fail("frozen actor/model changed")
    }
    let (model, _) = @ref.load_reference_dynamics(model_path)
    let (actor, meta) = @ref.load_reference_actor(actor_path)
    let geometry = @ref.kinematics_from_spec(meta.kinematics)
    let frozen_model = model_state_digest(model)
    let frozen_actor = @ref.state_digest(actor)
    let schedule = schedule_for(references, geometry, dt)
    let snapshot_path = resolve(source, text(condition, "snapshot"))
    if digest(snapshot_path) != text(condition, "snapshot_sha256") {
      fail("solver snapshot changed")
    }
    let source_snapshot = @artifacts.load_npz(snapshot_path)
    guard old_records.get(text(condition, "source_episode_id"))
      is Some(original) else {
      fail("controller history source absent")
    }
    let tape_path = resolve(old_source, text(original, "file"))
    if digest(tape_path) != text(original, "sha256") {
      fail("controller history source changed")
    }
    let original_arrays = @artifacts.load_npz(tape_path)
    let offset = integer(condition, "offset")
    let clip = integer(condition, "clip_index")
    let arrays = restored_inputs(
      source_snapshot, original_arrays, actor, clip, offset,
    )
    let label = stem(text(condition, "snapshot"))
    let inputs_file = "inputs/" + label + ".npz"
    let inputs_sha = @artifacts.save_npz(output + "/" + inputs_file, arrays)
    let inputs = feedback_inputs(arrays, actor)
    let target = targets(references[clip], offset, integer(config, "horizon"))
    if inputs.snapshot.actions.length() != integer(config, "horizon") {
      fail("saved tape horizon differs from declared feedback horizon")
    }
    let zero = inputs.snapshot.actions.map(row => row.map(_ => 0.0))
    let feedback_base = feedback_physics(
      runtime, actor, geometry, schedule, inputs, target, zero, dt,
    )
    if feedback_base.actions.length() != zero.length() {
      fail(
        "feedback baseline ends before complete shared feasible-direction tape",
      )
    }
    let metadata : Json = {
      "method": field(condition, "method"),
      "seed": field(condition, "seed"),
      "clip_index": clip,
      "offset": offset,
      "source_family": field(condition, "source_family"),
      "source_episode_id": field(condition, "source_episode_id"),
      "source_actor_sha256": field(condition, "source_actor_sha256"),
      "geometry_checkpoint": actor_path,
      "context": field(condition, "context"),
      "inputs": inputs_file,
      "inputs_sha256": inputs_sha,
    }
    let baselines : Map[String, Json] = {}
    for mode in modes {
      if mode == "open-tape" {
        guard prior_records.get(text(condition, "baseline")) is Some(base) else {
          fail("open tape baseline absent")
        }
        baselines[mode] = merge(
          base,
          merge(metadata, {
            "file": resolve(source, text(base, "file")),
            "execution_mode": mode,
            "reused_baseline": true,
            "snapshot": resolve(source, text(base, "snapshot")),
          }),
        )
      } else if mode == "feedback" {
        baselines[mode] = save_branch(
          output,
          label + "-feedback-baseline",
          feedback_base,
          merge(metadata, {
            "role": "feedback-baseline",
            "execution_mode": mode,
            "amplitude": 0.0,
            "reused_baseline": false,
          }),
          [8, 32],
          gamma,
        )
      } else {
        fail("unknown execution mode")
      }
      records.push(baselines[mode])
    }
    let responses : Map[String, ModelResponse] = {}
    for mode in modes {
      responses[mode] = model_response(
        model, actor, geometry, schedule, inputs, target, zero, mode, lower, upper,
        gamma, dt,
      )
    }
    let direction_rows : Array[Json] = []
    for direction_source in strings(config, "direction_sources") {
      let gradient = responses[direction_source].gradient
      if gradient.any(row => row.any(v => !@numeric.finite(v))) {
        fail("nonfinite control-tape gradient")
      }
      let feasible = @ref.control_direction(
        gradient,
        [
          inputs.snapshot.actions,
          responses["feedback"].controls,
          feedback_base.actions,
        ],
        lower,
        upper,
        maximum_amplitude,
      )
      let direction = feasible.direction
      let direction_file = "directions/" +
        label +
        "-" +
        direction_source +
        ".npz"
      let direction_sha = @artifacts.save_npz(output + "/" + direction_file, {
        "direction": matrix_array(direction),
        "gradient": matrix_array(gradient),
      })
      for mode in modes {
        let predicted = (amount : Double) => {
          model_response(
            model,
            actor,
            geometry,
            schedule,
            inputs,
            target,
            direction.map(row => row.map(v => amount * v)),
            mode,
            lower,
            upper,
            gamma,
            dt,
          ).objective
        }
        let mut analytic = 0.0
        for t, row in responses[mode].gradient {
          for j, g in row {
            analytic += g * direction[t][j]
          }
        }
        let checks : Array[Json] = []
        for epsilon in numbers(config, "model_finite_difference_epsilons_rad") {
          if epsilon <= 0 {
            fail("finite difference epsilons must be positive")
          }
          let numeric_derivative = (predicted(epsilon) - predicted(-epsilon)) /
            (2 * epsilon)
          checks.push({
            "epsilon_rad": epsilon,
            "numeric_directional": numeric_derivative,
            "absolute_error": (analytic - numeric_derivative).abs(),
            "passed": @ref.autodiff_consistent(
              analytic,
              numeric_derivative,
              absolute_tolerance=0.00001,
              relative_tolerance=0.001,
            ),
          })
        }
        if checks.is_empty() {
          fail("finite difference checks required")
        }
        let outcomes : Array[Json] = []
        for amplitude in amplitudes {
          if amplitude <= 0 {
            fail("positive action amplitude required")
          }
          let pair : Json = { "amplitude_rad": amplitude }
          guard pair is Object(p) else { fail("pair object") }
          for (sign, name) in [(-1.0, "minus"), (1.0, "plus")] {
            let perturbation = direction.map(row => {
              row.map(v => sign * amplitude * v)
            })
            let result = if mode == "open-tape" {
              let controls : Array[Array[Double]] = []
              for t, row in inputs.snapshot.actions {
                controls.push(
                  runtime.clip_control(
                    Array::makei(row.length(), i => row[i] + perturbation[t][i]),
                  ),
                )
              }
              physics_branch(
                runtime,
                inputs.snapshot,
                controls,
                target,
                geometry,
                dt,
              )
            } else {
              feedback_physics(
                runtime, actor, geometry, schedule, inputs, target, perturbation,
                dt,
              )
            }
            let id = label +
              "-direction-\{direction_source}-execute-\{mode}-amp\{amplitude}-sign\{sign}"
            let extra : Json = {
              "role": "counterfactual",
              "reused_baseline": false,
              "direction_source": direction_source,
              "execution_mode": mode,
              "amplitude": sign * amplitude,
              "direction_file": direction_file,
              "direction_sha256": direction_sha,
            }
            let record = save_branch(
              output,
              id,
              result,
              merge(metadata, extra),
              [8, 32],
              gamma,
            )
            records.push(record)
            p[name] = {
              "episode_id": field(record, "episode_id"),
              "model_return": predicted(sign * amplitude),
              "physics_return": number(field(record, "returns"), "32"),
            }
          }
          let plus = field(pair, "plus")
          let minus = field(pair, "minus")
          p["model_directional"] = ((
            number(plus, "model_return") - number(minus, "model_return")
          ) /
          (2 * amplitude)).to_json()
          p["physics_directional"] = ((
            number(plus, "physics_return") - number(minus, "physics_return")
          ) /
          (2 * amplitude)).to_json()
          p["positive_physics_gain"] = (number(plus, "physics_return") -
          number(field(baselines[mode], "returns"), "32")).to_json()
          outcomes.push(pair)
        }
        direction_rows.push({
          "direction_source": direction_source,
          "execution_mode": mode,
          "interior_action_coordinates": feasible.interior_coordinates,
          "analytic_directional": analytic,
          "finite_difference_error": number(checks[0], "absolute_error"),
          "model_finite_difference_checks": checks,
          "smallest_epsilon_verified": field(
            checks[checks.length() - 1],
            "passed",
          ),
          "model_baseline_return": responses[mode].objective,
          "model_active_steps": responses[mode].active_steps,
          "physics_baseline_return": number(
            field(baselines[mode], "returns"),
            "32",
          ),
          "outcomes": outcomes,
        })
      }
    }
    if model_state_digest(model) != frozen_model ||
      @ref.state_digest(actor) != frozen_actor {
      fail("feedback diagnostic changed learned tensors")
    }
    let baseline_ids : Map[String, Json] = {}
    for mode in modes {
      baseline_ids[mode] = field(baselines[mode], "episode_id")
    }
    conditions.push(
      merge(metadata, {
        "model_checkpoint": model_path,
        "model_sha256": digest(model_path),
        "baselines": baseline_ids,
        "directions": direction_rows,
      }),
    )
  }
  let report : Json = {
    "format": "moonrobo.g1-reference-feedback-response.v1",
    "config": config,
    "source_study": source,
    "source_report_sha256": digest(source + "/report.json"),
    "references": refs_path,
    "reference_manifest_sha256": field(prior, "reference_manifest_sha256"),
    "physical_records": records,
    "conditions": conditions,
    "provider_seconds": (@env.now() - started).to_double() / 1000,
    "physical_execution_allowed": false,
    "release_qualified": false,
    "scope": field(config, "scope"),
  }
  if report is Object(m) {
    m["provider_sha256"] = provider_digest("feedback.mbt").to_json()
  }
  ignore(@artifacts.save_json(output + "/report.json", report))
}
