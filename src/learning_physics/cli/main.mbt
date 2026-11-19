///|
fn field(j : Json, key : String) -> Json raise {
  guard j is Object(fields) && fields.get(key) is Some(value) else {
    fail("missing field: " + key)
  }
  value
}

///|
fn number(j : Json) -> Double raise {
  guard j is Number(n) else { fail("expected number") }
  n
}

///|
fn text(j : Json) -> String raise {
  guard j is String(s) else { fail("expected string") }
  s
}

///|
fn array(j : Json) -> Array[Json] raise {
  guard j is Array(a) else { fail("expected array") }
  a
}

///|
fn sha(bytes : Bytes) -> String {
  let mut digest = ""
  for b in @crypto.sha256(bytes) {
    digest += b.to_hex()
  }
  digest
}

///|
fn generator(seed : Int32, stream : Int32) -> @random.Rand {
  @random.Rand::chacha8(
    seed=Bytes::from_array(
      @crypto.sha256(@utf8.encode("moonrobo:\{seed}:\{stream}")),
    ),
  )
}

///|
async fn main {
  let args = @env.args()
  let options : Map[String, String] = {}
  for i = 1; i < args.length(); i = i + 2 {
    if i + 1 >= args.length() {
      fail("missing option value")
    }
    options[args[i]] = args[i + 1]
  }
  guard options.get("--scene") is Some(scene) else {
    fail("--scene is required")
  }
  guard options.get("--experiment") is Some(experiment_path) else {
    fail("--experiment is required")
  }
  guard options.get("--output") is Some(output) else {
    fail("--output is required")
  }
  guard options.get("--library") is Some(library) else {
    fail("--library must name the matching native MuJoCo shared library")
  }
  let experiment_bytes = @fs.read_file(experiment_path).binary()
  let experiment = @json.parse(@utf8.decode_lossy(experiment_bytes))
  let dt = number(field(experiment, "control_dt_s"))
  let duration = number(field(experiment, "duration_s"))
  let revision = text(field(experiment, "source_revision"))
  let runtime = @physics.Runtime::open(library, scene)
  let names = runtime.joint_names()
  let episodes : Array[@physics.Episode] = []
  let episode_rows : Array[Json] = []
  let trials : Array[Json] = []
  let controllers = array(field(experiment, "controllers")).map(text)
  let case_rows = array(field(experiment, "cases"))
  for case_json in case_rows {
    let case : @physics.Case = @json.from_json(case_json)
    for seed_json in array(field(experiment, "seeds")) {
      let seed = number(seed_json).to_int()
      for controller in controllers {
        let rng = generator(seed, 0)
        let normal = () => {
          let u = rng.double()
          let v = rng.double()
          (-2.0 * @math.ln(if u <= 0 { 0.0000000000000001 } else { u })).sqrt() *
          @math.cos(2.0 * @math.PI * v)
        }
        let mut offset : Array[Double]? = None
        let mut schedule : @physics.JointSines? = None
        if case.motion == "pose_offset" || case.motion == "random_joint_sines" {
          let limits = field(case_json, "goal_offset_rad")
          let lower = number(field(limits, "lower"))
          let waist = number(field(limits, "waist"))
          let upper = number(field(limits, "upper"))
          if case.motion == "pose_offset" {
            let reference_rng = generator(seed, 1729)
            offset = Some(
              @physics.pose_offset(
                names,
                lower,
                waist,
                upper,
                Array::makei(names.length(), _ => reference_rng.double() * 2 - 1),
              ),
            )
          } else {
            let reference_rng = generator(seed, 2718)
            let amplitudes = @physics.pose_offset(
              names,
              lower,
              waist,
              upper,
              Array::make(names.length(), 1.0),
            )
            schedule = Some({
              amplitude: amplitudes.map(a => {
                a * (0.3 + 0.7 * reference_rng.double())
              }),
              bias: amplitudes.map(a => {
                a * (-0.2 + 0.4 * reference_rng.double())
              }),
              frequency_hz: Array::makei(names.length(), _ => {
                0.15 + 0.5 * reference_rng.double()
              }),
              phase_rad: Array::makei(names.length(), _ => {
                -@math.PI + 2 * @math.PI * reference_rng.double()
              }),
            })
          }
        }
        let noise = match experiment {
          Object(m) => m.get("action_noise_std_rad").map(number).unwrap_or(0.0)
          _ => 0.0
        }
        let started = @env.now()
        let (episode, trial) = runtime.rollout(
          case,
          seed,
          controller,
          duration,
          dt,
          normal,
          fall_height=number(field(experiment, "fall_height_m")),
          fall_upright=number(field(experiment, "fall_upright_z")),
          action_noise_std=noise,
          offset?,
          schedule?,
        )
        let wall = (@env.now() - started).to_double() / 1000
        let row = episode.to_json()
        if row is Object(m) {
          if offset is Some(offset) {
            m["reference_offset_rad"] = offset.to_json()
          }
          if schedule is Some(schedule) {
            m["reference_schedule"] = schedule.to_json()
          }
        }
        episode_rows.push(row)
        episodes.push(episode)
        let trial_row = trial.to_json()
        if trial_row is Object(m) {
          m["wall_seconds"] = wall.to_json()
        }
        trials.push(trial_row)
      }
    }
  }
  let summaries : Array[Json] = []
  for controller in controllers {
    let selected = trials.filter(t => {
      match t {
        Object(m) => m.get("controller") == Some(controller.to_json())
        _ => false
      }
    })
    let mut steps = 0.0
    let mut failed = 0
    let mut wall = 0.0
    let mut error = 0.0
    for t in selected {
      let count = number(field(t, "steps"))
      steps += count
      wall += number(field(t, "wall_seconds"))
      let rmse = number(field(t, "joint_rmse_rad"))
      error += rmse * rmse * count
      if field(t, "failed") is True {
        failed += 1
      }
    }
    let throughput : Double? = if wall > 0 { Some(steps / wall) } else { None }
    summaries.push({
      "controller": controller,
      "trials": selected.length(),
      "failed_trials": failed,
      "steps": steps,
      "pooled_joint_rmse_rad": (error / steps).sqrt(),
      "control_steps_per_second": throughput,
    })
  }
  let dataset = runtime.dataset(
    episodes,
    revision,
    dt~,
    episode_json=episode_rows,
  )
  if dataset is Object(m) {
    m["dt_s"] = dt.to_json()
  }
  let report : Json = {
    "format": "moonrobo.physics-evaluation.v1",
    "evidence_class": "physics-simulation",
    "purpose": "CPU collection and scoring baseline; not PPO or SuperMimic performance",
    "scene_sha256": sha(@fs.read_file(scene).binary()),
    "experiment_sha256": sha(experiment_bytes),
    "source_revision": revision,
    "experiment": experiment,
    "dataset_file": "dataset.json",
    "summaries": summaries,
    "trials": trials,
    "rng": "MoonBit ChaCha8/SHA256 stream seeds and Box-Muller; not NumPy PCG64 seed equivalent",
    "provider_language": "MoonBit/native MuJoCo",
  }
  if report is Object(m) {
    m["mujoco_version"] = runtime.version().to_json()
  }
  if !@fs.exists(output) {
    @fs.mkdir(output, recursive=true)
  }
  @fs.write_file(
    output + "/dataset.json",
    dataset.stringify(),
    create_mode=CreateOrTruncate,
  )
  @fs.write_file(
    output + "/report.json",
    report.stringify(indent=2),
    create_mode=CreateOrTruncate,
  )
  println(({ "output": output, "summaries": summaries } : Json).stringify())
}
