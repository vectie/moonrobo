///|
/// Critic diagnostics on the selected actor's real native-physics trajectories.
pub async fn run_critic(options : Map[String, String]) -> Unit {
  let config = read(option(options, "--config"))
  let experiment = read(option(options, "--experiment"))
  let runtime = @physics.Runtime::open(
    option(options, "--library"),
    option(options, "--scene"),
  )
  let directory = option(options, "--policies")
  let dt = num(experiment, "control_dt_s")
  let records : Array[Json] = []
  let summaries : Array[Json] = []
  let digests : Map[String, String] = {}
  for seed in ints(config, "policy_seeds") {
    let path = checkpoint_path(directory, "actor-seed-\{seed}")
    let checkpoint = @training.load_learning_checkpoint(path, "g1-actor")
    let actor = @training.actor_from_checkpoint(checkpoint)
    let critics : Array[(@training.Critic, String)] = []
    for
      (label, file) in [
        ("selected", path),
        ("latest", checkpoint_path(directory, "latest-actor-seed-\{seed}")),
      ] {
      let cp = @training.load_learning_checkpoint(file, "g1-actor")
      critics.push(
        (
          @training.critic_from_actor_checkpoint(
            cp,
            actor.goal_stats.mean.length(),
            2,
          ),
          label,
        ),
      )
      digests[file] = digest(file)
    }
    let actor_config = field(checkpoint.metadata, "config")
    for case in arr(experiment, "cases") {
      for reset_seed in ints(config, "reset_seeds") {
        let collection = collect(
          runtime,
          case,
          reset_seed,
          experiment,
          [],
          Some(actor),
        )
        let rewards : Array[Double] = []
        let continuations : Array[Double] = []
        for s in collection.episode.steps {
          let nu = s.applied_action.length()
          let previous = Array::makei(nu, i => {
            s.observation[s.observation.length() - nu + i]
          })
          let (reward, continuation) = @probes.step_reward(
            s.next_state,
            s.applied_action,
            previous,
            s.goal,
            actor.body.q_indices,
            num(actor_config, "target_height_m"),
          )
          rewards.push(reward)
          continuations.push(continuation)
        }
        let (hard, soft) = @probes.recorded_returns(
          rewards,
          continuations,
          collection.episode.steps.map(s => s.terminated),
          num(actor_config, "gamma"),
        )
        for start in ints(config, "snapshot_steps") {
          if start >= collection.episode.steps.length() {
            continue
          }
          let step = collection.episode.steps[start]
          for (critic, label) in critics {
            let tape = @numeric.Tape::new()
            let state = tape.vector(step.state)
            let value = critic.forward(
              tape,
              critic.network.bind(tape),
              state,
              tape.vector(step.goal),
              tape.vector(collection.episode.context),
            )
            tape.backward(value)
            let shifts : Array[Double] = []
            for raw in arr(config, "translation_shifts_m") {
              let xy : Array[Double] = @json.from_json(raw)
              if xy.length() != 2 {
                fail("translation shift needs x/y")
              }
              let shifted = step.state.copy()
              shifted[0] += xy[0]
              shifted[1] += xy[1]
              shifts.push(
                critic.predict(shifted, step.goal, collection.episode.context) -
                value.value,
              )
            }
            records.push({
              "policy_seed": seed,
              "critic": label,
              "case": str(case, "id"),
              "reset_seed": reset_seed,
              "start_step": start,
              "time_s": start.to_double() * dt,
              "episode_terminated": collection.trial.failed,
              "value": value.value,
              "hard_physics_return": hard[start],
              "soft_physics_return": soft[start],
              "xy_gradient": [tape.gradient(state[0]), tape.gradient(state[1])],
              "shifted_value_changes": shifts,
              "near_bound": value.value.abs() >= 0.99 * critic.value_bound,
            })
          }
        }
      }
    }
    for label in ["selected", "latest"] {
      let rows = records.filter(r => {
        match r {
          Object(m) =>
            m.get("policy_seed") == Some(seed.to_json()) &&
            m.get("critic") == Some(label.to_json())
          _ => false
        }
      })
      let uncensored = rows.filter(r => {
        match r {
          Object(m) => m.get("episode_terminated") is Some(True)
          _ => false
        }
      })
      let shifts : Array[Double] = []
      for r in rows {
        for x in nums(r, "shifted_value_changes") {
          shifts.push(x.abs())
        }
      }
      let mut maximum : Double? = None
      for x in shifts {
        maximum = Some(
          match maximum {
            None => x
            Some(m) => if x > m { x } else { m }
          },
        )
      }
      summaries.push({
        "policy_seed": seed,
        "critic": label,
        "states": rows.length(),
        "uncensored_states": uncensored.length(),
        "mean_value": average(rows.map(r => num(r, "value"))),
        "mean_soft_physics_return": average(
          uncensored.map(r => num(r, "soft_physics_return")),
        ),
        "mean_absolute_soft_return_error": average(
          uncensored.map(r => {
            (num(r, "value") - num(r, "soft_physics_return")).abs()
          }),
        ),
        "mean_absolute_translation_change": average(shifts),
        "maximum_absolute_translation_change": maximum,
        "near_bound_fraction": average(
          rows.map(r => if field(r, "near_bound") is True { 1.0 } else { 0.0 }),
        ),
      })
    }
  }
  let report : Json = {
    "format": "moonrobo.g1-critic-probe.v1",
    "config": config,
    "experiment": experiment,
    "checkpoint_sha256": digests,
    "summaries": summaries,
    "records": records,
    "physical_execution_allowed": false,
    "scope": "Both critics scored on selected actor trajectories; true-fall uncensored states only for return errors; MoonBit float64/native checkpoints and xorshift32 draws.",
  }
  let output = option(options, "--output")
  if !@fs.exists(output) {
    @fs.mkdir(output, recursive=true)
  }
  write(output + "/report.json", report)
  if report is Object(m) {
    ignore(m.remove("records"))
  }
  write(output + "/summary.json", report)
}
