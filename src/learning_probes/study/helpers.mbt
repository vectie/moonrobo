///|
fn field(v : Json, key : String) -> Json raise {
  guard v is Object(m) && m.get(key) is Some(x) else {
    fail("missing field: " + key)
  }
  x
}

///|
fn num(v : Json, key : String) -> Double raise {
  @json.from_json(field(v, key))
}

///|
fn int(v : Json, key : String) -> Int32 raise {
  @json.from_json(field(v, key))
}

///|
fn str(v : Json, key : String) -> String raise {
  @json.from_json(field(v, key))
}

///|
fn arr(v : Json, key : String) -> Array[Json] raise {
  @json.from_json(field(v, key))
}

///|
fn ints(v : Json, key : String) -> Array[Int32] raise {
  @json.from_json(field(v, key))
}

///|
fn nums(v : Json, key : String) -> Array[Double] raise {
  @json.from_json(field(v, key))
}

///|
fn optional(v : Json, key : String, fallback : Json) -> Json {
  match v {
    Object(m) => m.get(key).unwrap_or(fallback)
    _ => fallback
  }
}

///|
fn boolean(v : Json, key : String, fallback : Bool) -> Bool raise {
  @json.from_json(optional(v, key, fallback.to_json()))
}

///|
fn option(o : Map[String, String], key : String) -> String raise {
  guard o.get(key) is Some(v) else { fail("required " + key) }
  v
}

///|
async fn read(path : String) -> Json {
  @json.parse(@fs.read_file(path).text())
}

///|
async fn digest(path : String) -> String {
  @artifacts.sha256(@fs.read_file(path).binary())
}

///|
async fn write(path : String, value : Json) -> Unit {
  let parts = path.split("/").to_array()
  let directories : Array[String] = []
  for i in 0..<(parts.length() - 1) {
    directories.push(parts[i].to_owned())
  }
  let directory = directories.join("/")
  if directory != "" && !@fs.exists(directory) {
    @fs.mkdir(directory, recursive=true)
  }
  @fs.write_file(path, value.stringify(indent=2), create_mode=CreateOrTruncate)
}

///|
fn average(a : Array[Double]) -> Double? {
  if a.is_empty() {
    None
  } else {
    let mut total = 0.0
    for x in a {
      total += x
    }
    Some(total / a.length().to_double())
  }
}

///|
fn max_error(
  a : Array[Array[Double]],
  b : Array[Array[Double]],
) -> Double raise {
  if a.length() != b.length() {
    fail("restored trajectory length differs")
  }
  let mut maximum = 0.0
  for i, x in a {
    if x.length() != b[i].length() {
      fail("restored state width differs")
    }
    for j, v in x {
      let d = (v - b[i][j]).abs()
      if d > maximum {
        maximum = d
      }
    }
  }
  maximum
}

///|
struct Snapshot {
  case_id : String
  seed : Int32
  step : Int32
  state : Array[Double]
  integration : Array[Double]
  previous : Array[Double]
  goal : Array[Double]
  context : Array[Double]
}

///|
struct Collection {
  episode : @physics.Episode
  trial : @physics.Trial
  snapshots : Array[Snapshot]
}

///|
fn collect(
  runtime : @physics.Runtime,
  case_json : Json,
  seed : Int32,
  experiment : Json,
  steps : Array[Int32],
  actor : @training.Actor?,
) -> Collection raise {
  let case : @physics.Case = @json.from_json(case_json)
  let rng = @numeric.Rng::new(seed.to_uint() + 1U)
  let names = runtime.joint_names()
  let mut offset : Array[Double]? = None
  let mut schedule : @physics.JointSines? = None
  if case.motion == "pose_offset" || case.motion == "random_joint_sines" {
    let limits = field(case_json, "goal_offset_rad")
    let stream = @numeric.Rng::new(
      seed.to_uint() +
      (if case.motion == "pose_offset" { 1729U } else { 2718U }),
    )
    let amplitude = @physics.pose_offset(
      names,
      num(limits, "lower"),
      num(limits, "waist"),
      num(limits, "upper"),
      Array::make(names.length(), 1.0),
    )
    if case.motion == "pose_offset" {
      offset = Some(amplitude.map(a => a * (stream.uniform() * 2 - 1)))
    } else {
      schedule = Some({
        amplitude: amplitude.map(a => a * (0.3 + 0.7 * stream.uniform())),
        bias: amplitude.map(a => a * (-0.2 + 0.4 * stream.uniform())),
        frequency_hz: names.map(_ => 0.15 + 0.5 * stream.uniform()),
        phase_rad: names.map(_ => -@math.PI + 2 * @math.PI * stream.uniform()),
      })
    }
  }
  let snapshots : Array[Snapshot] = []
  let controls : Array[Array[Double]] = []
  let trace = (i : Int32, action : Array[Double], goal : Array[Double]) => {
    if steps.contains(i) {
      let previous = if i == 0 {
        let s = runtime.state()
        try! runtime.clip_control(runtime.q_indices().map(q => s[q]))
      } else {
        controls[i - 1].copy()
      }
      snapshots.push({
        case_id: case.id,
        seed,
        step: i,
        state: runtime.state(),
        integration: runtime.integration(),
        previous,
        goal: goal.copy(),
        context: [case.friction, 1.0],
      })
    }
    controls.push(action.copy())
  }
  let policy = actor.map(a => (obs, goal) => a.predict(obs, goal))
  let (episode, trial) = runtime.rollout(
    case,
    seed,
    if actor is Some(_) {
      "policy"
    } else {
      "position"
    },
    num(experiment, "duration_s"),
    num(experiment, "control_dt_s"),
    () => rng.normal(),
    fall_height=num(experiment, "fall_height_m"),
    fall_upright=num(experiment, "fall_upright_z"),
    policy?,
    trace~,
    offset?,
    schedule?,
  )
  { episode, trial, snapshots, }
}

///|
fn ad_score(
  tape : @numeric.Tape,
  states : Array[Array[@numeric.Value]],
  actions : Array[Array[@numeric.Value]],
  previous : Array[Double],
  goals : Array[Array[Double]],
  q_indices : Array[Int32],
  height : Double,
  gamma : Double,
) -> @numeric.Value {
  let mut prev = tape.vector(previous)
  let mut total = tape.scalar(0)
  let mut survival = tape.scalar(1)
  let mut discount = 1.0
  for i, action in actions {
    let (reward, continuation) = @training.step_reward(
      tape,
      states[i],
      action,
      prev,
      tape.vector(goals[i]),
      q_indices,
      height,
    )
    total = tape.add(total, tape.scale(tape.mul(survival, reward), discount))
    survival = tape.mul(survival, continuation)
    discount *= gamma
    prev = action
  }
  total
}

///|
fn objective(
  model : @training.Dynamics,
  actor : @training.Actor,
  critic : @training.Critic,
  starts : Array[@training.ActorStart],
  parameters : Array[Double],
  config : Json,
  bootstrap : Bool,
) -> (Double, Array[Double]) raise {
  let tape = @numeric.Tape::new()
  let bound = tape.vector(parameters)
  let dp = model.network.bind(tape)
  let cp = critic.network.bind(tape)
  let cfg : @training.RolloutConfig = {
    horizon: int(config, "horizon"),
    gamma: num(config, "gamma"),
    target_height: num(config, "target_height_m"),
    bootstrap,
  }
  let outputs = starts.map(s => {
    @training.imagined_rollout(
      model,
      actor,
      critic,
      tape,
      dp,
      bound,
      cp,
      tape.vector(s.state),
      tape.vector(s.previous),
      tape.vector(s.goal),
      tape.vector(s.context),
      cfg,
    ).objective
  })
  if outputs.is_empty() {
    fail("no actor probe starts")
  }
  let value = tape.mean(outputs)
  tape.backward(value)
  (value.value, bound.map(p => tape.gradient(p)))
}

///|
fn candidate(
  actor : @training.Actor,
  delta : Array[Double],
  scale : Double,
) -> @training.Actor raise {
  let clone = @training.actor_from_checkpoint(actor.checkpoint({}))
  let parameters = @probes.scaled_actor(actor.network.parameters, delta, scale)
  for i, v in parameters {
    clone.network.parameters[i] = v
  }
  clone
}

///|
fn origin(s : Snapshot) -> @probes.Origin {
  {
    integration: s.integration,
    previous: s.previous,
    goal: s.goal,
    context: s.context,
  }
}

///|
fn physical(
  runtime : @physics.Runtime,
  s : Snapshot,
  actor : @training.Actor,
  critic : @training.Critic,
  config : Json,
  dt : Double,
) -> (@probes.PhysicalOutcome, Array[Array[Double]], Array[Array[Double]]) raise {
  @probes.physical_window(
    runtime,
    origin(s),
    (o, g) => actor.predict(o, g),
    (s, g, c) => critic.predict(s, g, c),
    int(config, "horizon"),
    dt,
    num(config, "gamma"),
    num(config, "target_height_m"),
    num(config, "fall_height_m"),
    num(config, "fall_upright_z"),
    bootstrap=boolean(config, "actor_critic_bootstrap", true),
  )
}

///|
async fn checkpoint_path(directory : String, stem : String) -> String {
  let native = directory + "/" + stem + ".moon.json"
  if @fs.exists(native) {
    native
  } else {
    directory + "/" + stem + ".pt"
  }
}

///|
fn torch_metadata(payload : @artifacts.TorchValue) -> Json {
  let metadata : Map[String, Json] = {}
  for
    key in [
      "config", "body", "training_batch_sha256", "layout", "selected_update", "online_model_round",
      "paired_dynamics_sha256", "initialization",
    ] {
    try payload.field(key).plain_json() catch {
      _ => ()
    } noraise {
      value => metadata[key] = value
    }
  }
  metadata.to_json()
}

///|
async fn load_dynamics(path : String) -> (@training.Dynamics, Json) {
  let cp = @training.load_learning_checkpoint(path, "residual-dynamics")
  (@training.dynamics_from_checkpoint(cp), cp.metadata)
}

///|
async fn load_policy(
  path : String,
) -> (@training.Actor, @training.Critic, Json) {
  let cp = @training.load_learning_checkpoint(path, "g1-actor")
  let actor = @training.actor_from_checkpoint(cp)
  (
    actor,
    @training.critic_from_actor_checkpoint(
      cp,
      actor.goal_stats.mean.length(),
      2,
    ),
    cp.metadata,
  )
}
