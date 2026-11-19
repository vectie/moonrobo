///|
fn field(v : Json, k : String) -> Json raise {
  @reference.json_field(v, k)
}

///|
fn text(v : Json, k : String) -> String raise {
  @reference.json_text(field(v, k))
}

///|
fn integer(v : Json, k : String) -> Int32 raise {
  @reference.json_integer(field(v, k))
}

///|
fn number(v : Json, k : String) -> Double raise {
  @reference.json_number(field(v, k))
}

///|
fn array(v : Json, k : String) -> Array[Json] raise {
  @reference.json_array(field(v, k))
}

///|
fn merge(a : Json, b : Json) -> Json raise {
  let result = @reference.json_fields(a)
  for key, value in @reference.json_fields(b) {
    result[key] = value
  }
  result.to_json()
}

///|
fn child(base : String, path : String) -> String {
  @reference.path_child(base, path)
}

///|
async fn digest(path : String) -> String {
  @artifacts.sha256(@fs.read_file(path).binary())
}

///|
async fn verify_hash(path : String, expected : String) -> Unit {
  guard digest(path) == expected else { fail("source bytes changed: " + path) }
}

///|
fn optional_adapter(config : Json) -> String? raise {
  match @reference.json_fields(config).get("torch_rng_adapter") {
    Some(value) => Some(@reference.json_text(value))
    None => None
  }
}

///|
/// Optional actual ATen CPU draws; portable draws never claim original Torch seed equivalence.
struct Sampler {
  native : @numeric.Rng
  torch : @torch_rng.Generator?
  adapter : String?
}

///|
fn Sampler::new(seed : Int32, adapter : String?) -> Sampler raise {
  {
    native: @numeric.Rng::new(seed.to_uint()),
    torch: match adapter {
      Some(path) => Some(@torch_rng.Generator::open(path, seed.to_int64()))
      None => None
    },
    adapter,
  }
}

///|
fn Sampler::indices(
  self : Sampler,
  high : Int32,
  count : Int32,
) -> Array[Int32] raise {
  match self.torch {
    Some(g) => g.indices(high, count)
    None => Array::makei(count, _ => self.native.index(high))
  }
}

///|
fn Sampler::state(self : Sampler) -> Json raise {
  match self.torch {
    Some(g) => {
      let state = g.state()
      {
        "backend": "aten-cpu",
        "state": state.to_array().map(b => b.to_int()).to_json(),
      }
    }
    None =>
      {
        "backend": "moonbit-xorshift32",
        "state": self.native.state().to_json(),
      }
  }
}

///|
fn Sampler::fork(self : Sampler) -> Sampler raise {
  let fork = Sampler::new(0, self.adapter)
  match (self.torch, fork.torch) {
    (Some(a), Some(b)) => b.restore(a.state())
    _ => fork.native.set_state(self.native.state())
  }
  guard self.state() == fork.state() else { fail("sampler fork differs") }
  fork
}

///|
fn Sampler::digest(self : Sampler) -> String raise {
  @artifacts.sha256(@utf8.encode(self.state().stringify()))
}

///|
fn raw_means(
  actor : @reference.ReferenceActor,
  points : Array[@reference.LearningPoint],
  schedule : @reference.ReferenceSchedule,
) -> Array[Double] {
  let result = []
  for point in points {
    let c = schedule.command(point.clip, point.step, actor.future_length)
    result.append(
      actor.latent_mean(point.history, c.current, c.future, c.valid),
    )
  }
  result
}

///|
fn rms_difference(a : Array[Double], b : Array[Double]) -> Double {
  guard a.length() == b.length() && !a.is_empty() else {
    abort("nonempty RMS shape")
  }
  let mut sum = 0.0
  for i in 0..<a.length() {
    let d = a[i] - b[i]
    sum += d * d
  }
  (sum / a.length().to_double()).sqrt()
}

///|
fn norm(a : Array[Double]) -> Double {
  let mut sum = 0.0
  for x in a {
    sum += x * x
  }
  sum.sqrt()
}

///|
fn dot(a : Array[Double], b : Array[Double]) -> Double {
  guard a.length() == b.length() else { abort("dot shape") }
  let mut sum = 0.0
  for i in 0..<a.length() {
    sum += a[i] * b[i]
  }
  sum
}

///|
fn objective(
  model : @training.Dynamics,
  actor : @reference.ReferenceActor,
  points : Array[@reference.LearningPoint],
  geometry : @balance.Kinematics,
  schedule : @reference.ReferenceSchedule,
  config : Json,
  route : @reference.FeedbackGradient,
  gradient : Bool,
) -> (Double, Int32, Array[Double]) raise {
  let tape = @numeric.Tape::new()
  let parameters = tape.vector(actor.parameters())
  let (value, active) = @reference.imagined_objective(
    tape,
    model,
    actor,
    parameters,
    None,
    points,
    geometry,
    schedule,
    integer(config, "imagination_horizon"),
    number(config, "gamma"),
    feedback_gradient=route,
    critic_tail=false,
  )
  guard @numeric.finite(value.value) else { fail("nonfinite route objective") }
  if gradient {
    tape.backward(value)
  }
  (
    value.value,
    active,
    if gradient {
      parameters.map(p => tape.gradient(p))
    } else {
      []
    },
  )
}

///|
fn route_name(route : @reference.FeedbackGradient) -> String {
  match route {
    Full => "full"
    StopPolicyInputs => "stop-policy-inputs"
  }
}

///|
fn route(value : String) -> @reference.FeedbackGradient raise {
  match value {
    "full" => @reference.Full
    "stop-policy-inputs" => @reference.StopPolicyInputs
    _ => fail("unknown actor feedback gradient route")
  }
}

///|
fn actor_origin_ids(
  batch : @reference.CollectedBatch,
  config : Json,
  sampler : Sampler,
) -> Array[Int32] raise {
  let mode = @reference.json_text(
    @reference.config_default(
      config,
      "actor_origin_sampling",
      "reset-starts".to_json(),
    ),
  )
  let candidates = @reference.actor_origin_candidates(
    batch.episode_lengths,
    trajectory_states=mode == "trajectory-states",
  )
  guard mode == "trajectory-states" || mode == "reset-starts" else {
    fail("unknown actor origin sampling")
  }
  sampler
  .indices(candidates.length(), integer(config, "actor_batch_size"))
  .map(i => candidates[i])
}

///|
/// Full original calibrated Adam actor loop, including calibration draw consumption and exact origin records.
fn optimize_actor(
  model : @training.Dynamics,
  actor : @reference.ReferenceActor,
  optimizer : @numeric.Adam,
  batch : @reference.CollectedBatch,
  geometry : @balance.Kinematics,
  schedule : @reference.ReferenceSchedule,
  config : Json,
  sampler : Sampler,
  feedback : @reference.FeedbackGradient,
) -> Json raise {
  let original_model = model.network.parameters.copy()
  let cap = @reference.json_fields(config)
    .get("actor_logit_rms_cap")
    .map(@reference.json_number)
  let calibration = match cap {
    Some(bound) => {
      guard bound > 0 else { fail("positive actor logit cap required") }
      sampler
      .indices(
        batch.points.length(),
        integer(config, "actor_calibration_batch_size"),
      )
      .map(i => batch.points[i])
    }
    None => []
  }
  let samples : Array[Json] = []
  let scales : Array[Json] = []
  let mut last_objective = 0.0
  let mut last_norm = 0.0
  let mut total_active = 0
  for _ in 0..<integer(config, "maximum_actor_steps_per_cycle") {
    let ids = actor_origin_ids(batch, config, sampler)
    let points = ids.map(i => batch.points[i])
    let ages = points.map(p => p.step - p.origin)
    let mut min_age = ages[0]
    let mut max_age = ages[0]
    let mut age_sum = 0
    let mut nonreset = 0
    for age in ages {
      min_age = min_age.min(age)
      max_age = max_age.max(age)
      age_sum += age
      if age > 0 {
        nonreset += 1
      }
    }
    samples.push({
      "replay_indices": ids.to_json(),
      "minimum_age_steps": min_age.to_json(),
      "maximum_age_steps": max_age.to_json(),
      "mean_age_steps": (age_sum.to_double() / ages.length().to_double())
      .to_float()
      .to_double()
      .to_json(),
      "nonreset_samples": nonreset.to_json(),
    })
    let (value, active, gradient) = objective(
      model, actor, points, geometry, schedule, config, feedback, true,
    )
    let base = actor.parameters()
    let old_means = if calibration.is_empty() {
      []
    } else {
      raw_means(actor, calibration, schedule)
    }
    let tape = @numeric.Tape::new()
    let bound = tape.vector(base)
    let mut loss = tape.scalar(0)
    for i in 0..<bound.length() {
      loss = tape.add(loss, tape.scale(bound[i], -gradient[i]))
    }
    tape.backward(loss)
    let parameters = base.copy()
    last_norm = optimizer.step(parameters, tape, bound)
    actor.set_parameters(parameters)
    if cap is Some(cap) {
      let proposed = rms_difference(
        raw_means(actor, calibration, schedule),
        old_means,
      )
      guard @numeric.finite(proposed) else {
        fail("nonfinite proposed logit step")
      }
      let mut applied = proposed
      let mut scale = 1.0
      if applied > cap {
        scale = 0.99 * cap / applied
        actor.set_parameters(
          Array::makei(base.length(), i => {
            base[i] + scale * (parameters[i] - base[i])
          }),
        )
        applied = rms_difference(
          raw_means(actor, calibration, schedule),
          old_means,
        )
        while applied > cap {
          scale *= 0.5
          actor.set_parameters(
            Array::makei(base.length(), i => {
              base[i] + scale * (parameters[i] - base[i])
            }),
          )
          applied = rms_difference(
            raw_means(actor, calibration, schedule),
            old_means,
          )
          guard @numeric.finite(applied) else {
            fail("nonfinite calibrated logit step")
          }
        }
      }
      scales.push({
        "proposed_logit_rms": proposed.to_json(),
        "applied_logit_rms": applied.to_json(),
        "parameter_step_scale": scale.to_json(),
      })
    }
    last_objective = value
    total_active += active
  }
  guard model.network.parameters == original_model else {
    fail("actor optimization changed frozen dynamics")
  }
  {
    "actor_steps": field(config, "maximum_actor_steps_per_cycle"),
    "active_imagined_steps": total_active.to_json(),
    "last_objective": last_objective.to_json(),
    "last_gradient_norm": last_norm.to_json(),
    "frozen_model_unchanged": true,
    "critic_tail_used": false,
    "origin_sampling": @reference.config_default(
      config,
      "actor_origin_sampling",
      "reset-starts".to_json(),
    ),
    "actor_origin_samples": samples.to_json(),
    "logit_step_calibration": scales.to_json(),
  }
}

///|
async fn initial_actor_path(folder : String) -> String {
  for suffix in [".moon.json", ".json", ".pt"] {
    let path = folder + "/initial/actor-zero-output" + suffix
    if @fs.exists(path) {
      return path
    }
  }
  fail("initial actor checkpoint absent")
}

///|
fn record_map(report : Json) -> Map[String, Json] raise {
  let result : Map[String, Json] = Map([])
  for record in array(report, "physical_records") {
    result[text(record, "episode_id")] = record
  }
  result
}

///|
async fn save_direction(
  path : String,
  actor : @reference.ReferenceActor,
  direction : Array[Double],
  base_sha : String,
  metadata : Json,
) -> String {
  let checkpoint = @artifacts.Checkpoint::new(
    "moonrobo.g1-reference-parameter-direction.moonbit.v1",
    merge(metadata, {
      "base_actor_sha256": base_sha.to_json(),
      "parameter_names": actor.parameter_names().to_json(),
    }),
  )
  checkpoint.put("direction", [direction.length()], direction)
  @artifacts.save_checkpoint(path, checkpoint)
}

///|
fn physical_returns(
  batch : @reference.CollectedBatch,
  clips : Array[Int32],
  gamma : Double,
) -> Array[Json] {
  let results : Array[Json] = []
  let mut first = 0
  for i in 0..<batch.episode_lengths.length() {
    let length = batch.episode_lengths[i]
    let mut prefix_return = 0.0
    let mut full_return = 0.0
    let mut discount = 1.0
    for j in 0..<length {
      let value = discount * batch.reward[first + j]
      full_return += value
      if j < 32 {
        prefix_return += value
      }
      discount *= gamma
    }
    results.push({
      "clip_index": clips[i].to_json(),
      "prefix_return": prefix_return.to_json(),
      "full_return": full_return.to_json(),
    })
    first += length
  }
  results
}
