///|
/// Full real-physics model sensitivity collection from native checkpoints.
pub async fn run_model(options : Map[String, String]) -> Unit {
  let config = read(option(options, "--config"))
  let experiment = read(option(options, "--experiment"))
  let initial_path = option(options, "--initial")
  let corrected_path = option(options, "--corrected")
  let models = [
    @training.dynamics_from_checkpoint(
      @training.load_learning_checkpoint(initial_path, "residual-dynamics"),
    ),
    @training.dynamics_from_checkpoint(
      @training.load_learning_checkpoint(corrected_path, "residual-dynamics"),
    ),
  ]
  let actor = match options.get("--actor") {
    Some(p) =>
      Some(
        @training.actor_from_checkpoint(
          @training.load_learning_checkpoint(p, "g1-actor"),
        ),
      )
    None => None
  }
  let runtime = @physics.Runtime::open(
    option(options, "--library"),
    option(options, "--scene"),
  )
  let dt = num(experiment, "control_dt_s")
  let substeps = runtime.control_substeps(dt)
  let heights = num(config, "target_height_m")
  let gamma = num(config, "gamma")
  let epsilons = nums(config, "epsilons_rad")
  if epsilons.length() < 2 {
    fail("two epsilon scales required")
  }
  let scale = models[0].state_stats.scale
  let records : Array[Json] = []
  let typed : Array[@probes.Record] = []
  let omitted : Array[Json] = []
  let mut maximum_restore_error = 0.0
  let seeds : Array[Int32] = @json.from_json(
    optional(config, "seeds", [int(config, "seed")].to_json()),
  )
  let rng = @numeric.Rng::new(int(config, "seed").to_uint() + 1U)
  let (lower, upper) = runtime.control_bounds()
  for case in arr(experiment, "cases") {
    for seed in seeds {
      let collection = collect(
        runtime,
        case,
        seed,
        experiment,
        ints(config, "snapshot_steps"),
        actor,
      )
      for start in ints(config, "snapshot_steps") {
        for horizon in ints(config, "horizons") {
          if !collection.snapshots.any(s => s.step == start) ||
            start + horizon > collection.episode.steps.length() {
            omitted.push({
              "case": str(case, "id"),
              "seed": seed,
              "start_step": start,
              "horizon": horizon,
              "episode_steps": collection.episode.steps.length(),
              "reason": "episode-ended-before-complete-window",
            })
          }
        }
      }
      for s in collection.snapshots {
        for horizon in ints(config, "horizons") {
          if s.step + horizon > collection.episode.steps.length() {
            continue
          }
          let window = Array::makei(horizon, i => {
            collection.episode.steps[s.step + i]
          })
          let actions = window.map(w => w.applied_action)
          let goals = window.map(w => w.goal)
          let truth = @probes.physical_rollout(
            runtime,
            s.integration,
            actions,
            substeps,
          )
          let restore_error = max_error(truth, window.map(w => w.next_state))
          if restore_error > 0.00000001 {
            fail("integration-state replay differs from collected physics")
          }
          if restore_error > maximum_restore_error {
            maximum_restore_error = restore_error
          }
          let actual = @probes.score(
            truth,
            actions,
            s.previous,
            goals,
            runtime.q_indices(),
            heights,
            gamma,
          )
          let model_rows : Array[Json] = []
          let model_typed : Array[@probes.ModelResult] = []
          let gradients : Array[Array[Array[Double]]] = []
          for model_index, model in models {
            let label = if model_index == 0 { "initial" } else { "corrected" }
            let tape = @numeric.Tape::new()
            let variable = actions.map(a => tape.vector(a))
            let applied = variable.map(a => {
              Array::makei(a.length(), i => {
                let clipped = tape.clamp(a[i], lower[i], upper[i])
                // torch.maximum(torch.minimum(x, upper), lower) shares the
                // derivative equally at ties; torch.clamp has another rule.
                let tie = (if a[i].value == lower[i] { 0.5 } else { 1.0 }) *
                  (if a[i].value == upper[i] { 0.5 } else { 1.0 })
                tape.add(
                  tape.scalar(clipped.value),
                  tape.scale(tape.sub(clipped, tape.scalar(clipped.value)), tie),
                )
              })
            })
            let predicted = model.imagine(
              tape,
              model.network.bind(tape),
              tape.vector(s.state),
              applied,
              tape.vector(s.context),
            )
            let value = ad_score(
              tape,
              predicted,
              applied,
              s.previous,
              goals,
              runtime.q_indices(),
              heights,
              gamma,
            )
            tape.backward(value)
            let gradient = variable.map(a => a.map(v => tape.gradient(v)))
            gradients.push(gradient)
            let prediction = predicted.map(a => a.map(v => v.value))
            let mut mse = 0.0
            for t, p in prediction {
              mse += @probes.normalized_mse(p, truth[t], scale) /
                horizon.to_double()
            }
            let mut norm2 = 0.0
            for a in gradient {
              for g in a {
                norm2 += g * g
              }
            }
            let norm = norm2.sqrt()
            let translations : Array[@probes.Translation] = []
            let translation_rows : Array[Json] = []
            let shifts : Array[Array[Double]] = @json.from_json(
              optional(config, "translation_shifts_m", [].to_json()),
            )
            for shift in shifts {
              if shift.length() != 2 {
                fail("translation shift needs x/y")
              }
              let shifted_truth = @probes.physical_rollout(
                runtime,
                s.integration,
                actions,
                substeps,
                xy_shift=(shift[0], shift[1]),
              )
              let shifted = s.state.copy()
              shifted[0] += shift[0]
              shifted[1] += shift[1]
              let shifted_tape = @numeric.Tape::new()
              let shifted_prediction = model
                .imagine(
                  shifted_tape,
                  model.network.bind(shifted_tape),
                  shifted_tape.vector(shifted),
                  actions.map(a => shifted_tape.vector(a)),
                  shifted_tape.vector(s.context),
                )
                .map(a => a.map(v => v.value))
              let mut physical_error = 0.0
              let mut model_error = 0.0
              for t in 0..<horizon {
                let target = prediction[t].copy()
                target[0] += shift[0]
                target[1] += shift[1]
                model_error += @probes.normalized_mse(
                    shifted_prediction[t],
                    target,
                    scale,
                  ) /
                  horizon.to_double()
                for j, v in truth[t] {
                  let expected = v + (if j < 2 { shift[j] } else { 0.0 })
                  let err = (shifted_truth[t][j] - expected).abs()
                  if err > physical_error {
                    physical_error = err
                  }
                }
              }
              translations.push({
                physical_equivariance_error: physical_error,
                normalized_model_equivariance_mse: model_error,
              })
              translation_rows.push({
                "xy_shift_m": shift,
                "physical_equivariance_error": physical_error,
                "normalized_model_equivariance_mse": model_error,
              })
            }
            let ascent : Array[@probes.Ascent] = []
            let ascent_rows : Array[Json] = []
            if boolean(config, "model_ascent_probe", false) && norm > 0 {
              let direction = gradient.map(a => a.map(g => g / norm))
              for epsilon in epsilons {
                let values : Array[Double] = []
                for sign in [1.0, -1.0] {
                  let perturbed : Array[Array[Double]] = []
                  for t, a in actions {
                    perturbed.push(
                      runtime.clip_control(
                        Array::makei(a.length(), i => {
                          a[i] + sign * epsilon * direction[t][i]
                        }),
                      ),
                    )
                  }
                  let states = @probes.physical_rollout(
                    runtime,
                    s.integration,
                    perturbed,
                    substeps,
                  )
                  values.push(
                    @probes.score(
                      states,
                      perturbed,
                      s.previous,
                      goals,
                      runtime.q_indices(),
                      heights,
                      gamma,
                    ),
                  )
                }
                ascent.push({ plus_return_change: values[0] - actual, })
                ascent_rows.push({
                  "epsilon_rad": epsilon,
                  "plus_return_change": values[0] - actual,
                  "minus_return_change": values[1] - actual,
                  "physics_derivative": (values[0] - values[1]) / (2 * epsilon),
                })
              }
            }
            model_typed.push({
              model: label,
              normalized_mse: mse,
              predicted_return: value.value,
              ascent_physics: ascent,
              translation_checks: translations,
            })
            model_rows.push({
              "model": label,
              "normalized_mse": mse,
              "predicted_return": value.value,
              "action_gradient_norm": norm,
              "ascent_physics": ascent_rows,
              "translation_checks": translation_rows,
              "final_root_height_m": prediction[horizon - 1][2],
              "final_upright_z": -@probes.gravity(prediction[horizon - 1])[2],
            })
          }
          let directions : Array[@probes.Direction] = []
          for _ in 0..<int(config, "directions") {
            let raw = actions.map(a => a.map(_ => rng.normal()))
            let mut norm2 = 0.0
            for a in raw {
              for v in a {
                norm2 += v * v
              }
            }
            let norm = norm2.sqrt()
            if norm == 0 {
              fail("zero sampled direction")
            }
            let direction = raw.map(a => a.map(v => v / norm))
            let numerical : Array[Double] = []
            for epsilon in epsilons {
              let values : Array[Double] = []
              for sign in [1.0, -1.0] {
                let perturbed : Array[Array[Double]] = []
                for t, a in actions {
                  perturbed.push(
                    runtime.clip_control(
                      Array::makei(a.length(), i => {
                        a[i] + sign * epsilon * direction[t][i]
                      }),
                    ),
                  )
                }
                values.push(
                  @probes.score(
                    @probes.physical_rollout(
                      runtime,
                      s.integration,
                      perturbed,
                      substeps,
                    ),
                    perturbed,
                    s.previous,
                    goals,
                    runtime.q_indices(),
                    heights,
                    gamma,
                  ),
                )
              }
              numerical.push((values[0] - values[1]) / (2 * epsilon))
            }
            let derivatives = gradients.map(g => {
              let mut dot = 0.0
              for t, a in g {
                for i, v in a {
                  dot += v * direction[t][i]
                }
              }
              dot
            })
            directions.push({
              initial_derivative: derivatives[0],
              corrected_derivative: derivatives[1],
              physics_derivatives: numerical,
            })
          }
          let mut persistence = 0.0
          for state in truth {
            persistence += @probes.normalized_mse(s.state, state, scale) /
              horizon.to_double()
          }
          records.push({
            "case": s.case_id,
            "seed": seed,
            "start_step": s.step,
            "start_time_s": s.step.to_double() * dt,
            "horizon": horizon,
            "source_split": collection.episode.split,
            "episode_steps": collection.episode.steps.length(),
            "steps_until_episode_end": collection.episode.steps.length() -
            s.step,
            "final_physics_root_height_m": truth[horizon - 1][2],
            "final_physics_upright_z": -@probes.gravity(truth[horizon - 1])[2],
            "physical_return": actual,
            "persistence_mse": persistence,
            "models": model_rows,
            "directions": directions,
          })
          typed.push({
            horizon,
            start_time_s: s.step.to_double() * dt,
            physical_return: actual,
            models: model_typed,
            directions,
          })
        }
      }
    }
  }
  let groups = if boolean(config, "stratify_time", false) {
    ["all", "before-two-seconds", "after-two-seconds"]
  } else {
    ["all"]
  }
  let summaries : Array[@probes.ModelSummary] = []
  for horizon in ints(config, "horizons") {
    for group in groups {
      summaries.append(
        @probes.summarize(typed, horizon, group, epsilons.length()),
      )
    }
  }
  let checkpoints : Map[String, String] = {}
  checkpoints[initial_path] = digest(initial_path)
  checkpoints[corrected_path] = digest(corrected_path)
  let report : Json = {
    "format": "moonrobo.model-physics-probe.v1",
    "config": config,
    "experiment": experiment,
    "controller": if actor is Some(_) {
      "policy"
    } else {
      "position"
    },
    "metric_scale": "initial-model training state scale",
    "maximum_restore_error": maximum_restore_error,
    "mujoco_version": runtime.version(),
    "checkpoints": checkpoints,
    "physical_execution_allowed": false,
    "summaries": summaries,
    "records": records,
    "omitted": omitted,
    "provider_language": "MoonBit float64/autodiff; xorshift32 draws are not NumPy/PyTorch seed-equivalent",
  }
  write(option(options, "--output"), report)
}
