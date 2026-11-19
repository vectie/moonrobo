///|
fn field(value : Json, key : String) -> Json raise {
  guard value is Object(fields) && fields.get(key) is Some(result) else {
    fail("missing calibration field: " + key)
  }
  result
}

///|
fn number(value : Json) -> Double raise {
  guard value is Number(n, ..) && @numeric.finite(n) else {
    fail("finite calibration number required")
  }
  n
}

///|
fn integer(value : Json) -> Int32 raise {
  let value = number(value)
  guard value >= 0 &&
    value <= 2147483647.0 &&
    value.to_int().to_double() == value else {
    fail("nonnegative calibration integer required")
  }
  value.to_int()
}

///|
fn array(value : Json) -> Array[Json] raise {
  guard value is Array(items) else { fail("calibration array required") }
  items
}

///|
fn text(value : Json) -> String raise {
  guard value is String(s) else { fail("calibration string required") }
  s
}

///|
pub async fn calibrate_noise(
  library : String,
  scene : String,
  config_path : String,
  collection_path : String,
  policies : String,
  output : String,
) -> Json {
  let config = @artifacts.load_json(config_path)
  let collection = @artifacts.load_json(collection_path)
  let runtime = @physics.Runtime::open(library, scene)
  let dt = number(field(collection, "control_dt_s"))
  let seconds = number(field(config, "duration_s"))
  let amplitudes = array(field(config, "standard_deviations")).map(number)
  guard !amplitudes.is_empty() && amplitudes.all(v => v >= 0) else {
    fail("nonempty nonnegative latent amplitudes required")
  }
  let cases = array(field(collection, "cases"))
  guard !cases.is_empty() && cases.all(raw => field(raw, "split") == "train") else {
    fail("exploration calibration requires train families only")
  }
  if !@fs.exists(output) {
    @fs.mkdir(output, recursive=true)
  }
  let rows : Array[Json] = []
  let logs : Array[Json] = []
  for seed_json in array(field(config, "seeds")) {
    let seed = integer(seed_json)
    let native = policies + "/actor-seed-\{seed}.moon.json"
    let actor_path = if @fs.exists(native) {
      native
    } else {
      policies + "/actor-seed-\{seed}.pt"
    }
    let actor = @temporal.load_temporal(actor_path)
    let original_parameters = actor.parameters()
    for std in amplitudes {
      let episodes : Array[@physics.Episode] = []
      let trials : Array[@physics.Trial] = []
      let mut squared_noise = 0.0
      let mut saturated = 0
      let mut count = 0
      for index, raw in cases {
        let case : @physics.Case = @json.from_json(raw)
        let reset64 = integer(field(config, "collect_seed_base")).to_int64() +
          10000L * seed.to_int64()
        guard reset64 <= 2147483647L else {
          fail("calibration reset seed overflow")
        }
        let reset = reset64.to_int()
        let noise64 = integer(field(config, "noise_seed")).to_int64() +
          seed.to_int64() +
          100000L * index.to_int64()
        guard noise64 <= 4294967295L else {
          fail("calibration noise seed overflow")
        }
        // Recreated for each amplitude: episode lengths cannot shift other cases' draws.
        let noise_rng = @numeric.Rng::new(
          noise64.to_int().reinterpret_as_uint(),
        )
        let reset_rng = @numeric.Rng::new(reset.to_uint())
        let (offset, schedule) = @balance_physics.sample_reference(
          runtime, raw, reset,
        )
        let history : Array[Array[Double]] = []
        let mut nominal : Array[Double] = []
        let mut step = 0
        let policy = fn(
          obs : Array[Double],
          goal : Array[Double],
        ) -> Array[Double] {
          if history.is_empty() {
            nominal = Array::makei(goal.length(), i => obs[i])
            for _ in 0..<actor.temporal.history_length {
              history.push(obs.copy())
            }
          } else {
            ignore(history.remove(0))
            history.push(obs.copy())
          }
          let future = Array::makei(actor.temporal.future_length, j => {
            try! runtime.reference(
              nominal,
              case.motion,
              (step + j + 1).to_double() * dt,
              offset?,
              schedule?,
            )
          })
          let tape = @numeric.Tape::new()
          let mean = actor.latent_mean(
            tape,
            tape.vector(actor.parameters()),
            history.map(row => tape.vector(row)),
            tape.vector(goal),
            future.map(row => tape.vector(row)),
          )
          let deterministic = actor.base
            .action_from_latent(tape, mean, tape.vector(goal))
            .map(v => v.value)
          let latent = mean.map(v => v.value + std * noise_rng.normal())
          let action = actor.base
            .action_from_latent(tape, tape.vector(latent), tape.vector(goal))
            .map(v => v.value)
          for j in 0..<action.length() {
            let difference = action[j] - deterministic[j]
            squared_noise += difference * difference
            if mean[j].value.abs() > 3 {
              saturated += 1
            }
            count += 1
          }
          step += 1
          action
        }
        let (episode, trial) = runtime.rollout(
          case,
          reset,
          "policy",
          seconds,
          dt,
          () => reset_rng.normal(),
          policy~,
          offset?,
          schedule?,
          fall_height=number(field(config, "fall_height_m")),
          fall_upright=number(field(config, "fall_upright_z")),
        )
        let id = episode.id + "-noise-\{std}"
        episodes.push({ ..episode, id, })
        trials.push({ ..trial, episode_id: id, })
      }
      guard count > 0 && actor.parameters() == original_parameters else {
        fail("empty noise calibration or actor weights changed")
      }
      let mut falls = 0
      let mut survival = 0.0
      let mut rmse = 0.0
      let mut transitions = 0
      let trial_rows : Array[Json] = []
      for trial in trials {
        if trial.failed {
          falls += 1
        }
        survival += trial.simulated_seconds
        rmse += trial.joint_rmse_rad
        transitions += trial.steps
        guard Json(trial) is Object(fields) else {
          fail("trial serialization failed")
        }
        ignore(fields.remove("replay"))
        trial_rows.push(Json::object(fields))
      }
      rows.push({
        "seed": Json(seed),
        "latent_std": Json(std),
        "episodes": Json(episodes.length()),
        "transitions": Json(transitions),
        "falls": Json(falls),
        "mean_survival_s": Json(survival / trials.length().to_double()),
        "mean_joint_rmse_rad": Json(rmse / trials.length().to_double()),
        "setpoint_noise_rms_rad": Json(
          (squared_noise / count.to_double()).sqrt(),
        ),
        "saturated_latent_fraction": Json(
          saturated.to_double() / count.to_double(),
        ),
        "trials": Json(trial_rows),
        "incoming_sha256": Json(
          @artifacts.sha256(@fs.read_file(actor_path).binary()),
        ),
      })
      logs.push({
        "seed": Json(seed),
        "latent_std": Json(std),
        "dataset": runtime.dataset(
          episodes,
          text(field(collection, "source_revision")),
          dt~,
        ),
      })
    }
  }
  let log_sha = @artifacts.save_jsonl(output + "/noise-physics.jsonl.gz", logs)
  let report : Json = {
    "format": "moonrobo.g1-temporal-ppo-noise.v1",
    "config": config,
    "rows": Json(rows),
    "log_sha256": Json(log_sha),
    "scope": "No learning: original incoming actors, same first PPO training reset per seed, coupled per-case noise streams. Separate diagnostic sampling cost, not PPO training samples. Only train families; no validation/test-based amplitude selection.",
    "physical_execution_allowed": false,
    "rng": "moonbit-xorshift32-box-muller; does not reproduce Torch noise seeds",
  }
  ignore(@artifacts.save_json(output + "/report.json", report))
  report
}
