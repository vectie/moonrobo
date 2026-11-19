///|
fn torch_int(value : @artifacts.TorchValue) -> Int32 raise {
  let n : Int32 = @json.from_json(value.plain_json())
  guard n >= 0 else { fail("nonnegative Torch temporal dimension required") }
  n
}

///|
fn torch_stat(
  weights : @artifacts.TorchValue,
  name : String,
) -> Array[Double] raise {
  let t = weights.field(name).tensor()
  guard t.shape.length() == 1 &&
    t.shape[0] == t.values.length() &&
    t.values.all(@numeric.finite) else {
    fail("invalid Torch temporal statistic: " + name)
  }
  t.values.copy()
}

///|
fn spec_int(spec : Json, name : String) -> Int32 raise {
  guard spec is Object(fields) && fields.get(name) is Some(value) else {
    fail("missing temporal critic spec field: " + name)
  }
  let number : Int32 = @json.from_json(value)
  guard number >= 0 else { fail("negative temporal critic dimension") }
  number
}

///|
fn spec_double(spec : Json, name : String) -> Double raise {
  guard spec is Object(fields) && fields.get(name) is Some(value) else {
    fail("missing temporal critic spec field: " + name)
  }
  let number : Double = @json.from_json(value)
  guard @numeric.finite(number) else {
    fail("nonfinite temporal critic specification")
  }
  number
}

///|
/// Structural import of legacy Torch temporal actors. Dense tensor shapes and the explicit parent prefix are checked; no Python process is invoked.
pub fn temporal_from_torch_payload(
  payload : @artifacts.TorchValue,
) -> TemporalPolicy raise {
  guard payload.field("format").plain_json() == "moonrobo.g1-temporal-actor.v1" else {
    fail("expected legacy temporal actor checkpoint")
  }
  let weights = payload.field("actor")
  let body_value = payload.field("body")
  let q_indices : Array[Int32] = @json.from_json(
    body_value.field("q_indices").plain_json(),
  )
  let v_state_indices : Array[Int32] = @json.from_json(
    body_value.field("v_state_indices").plain_json(),
  )
  let body : @training.Body = {
    q_indices,
    v_state_indices,
    nq: torch_int(body_value.field("nq")),
  }
  let base = @training.actor_from_torch_state(
    weights,
    payload.field("base_config").plain_json(),
    body,
    prefix="base.",
  )
  let actor = TemporalPolicy::new(
    base,
    torch_int(payload.field("history_length")),
    torch_int(payload.field("future_length")),
    torch_int(payload.field("adapter_width")),
    @numeric.Rng::new(1U),
  )
  @training.import_torch_mlp(actor.temporal.adapter, weights, "adapter.")
  actor
}

///|
pub fn value_from_torch_payload(
  payload : @artifacts.TorchValue,
) -> TemporalValue raise {
  guard payload.field("format").plain_json() == "moonrobo.g1-temporal-actor.v1" &&
    payload.field("critic_status").plain_json() ==
    "finite-horizon-physical-return" else {
    fail("legacy checkpoint has no calibrated temporal value")
  }
  let weights = payload.field("critic")
  let spec = payload.field("critic_spec").plain_json()
  let state_mean = torch_stat(weights, "state_mean")
  let state_scale = torch_stat(weights, "state_scale")
  let obs_mean = torch_stat(weights, "obs_mean")
  let obs_scale = torch_stat(weights, "obs_scale")
  let goal_mean = torch_stat(weights, "goal_mean")
  let goal_scale = torch_stat(weights, "goal_scale")
  let context_mean = torch_stat(weights, "context_mean")
  let context_scale = torch_stat(weights, "context_scale")
  for
    (mean, scale) in [
      (state_mean, state_scale),
      (obs_mean, obs_scale),
      (goal_mean, goal_scale),
      (context_mean, context_scale),
    ] {
    guard mean.length() == scale.length() && scale.all(fn(v) { v > 0.0 }) else {
      fail("invalid Torch temporal value normalization")
    }
  }
  let features = state_mean.length() +
    spec_int(spec, "history_length") * obs_mean.length() +
    (spec_int(spec, "future_length") + 1) * goal_mean.length() +
    context_mean.length() +
    1
  let net = @numeric.MLP::new(
    [features, spec_int(spec, "width"), 64, 1],
    @numeric.Rng::new(1U),
  )
  @training.import_torch_mlp(net, weights, "net.")
  let gamma = spec_double(spec, "gamma")
  let dt = spec_double(spec, "dt_s")
  let duration = spec_double(spec, "duration_s")
  guard gamma > 0.0 && gamma < 1.0 && dt > 0.0 && duration > 0.0 else {
    fail("invalid Torch finite-value cadence or discount")
  }
  {
    state_mean,
    state_scale,
    obs_mean,
    obs_scale,
    goal_mean,
    goal_scale,
    context_mean,
    context_scale,
    gamma,
    dt,
    duration,
    fall_height: spec_double(spec, "fall_height_m"),
    fall_upright: spec_double(spec, "fall_upright_z"),
    net,
  }
}

///|
pub async fn load_torch_temporal(
  path : String,
  expected_sha256? : String,
) -> (TemporalPolicy, @artifacts.TorchValue) {
  let payload = @artifacts.load_torch_checkpoint(path, expected_sha256?)
  (temporal_from_torch_payload(payload), payload)
}

///|
pub async fn load_torch_value(
  path : String,
  expected_sha256? : String,
) -> (TemporalValue, @artifacts.TorchValue) {
  let payload = @artifacts.load_torch_checkpoint(path, expected_sha256?)
  (value_from_torch_payload(payload), payload)
}
