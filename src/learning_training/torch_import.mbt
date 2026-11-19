///|
fn torch_vector(
  weights : @artifacts.TorchValue,
  name : String,
  finite~ : Bool = true,
) -> Array[Double] raise {
  let tensor = weights.field(name).tensor()
  guard tensor.shape.length() == 1 && tensor.shape[0] == tensor.values.length() else {
    fail("Torch vector shape differs: " + name)
  }
  guard tensor.values.all(v => if finite { @numeric.finite(v) } else { v == v }) else {
    fail("invalid Torch vector values: " + name)
  }
  tensor.values.copy()
}

///|
fn torch_normalization(
  weights : @artifacts.TorchValue,
  mean_name : String,
  scale_name : String,
) -> @numeric.Normalization raise {
  let mean = torch_vector(weights, mean_name)
  let scale = torch_vector(weights, scale_name)
  guard mean.length() == scale.length() && scale.all(v => v > 0) else {
    fail("invalid Torch normalization")
  }
  { mean, scale, }
}

///|
fn require_torch_keys(
  weights : @artifacts.TorchValue,
  prefix : String,
  buffers : Array[String],
) -> Unit raise {
  guard weights is @artifacts.TorchDict(fields) else {
    fail("Torch state_dict required")
  }
  let allowed = buffers.copy()
  for layer in [0, 2, 4] {
    allowed.push("net.\{layer}.weight")
    allowed.push("net.\{layer}.bias")
  }
  let mut count = 0
  for key, _ in fields {
    if key.has_prefix(prefix) {
      let suffix = key.strip_prefix(prefix).unwrap().to_owned()
      guard allowed.contains(suffix) else {
        fail("unexpected Torch state_dict key: " + key)
      }
      count += 1
    }
  }
  guard count == allowed.length() else {
    fail("Torch state_dict key set differs")
  }
}

///|
/// Exact parameter-name/shape mapping for the legacy Linear/SiLU/Linear/SiLU/Linear
/// network. Does not reinterpret arbitrary module checkpoints as this architecture.
pub fn import_torch_mlp(
  network : @numeric.MLP,
  weights : @artifacts.TorchValue,
  prefix : String,
) -> Unit raise {
  let parameters : Array[Double] = []
  for layer in 0..<(network.dimensions.length() - 1) {
    let name = prefix + (2 * layer).to_string()
    let weight = weights.field(name + ".weight").tensor()
    let bias = weights.field(name + ".bias").tensor()
    let nin = network.dimensions[layer]
    let nout = network.dimensions[layer + 1]
    guard weight.shape == [nout, nin] &&
      weight.values.length() == nin * nout &&
      bias.shape == [nout] &&
      bias.values.length() == nout else {
      fail("Torch dense layer shape differs: " + name)
    }
    guard weight.values.all(@numeric.finite) && bias.values.all(@numeric.finite) else {
      fail("nonfinite Torch layer: " + name)
    }
    parameters.append(weight.values)
    parameters.append(bias.values)
  }
  guard parameters.length() == network.parameters.length() else {
    fail("Torch MLP parameter count differs")
  }
  restore_parameters(network, parameters)
}

///|
pub fn actor_from_torch_state(
  weights : @artifacts.TorchValue,
  config : Json,
  body : Body,
  prefix~ : String = "",
) -> Actor raise {
  require_torch_keys(weights, prefix, [
    "obs_mean", "obs_scale", "goal_mean", "goal_scale", "lower", "upper",
  ])
  let obs = torch_normalization(
    weights,
    prefix + "obs_mean",
    prefix + "obs_scale",
  )
  let goal = torch_normalization(
    weights,
    prefix + "goal_mean",
    prefix + "goal_scale",
  )
  let lower = torch_vector(weights, prefix + "lower", finite=false)
  let upper = torch_vector(weights, prefix + "upper", finite=false)
  guard lower.length() == goal.mean.length() &&
    upper.length() == lower.length() &&
    !lower.is_empty() &&
    body.q_indices.length() == lower.length() &&
    body.v_state_indices.length() == lower.length() &&
    body.nq >= 7 else {
    fail("Torch actor body/bounds dimensions differ")
  }
  guard body.q_indices.all(i => i >= 0 && i < body.nq) &&
    body.v_state_indices.all(i => i >= body.nq) else {
    fail("invalid Torch actor state indices")
  }
  for i in 0..<lower.length() {
    guard lower[i] <= upper[i] &&
      lower[i] != 1.0 / 0.0 &&
      upper[i] != -1.0 / 0.0 else {
      fail("invalid Torch action bounds")
    }
  }
  let actor = Actor::new(
    obs,
    goal,
    lower,
    upper,
    json_double(json_field(config, "action_delta_rad")),
    body,
    json_int(json_field(config, "hidden_width")),
    @numeric.Rng::new(1U),
  )
  import_torch_mlp(actor.network, weights, prefix + "net.")
  actor
}

///|
pub fn actor_from_torch_payload(payload : @artifacts.TorchValue) -> Actor raise {
  guard payload.field("format").plain_json() == "moonrobo.g1-actor.v1" else {
    fail("legacy base-actor checkpoint format required")
  }
  let body = body_from_torch(payload.field("body"))
  actor_from_torch_state(
    payload.field("actor"),
    payload.field("config").plain_json(),
    body,
  )
}

///|
pub fn dynamics_from_torch_payload(
  payload : @artifacts.TorchValue,
) -> Dynamics raise {
  let format = payload.field("format").plain_json()
  let root = format == "moonrobo.g1-root-integrated-dynamics.v1"
  let config : Json = if root {
    Json::null()
  } else {
    payload.field("config").plain_json()
  }
  let encoding = if root {
    true
  } else {
    json_bool_default(config, "horizontal_translation_invariant", false)
  }
  guard root ||
    format ==
    (if encoding {
      "moonrobo.residual-dynamics.v2"
    } else {
      "moonrobo.residual-dynamics.v1"
    }) else {
    fail("legacy dynamics format does not match input encoding")
  }
  let weights = payload.field("model")
  require_torch_keys(weights, "", [
    "state_mean", "state_scale", "action_mean", "action_scale", "context_mean", "context_scale",
  ])
  let width = if root {
    json_int(payload.field("width").plain_json())
  } else {
    json_int(json_field(config, "hidden_width"))
  }
  let dt = if root {
    Some(json_double(payload.field("dt_s").plain_json()))
  } else {
    None
  }
  let model = Dynamics::new(
    torch_normalization(weights, "state_mean", "state_scale"),
    torch_normalization(weights, "action_mean", "action_scale"),
    torch_normalization(weights, "context_mean", "context_scale"),
    width,
    @numeric.Rng::new(1U),
    translation_invariant=encoding,
    root_integration_dt=dt,
  )
  import_torch_mlp(model.network, weights, "net.")
  model
}

///|
pub fn body_from_torch(value : @artifacts.TorchValue) -> Body raise {
  let body = value.plain_json()
  {
    q_indices: json_array(json_field(body, "q_indices")).map(json_int),
    v_state_indices: json_array(json_field(body, "v_state_indices")).map(
      json_int,
    ),
    nq: json_int(json_field(body, "nq")),
  }
}

///|
pub fn critic_from_torch_state(
  weights : @artifacts.TorchValue,
  config : Json,
  n_goal : Int32,
) -> Critic raise {
  require_torch_keys(weights, "", ["mean", "scale"])
  let stats = torch_normalization(weights, "mean", "scale")
  let first = weights.field("net.0.weight").tensor()
  guard first.shape.length() == 2 && first.shape[0] == 128 && n_goal > 0 else {
    fail("legacy critic input architecture differs")
  }
  let n_context = first.shape[1] - stats.mean.length() - n_goal
  guard n_context >= 0 else { fail("legacy critic input dimensions differ") }
  let critic = Critic::new(
    stats,
    n_goal,
    n_context,
    json_double(json_field(config, "gamma")),
    @numeric.Rng::new(1U),
    translation_invariant=json_bool_default(
      config, "critic_horizontal_translation_invariant", false,
    ),
  )
  import_torch_mlp(critic.network, weights, "net.")
  critic
}

///|
pub async fn load_torch_actor(
  path : String,
  expected_sha256? : String,
) -> (Actor, @artifacts.TorchValue) {
  let payload = @artifacts.load_torch_checkpoint(path, expected_sha256?)
  (actor_from_torch_payload(payload), payload)
}

///|
pub async fn load_torch_dynamics(
  path : String,
  expected_sha256? : String,
) -> (Dynamics, @artifacts.TorchValue) {
  let payload = @artifacts.load_torch_checkpoint(path, expected_sha256?)
  (dynamics_from_torch_payload(payload), payload)
}

///|
/// Preserve the ordinary experiment/provenance metadata while state_dict tensors
/// are mapped through explicit model-specific shape checks.
pub fn torch_checkpoint_metadata(payload : @artifacts.TorchValue) -> Json raise {
  guard payload is @artifacts.TorchDict(fields) else {
    fail("legacy checkpoint dictionary required")
  }
  let metadata : Map[String, Json] = {}
  for key, value in fields {
    if [
        "actor", "model", "critic", "optimizer", "actor_optimizer", "critic_optimizer",
        "model_optimizer",
      ].contains(key) {
      continue
    }
    metadata[key] = value.plain_json()
  }
  metadata["imported_from"] = "torch-numeric-state-dict"
  metadata["numeric_dtype"] = "float64"
  Json::object(metadata)
}

///|
/// Native JSON and allowlisted Torch ZIP checkpoints share one loading path.
/// The returned checkpoint is a native inference bundle, not an assertion that
/// an omitted Torch optimizer/RNG state can be resumed by a native optimizer.
pub async fn load_learning_checkpoint(
  path : String,
  kind : String,
  expected_sha256? : String,
) -> @artifacts.Checkpoint {
  let bytes = @fs.read_file(path).binary()
  if expected_sha256 is Some(expected) {
    guard @artifacts.sha256(bytes) == expected else {
      fail("learning checkpoint SHA256 differs")
    }
  }
  if bytes.length() >= 4 && bytes[0:4] == b"PK\x03\x04" {
    let payload = @artifacts.decode_torch_checkpoint(bytes)
    let metadata = torch_checkpoint_metadata(payload)
    match kind {
      "residual-dynamics" =>
        dynamics_from_torch_payload(payload).checkpoint(metadata)
      "g1-actor" => {
        let actor = actor_from_torch_payload(payload)
        let checkpoint = actor.checkpoint(metadata)
        if payload is @artifacts.TorchDict(fields) &&
          fields.get("critic") is Some(critic_weights) {
          critic_from_torch_state(
            critic_weights,
            payload.field("config").plain_json(),
            actor.goal_stats.mean.length(),
          ).put_checkpoint(checkpoint)
        }
        checkpoint
      }
      _ => fail("unsupported legacy learning model kind: " + kind)
    }
  } else {
    @artifacts.load_checkpoint(path, kind, expected_sha256?)
  }
}
