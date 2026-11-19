///|
fn put_vector(
  checkpoint : @artifacts.Checkpoint,
  name : String,
  values : Array[Double],
) -> Unit raise {
  checkpoint.put(name, [values.length()], values)
}

///|
pub fn TemporalPolicy::checkpoint(
  self : TemporalPolicy,
  metadata : Json,
) -> @artifacts.Checkpoint raise {
  let result = @artifacts.Checkpoint::new("temporal-actor", metadata)
  for
    (name, values) in [
      ("obs_mean", self.temporal.obs_mean),
      ("obs_scale", self.temporal.obs_scale),
      ("goal_mean", self.temporal.goal_mean),
      ("goal_scale", self.temporal.goal_scale),
      ("lower", self.base.lower),
      ("upper", self.base.upper),
      ("base.parameters", self.base.network.parameters),
      ("adapter.parameters", self.temporal.adapter.parameters),
    ] {
    put_vector(result, name, values)
  }
  put_vector(
    result,
    "base.dimensions",
    self.base.network.dimensions.map(fn(i) { i.to_double() }),
  )
  put_vector(
    result,
    "adapter.dimensions",
    self.temporal.adapter.dimensions.map(fn(i) { i.to_double() }),
  )
  put_vector(
    result,
    "q_indices",
    self.base.body.q_indices.map(fn(i) { i.to_double() }),
  )
  put_vector(
    result,
    "v_state_indices",
    self.base.body.v_state_indices.map(fn(i) { i.to_double() }),
  )
  put_vector(result, "spec", [
    self.temporal.history_length.to_double(),
    self.temporal.future_length.to_double(),
    self.base.action_delta_rad,
    self.base.body.nq.to_double(),
  ])
  result
}

///|
fn integers(values : Array[Double]) -> Array[Int32] raise {
  values.map(fn(v) {
    guard @numeric.finite(v) &&
      v >= 0.0 &&
      v <= 2147483647.0 &&
      v.to_int().to_double() == v else {
      fail("invalid integer checkpoint field")
    }
    v.to_int()
  })
}

///|
pub fn temporal_from_checkpoint(
  checkpoint : @artifacts.Checkpoint,
) -> TemporalPolicy raise {
  checkpoint.validate()
  guard checkpoint.model_kind == "temporal-actor" else {
    fail("expected temporal actor checkpoint")
  }
  let base_dimensions = integers(checkpoint.tensor("base.dimensions").values)
  let adapter_dimensions = integers(
    checkpoint.tensor("adapter.dimensions").values,
  )
  guard base_dimensions.length() == 4 && adapter_dimensions.length() == 4 else {
    fail("temporal actor requires two three-layer networks")
  }
  let spec = checkpoint.tensor("spec").values
  guard spec.length() == 4 else { fail("invalid temporal specification") }
  let lengths = integers([spec[0], spec[1], spec[3]])
  let obs_mean = checkpoint.tensor("obs_mean").values
  let obs_scale = checkpoint.tensor("obs_scale").values
  let goal_mean = checkpoint.tensor("goal_mean").values
  let goal_scale = checkpoint.tensor("goal_scale").values
  guard obs_mean.length() == obs_scale.length() &&
    goal_mean.length() == goal_scale.length() &&
    obs_scale.all(fn(v) { v > 0.0 }) &&
    goal_scale.all(fn(v) { v > 0.0 }) else {
    fail("invalid temporal normalization")
  }
  let base = @training.Actor::new(
    { mean: obs_mean, scale: obs_scale, },
    { mean: goal_mean, scale: goal_scale, },
    checkpoint.tensor("lower").values,
    checkpoint.tensor("upper").values,
    spec[2],
    {
      q_indices: integers(checkpoint.tensor("q_indices").values),
      v_state_indices: integers(checkpoint.tensor("v_state_indices").values),
      nq: lengths[2],
    },
    base_dimensions[1],
    @numeric.Rng::new(1U),
  )
  let actor = TemporalPolicy::new(
    base,
    lengths[0],
    lengths[1],
    adapter_dimensions[1],
    @numeric.Rng::new(1U),
  )
  guard base.network.dimensions == base_dimensions &&
    actor.temporal.adapter.dimensions == adapter_dimensions else {
    fail("checkpoint architecture disagrees with normalization")
  }
  let parameters = checkpoint.tensor("base.parameters").values
  parameters.append(checkpoint.tensor("adapter.parameters").values)
  guard parameters.length() == actor.parameters().length() else {
    fail("temporal actor parameter count differs")
  }
  actor.restore(parameters)
  actor
}

///|
pub fn TemporalValue::checkpoint(
  self : TemporalValue,
  metadata : Json,
) -> @artifacts.Checkpoint raise {
  let result = @artifacts.Checkpoint::new("temporal-value", metadata)
  for
    (name, values) in [
      ("state_mean", self.state_mean),
      ("state_scale", self.state_scale),
      ("obs_mean", self.obs_mean),
      ("obs_scale", self.obs_scale),
      ("goal_mean", self.goal_mean),
      ("goal_scale", self.goal_scale),
      ("context_mean", self.context_mean),
      ("context_scale", self.context_scale),
      ("parameters", self.net.parameters),
    ] {
    put_vector(result, name, values)
  }
  put_vector(
    result,
    "dimensions",
    self.net.dimensions.map(fn(i) { i.to_double() }),
  )
  put_vector(result, "spec", [
    self.gamma,
    self.dt,
    self.duration,
    self.fall_height,
    self.fall_upright,
  ])
  result
}

///|
pub fn value_from_checkpoint(
  checkpoint : @artifacts.Checkpoint,
) -> TemporalValue raise {
  checkpoint.validate()
  guard checkpoint.model_kind == "temporal-value" else {
    fail("expected temporal value checkpoint")
  }
  let spec = checkpoint.tensor("spec").values
  guard spec.length() == 5 &&
    spec[0] > 0.0 &&
    spec[0] < 1.0 &&
    spec[1] > 0.0 &&
    spec[2] > 0.0 else {
    fail("invalid temporal value specification")
  }
  let dimensions = integers(checkpoint.tensor("dimensions").values)
  let net = @numeric.MLP::new(dimensions, @numeric.Rng::new(1U))
  let parameters = checkpoint.tensor("parameters").values
  guard parameters.length() == net.parameters.length() else {
    fail("temporal value parameter count differs")
  }
  for i in 0..<parameters.length() {
    net.parameters[i] = parameters[i]
  }
  {
    state_mean: checkpoint.tensor("state_mean").values,
    state_scale: checkpoint.tensor("state_scale").values,
    obs_mean: checkpoint.tensor("obs_mean").values,
    obs_scale: checkpoint.tensor("obs_scale").values,
    goal_mean: checkpoint.tensor("goal_mean").values,
    goal_scale: checkpoint.tensor("goal_scale").values,
    context_mean: checkpoint.tensor("context_mean").values,
    context_scale: checkpoint.tensor("context_scale").values,
    gamma: spec[0],
    dt: spec[1],
    duration: spec[2],
    fall_height: spec[3],
    fall_upright: spec[4],
    net,
  }
}

///|
pub async fn save_temporal(
  path : String,
  actor : TemporalPolicy,
  metadata : Json,
) -> String {
  @artifacts.save_checkpoint(path, actor.checkpoint(metadata))
}

///|
pub async fn load_temporal(path : String) -> TemporalPolicy {
  if path.has_suffix(".pt") {
    temporal_from_torch_payload(@artifacts.load_torch_checkpoint(path))
  } else {
    temporal_from_checkpoint(@artifacts.load_checkpoint(path, "temporal-actor"))
  }
}

///|
pub async fn save_value(
  path : String,
  value : TemporalValue,
  metadata : Json,
) -> String {
  @artifacts.save_checkpoint(path, value.checkpoint(metadata))
}

///|
pub async fn load_value(path : String) -> TemporalValue {
  if path.has_suffix(".pt") {
    value_from_torch_payload(@artifacts.load_torch_checkpoint(path))
  } else {
    let checkpoint : @artifacts.Checkpoint = @json.from_json(
      @artifacts.load_json(path),
    )
    checkpoint.validate()
    if checkpoint.model_kind == "temporal-value" {
      value_from_checkpoint(checkpoint)
    } else {
      guard checkpoint.model_kind == "temporal-actor" &&
        checkpoint.metadata is Object(fields) &&
        fields.get("temporal_value_checkpoint") is Some(encoded) else {
        fail(
          "native actor checkpoint has no embedded calibrated temporal value",
        )
      }
      let value_checkpoint : @artifacts.Checkpoint = @json.from_json(encoded)
      value_from_checkpoint(value_checkpoint)
    }
  }
}

///|
/// PPO requires the exact actor paired with initial physical-return value calibration. Preserve the legacy initialization hash and update-zero guard for imported Torch payloads.
pub async fn load_paired_value(
  path : String,
  actor_sha256 : String,
) -> TemporalValue {
  if path.has_suffix(".pt") {
    let payload = @artifacts.load_torch_checkpoint(path)
    let initialization = payload.field("initialization")
    guard initialization.field("sha256").plain_json() == actor_sha256.to_json() &&
      initialization.field("critic_actor_update").plain_json() == 0 else {
      fail("PPO requires the incoming actor's initial calibrated legacy value")
    }
    value_from_torch_payload(payload)
  } else {
    let checkpoint = @artifacts.load_checkpoint(path, "temporal-value")
    guard checkpoint.metadata is Object(meta) &&
      meta.get("actor_checkpoint_sha256") is Some(String(expected)) &&
      expected == actor_sha256 &&
      meta.get("critic_actor_update") is Some(Number(0.0, ..)) &&
      meta.get("calibrated") is Some(True) else {
      fail("PPO requires calibrated value paired with the exact incoming actor")
    }
    value_from_checkpoint(checkpoint)
  }
}
