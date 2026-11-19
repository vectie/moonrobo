///|
/// Extend frozen learned policies; the repeated reset must reproduce every original step except time-limit truncation flags.
pub async fn run_learned_long(
  library : String,
  scene : String,
  config_path : String,
  study_directory : String,
  output : String,
) -> Unit {
  let config = @artifacts.load_json(config_path)
  let fit = @artifacts.load_json(study_directory + "/report.json")
  let fit_sha = @artifacts.sha256(
    @fs.read_file(study_directory + "/report.json").binary(),
  )
  let experiment = @artifacts.load_json(study_directory + "/experiment.json")
  let charter = @artifacts.load_json(study_directory + "/charter.json")
  let source_log = @artifacts.load_jsonl(
    study_directory + "/evaluation-physics.jsonl.gz",
    expected_sha256=text(fit, "evaluation_log_sha256"),
  )
  let prior : Map[(Int32, String, String), Array[Json]] = Map([])
  for row in source_log {
    let episodes = array(field(row, "dataset"), "episodes")
    let trials = array(row, "trials")
    guard episodes.length() == trials.length() else {
      fail("prior evaluation episodes/trials differ")
    }
    for i in 0..<episodes.length() {
      if text(trials[i], "scope") == "canonical-development" &&
        integer(trials[i], "seed") == integer(config, "repeat_reset_seed") {
        let key = (
          integer(row, "seed"),
          text(row, "mode"),
          text(trials[i], "case_id"),
        )
        guard !prior.contains(key) else {
          fail("duplicate prior canonical trajectory")
        }
        prior[key] = array(episodes[i], "steps")
      }
    }
  }
  let runtime = @native_physics.Runtime::open(library, scene)
  let native_geometry = @balance_native.make_spec(runtime)
  let seeds : Array[Int32] = @json.from_json(field(config, "seeds"))
  let modes : Array[String] = @json.from_json(field(config, "modes"))
  let resets : Array[Int32] = @json.from_json(field(config, "reset_seeds"))
  guard resets.contains(integer(config, "repeat_reset_seed")) else {
    fail("long study must include repeated prefix reset")
  }
  if !@fs.exists(output) {
    @fs.mkdir(output)
  }
  let start_time = @async.now()
  let rows : Array[Json] = []
  let log : Array[Json] = []
  for seed in seeds {
    for mode in modes {
      let checkpoint = if mode == "student" {
        policy_path(
          text(charter, "incoming_policies") + "/actor-seed-" + seed.to_string(),
        )
      } else {
        policy_path(
          study_directory +
          "/policy/actor-" +
          mode +
          "-seed-" +
          seed.to_string(),
        )
      }
      let feedback = if mode == "student" {
        None
      } else {
        Some(@balance_policy.load(checkpoint))
      }
      let parent = match feedback {
        Some(policy) => policy.parent
        None => @temporal.load_temporal(checkpoint)
      }
      let head = match feedback {
        Some(policy) =>
          match policy.head {
            Learned(head) => Some(head)
            _ => fail("learned long study requires learned ankle head")
          }
        None => None
      }
      let geometry = match feedback {
        Some(policy) => policy.geometry
        None => native_geometry
      }
      let window = match feedback {
        Some(policy) => policy.window
        None => None
      }
      let initial = parent.parameters()
      let episodes = []
      let trials : Array[Json] = []
      let mut prefix_points = 0
      let mut transitions = 0
      for case_json in array(experiment, "cases") {
        for reset in resets {
          let (episode, trial, _, _, _) = study_rollout(
            runtime,
            parent,
            head,
            geometry,
            window,
            case_json,
            reset,
            number(experiment, "control_dt_s"),
            number(config, "duration_s"),
            number(config, "fall_height_m"),
            number(config, "fall_upright_z"),
          )
          if reset == integer(config, "repeat_reset_seed") {
            let key = (seed, mode, text(case_json, "id"))
            guard prior.get(key) is Some(original) else {
              fail("missing original canonical prefix")
            }
            guard episode.steps.length() >= original.length() else {
              fail("long extension ended before original prefix")
            }
            for i in 0..<original.length() {
              let new_step = episode.steps[i].to_json()
              guard original[i] is Object(old_fields) else {
                fail("invalid original step")
              }
              for name, old_value in old_fields {
                if name == "truncated" {
                  continue
                }
                guard field(new_step, name) == old_value else {
                  fail(
                    "long evaluation changed actual original prefix field: " +
                    name,
                  )
                }
              }
            }
            prefix_points += original.length()
          }
          let id = episode.id + "-balance-long-" + seed.to_string() + "-" + mode
          let episode = { ..episode, id, }
          let trial = trial.to_json()
          match trial {
            Object(fields) => {
              fields["episode_id"] = id.to_json()
              fields["scope"] = "thirty-second-development".to_json()
            }
            _ => ()
          }
          episodes.push(episode)
          trials.push(trial)
          transitions += episode.steps.length()
        }
      }
      guard parent.parameters() == initial else {
        fail("long evaluation changed frozen parent weights")
      }
      log.push({
        "seed": seed.to_json(),
        "mode": mode.to_json(),
        "dataset": runtime.dataset(
          episodes,
          text(experiment, "source_revision"),
          dt=number(experiment, "control_dt_s"),
        ),
        "trials": trials.to_json(),
      })
      let concise = trials.map(trial => {
        match trial {
          Object(fields) => {
            let fields = fields.copy()
            ignore(fields.remove("replay"))
            Json::object(fields)
          }
          _ => trial
        }
      })
      rows.push({
        "seed": seed.to_json(),
        "mode": mode.to_json(),
        "checkpoint": checkpoint.to_json(),
        "checkpoint_sha256": @artifacts.sha256(
          @fs.read_file(checkpoint).binary(),
        ).to_json(),
        "summary": @balance.summarize_recorded_trials(trials),
        "trials": concise.to_json(),
        "episodes": episodes.length().to_json(),
        "transitions": transitions.to_json(),
        "exact_original_prefix_points": prefix_points.to_json(),
      })
    }
  }
  let pooled : Array[Json] = []
  for mode in modes {
    let trials = []
    for row in rows {
      if text(row, "mode") == mode {
        trials.append(array(row, "trials"))
      }
    }
    pooled.push({
      "mode": mode.to_json(),
      "summary": @balance.summarize_recorded_trials(trials),
    })
  }
  let log_sha = @artifacts.save_jsonl(
    output + "/evaluation-physics.jsonl.gz",
    log,
  )
  ignore(
    @artifacts.save_json(output + "/report.json", {
      "format": "moonrobo.moonbit-learned-balance-long.v1",
      "config": config,
      "fit_report_sha256": fit_sha.to_json(),
      "evaluation_log_sha256": log_sha.to_json(),
      "evaluation": rows.to_json(),
      "pooled": pooled.to_json(),
      "wall_seconds": ((@async.now() - start_time).to_double() / 1000).to_json(),
      "release_qualified": false,
      "physical_execution_allowed": false,
      "parity_status": "awaiting-python-comparison",
    }),
  )
}
