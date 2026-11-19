///|
fn torch_vector(value : @artifacts.TorchValue) -> Array[Double] raise {
  let tensor = value.tensor()
  guard tensor.shape.length() == 1 else { fail("expected Torch vector") }
  tensor.values
}

///|
fn torch_dense(
  state : @artifacts.TorchValue,
  prefix : String,
  activation : Activation,
) -> Dense raise {
  let weight = state.field(prefix + ".weight").tensor()
  let bias = torch_vector(state.field(prefix + ".bias"))
  guard weight.shape.length() == 2 && weight.shape[0] == bias.length() else {
    fail("Torch Linear shape mismatch")
  }
  let width = weight.shape[1]
  {
    weight: Array::makei(weight.shape[0], i => {
      weight.values[i * width:(i + 1) * width].to_owned()
    }),
    bias,
    activation,
  }
}

///|
pub fn reference_actor_from_torch(
  checkpoint : @artifacts.TorchValue,
) -> (ReferenceActor, ActorMetadata) raise {
  guard json_text(checkpoint.field("format").plain_json()) ==
    "moonrobo.g1-reference-actor.v1" else {
    fail("expected full-reference Torch actor")
  }
  let state = checkpoint.field("state_dict")
  let architecture = checkpoint.field("architecture").plain_json()
  let actor : ReferenceActor = {
    nu: json_integer(json_field(architecture, "nu")),
    history_length: json_integer(json_field(architecture, "history_length")),
    future_length: json_integer(json_field(architecture, "future_length")),
    output_bound: json_number(json_field(architecture, "output_bound")),
    indices: @json.from_json(json_field(architecture, "indices")),
    obs_mean: torch_vector(state.field("obs_mean")),
    obs_scale: torch_vector(state.field("obs_scale")),
    goal_mean: torch_vector(state.field("goal_mean")),
    goal_scale: torch_vector(state.field("goal_scale")),
    lower: torch_vector(state.field("lower")),
    upper: torch_vector(state.field("upper")),
    feedback_coefficients: {
      let coefficients = state.field("feedback_coefficients").tensor()
      guard coefficients.shape == [4, 5] else {
        fail("Torch feedback must have four five-channel rows")
      }
      Array::makei(4, i => coefficients.values[i * 5:i * 5 + 5].to_owned())
    },
    goal_encoder: [
      torch_dense(state, "goal_encoder.0", Silu),
      torch_dense(state, "goal_encoder.2", Silu),
      torch_dense(state, "goal_encoder.4", Tanh),
    ],
    observation_encoder: [
      torch_dense(state, "observation_encoder.0", Silu),
      torch_dense(state, "observation_encoder.2", Silu),
    ],
    decoder: [
      torch_dense(state, "decoder.0", Silu),
      torch_dense(state, "decoder.2", Linear),
    ],
  }
  actor.validate()
  guard actor.goal_mean.length() ==
    json_integer(json_field(architecture, "goal_dim")) &&
    actor.goal_encoder[0].bias.length() ==
    json_integer(json_field(architecture, "width")) &&
    actor.goal_encoder[2].bias.length() ==
    json_integer(json_field(architecture, "latent_dim")) else {
    fail("Torch reference architecture disagrees with stored weights")
  }
  let metadata : ActorMetadata = {
    architecture_and_weights: actor,
    kinematics: checkpoint.field("kinematics").plain_json(),
    dt_s: json_number(checkpoint.field("dt_s").plain_json()),
    provenance: checkpoint.field("provenance").plain_json(),
    critic_status: json_text(checkpoint.field("critic_status").plain_json()),
    physical_execution_allowed: json_boolean(
      checkpoint.field("physical_execution_allowed").plain_json(),
    ),
  }
  guard !metadata.physical_execution_allowed && metadata.dt_s > 0.0 else {
    fail("invalid reference Torch actor metadata")
  }
  (actor, metadata)
}

///|
pub fn reference_value_from_torch(
  checkpoint : @artifacts.TorchValue,
  clips : Int32,
) -> ReferenceValue raise {
  let state = checkpoint.field("state_dict")
  {
    state_mean: torch_vector(state.field("state_mean")),
    state_scale: torch_vector(state.field("state_scale")),
    obs_mean: torch_vector(state.field("obs_mean")),
    obs_scale: torch_vector(state.field("obs_scale")),
    goal_mean: torch_vector(state.field("goal_mean")),
    goal_scale: torch_vector(state.field("goal_scale")),
    clips,
    net: [
      torch_dense(state, "net.0", Silu),
      torch_dense(state, "net.2", Silu),
      torch_dense(state, "net.4", Linear),
    ],
  }
}

///|
pub fn dynamics_from_torch(
  checkpoint : @artifacts.TorchValue,
) -> @training.Dynamics raise {
  let format = json_text(checkpoint.field("format").plain_json())
  let state = checkpoint.field("model")
  let config = if format == "moonrobo.g1-root-integrated-dynamics.v1" {
    Json::empty_object()
  } else {
    checkpoint.field("config").plain_json()
  }
  let invariant = if format == "moonrobo.g1-root-integrated-dynamics.v1" {
    true
  } else {
    config_bool(config, "horizontal_translation_invariant", false)
  }
  guard format ==
    (if invariant {
      "moonrobo.residual-dynamics.v2"
    } else {
      "moonrobo.residual-dynamics.v1"
    }) ||
    format == "moonrobo.g1-root-integrated-dynamics.v1" else {
    fail("Torch dynamics format and input encoding disagree")
  }
  let stats = (name : String) => {
    (
      {
        mean: torch_vector(state.field(name + "_mean")),
        scale: torch_vector(state.field(name + "_scale")),
      } : @numeric.Normalization)
  }
  let width = if format == "moonrobo.g1-root-integrated-dynamics.v1" {
    json_integer(checkpoint.field("width").plain_json())
  } else {
    json_integer(json_field(config, "hidden_width"))
  }
  let root_dt = if format == "moonrobo.g1-root-integrated-dynamics.v1" {
    Some(json_number(checkpoint.field("dt_s").plain_json()))
  } else {
    None
  }
  let model = @training.Dynamics::new(
    stats("state"),
    stats("action"),
    stats("context"),
    width,
    @numeric.Rng::new(1U),
    translation_invariant=invariant,
    root_integration_dt=root_dt,
  )
  let parameters : Array[Double] = []
  for prefix in ["net.0", "net.2", "net.4"] {
    let layer = torch_dense(state, prefix, Linear)
    for row in layer.weight {
      parameters.append(row)
    }
    parameters.append(layer.bias)
  }
  guard model.network.parameters.length() == parameters.length() else {
    fail("Torch dynamics network shape mismatch")
  }
  for i, value in parameters {
    model.network.parameters[i] = value
  }
  model
}

///|
pub async fn load_reference_dynamics(
  path : String,
  expected_sha256? : String,
) -> (@training.Dynamics, Json) {
  let raw = @fs.read_file(path).binary()
  if expected_sha256 is Some(expected) {
    guard @artifacts.sha256(raw) == expected else {
      fail("world model checksum differs")
    }
  }
  if raw.length() >= 2 && raw[:2] == b"PK" {
    let data = @artifacts.decode_torch_checkpoint(raw)
    return (dynamics_from_torch(data), data.plain_json())
  }
  let data = @artifacts.load_checkpoint(
    path,
    "residual-dynamics",
    expected_sha256?,
  )
  (@training.dynamics_from_checkpoint(data), data.metadata)
}

///|
pub async fn load_initialization_feedback(path : String) -> Json {
  let raw = @fs.read_file(path).binary()
  if raw.length() < 2 || raw[:2] != b"PK" {
    return @json.parse(@utf8.decode(raw))
  }
  let data = @artifacts.decode_torch_checkpoint(raw)
  guard json_text(data.field("format").plain_json()) ==
    "moonrobo.g1-learned-balance-actor.v2" &&
    json_boolean(data.field("head_spec").field("pose_rate").plain_json()) else {
    fail("relative feedback requires fitted five-input pose/rate law")
  }
  let kinematics = data.field("kinematics").plain_json()
  let head = data.field("head")
  let weight = head.field("ankle.weight").tensor()
  let scale = head.field("ankle.scale").tensor()
  guard weight.shape == [4, 6] && scale.shape == [4, 5] else {
    fail("Torch feedback head shape differs")
  }
  let coefficients = Array::makei(4, i => {
    Array::makei(5, j => {
      (weight.values[i * 6 + j].to_float() / scale.values[i * 5 + j].to_float()).to_double()
    })
  })
  let names = json_array(json_field(kinematics, "joint_names")).map(name => {
    json_text(name)
  })
  let indices : Array[Int32] = []
  for side in ["left", "right"] {
    for axis in ["pitch", "roll"] {
      let name = side + "_ankle_" + axis + "_joint"
      let mut found = -1
      for i, joint in names {
        if joint == name {
          found = i
          break
        }
      }
      guard found >= 0 else { fail("feedback ankle joint absent") }
      indices.push(found)
    }
  }
  {
    "kinematics": kinematics,
    "feedback_coefficients": coefficients,
    "indices": indices,
  }
}
