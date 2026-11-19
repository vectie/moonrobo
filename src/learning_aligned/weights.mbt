///|
/// Weight import deliberately excludes optimizer, RNG, replay and physical state.
pub fn Learner::restore_weights(
  self : Learner,
  saved : LearnerSnapshot,
) -> Unit raise {
  let a = self.config
  let b = saved.config
  guard a.hist == b.hist &&
    a.goal_frames == b.goal_frames &&
    a.wm_hidden == b.wm_hidden &&
    a.policy_hidden == b.policy_hidden &&
    a.critic_hidden == b.critic_hidden &&
    saved.parameters.length() == 4 &&
    saved.norms.length() == 5 else {
    fail("aligned weight architecture differs")
  }
  let models = [
    self.wm.net,
    self.policy.encoder,
    self.policy.decoder,
    self.critic.net,
  ]
  for i, net in models {
    guard net.parameters.length() == saved.parameters[i].length() &&
      saved.parameters[i].all(finite) else {
      fail("aligned weight shape or finite-value mismatch")
    }
  }
  // Validate all normalizers before mutating the learner.
  let norms = [
    self.wm.input_norm,
    self.wm.output_norm,
    self.policy.obs_norm,
    self.policy.goal_norm,
    self.critic.norm,
  ]
  for i, norm in norms {
    let row = saved.norms[i]
    guard row.mean.length() == norm.mean.length() &&
      row.variance.length() == norm.mean.length() &&
      row.mean.all(finite) &&
      row.variance.all(v => finite(v) && v >= 0.0) &&
      finite(row.count) &&
      row.count >= 0.0 else {
      fail("aligned weight normalizer mismatch")
    }
  }
  for i, net in models {
    for j, v in saved.parameters[i] {
      net.parameters[j] = v
    }
  }
  for i, norm in norms {
    norm.load(saved.norms[i])
  }
}

///|
fn weight_field(value : Json, key : String) -> Json raise {
  guard value is Object(fields) && fields.get(key) is Some(result) else {
    fail("aligned weight identity missing " + key)
  }
  result
}

///|
fn weight_mode(value : Json) -> String raise {
  guard value is Object(fields) else {
    fail("aligned weight config must be object")
  }
  match fields.get("observation_mode") {
    Some(value) => @json.from_json(value)
    None => "paper"
  }
}

///|
fn mode_name(mode : ObservationMode) -> String {
  match mode {
    Paper => "paper"
    Smc => "smc"
    Observable => "observable"
  }
}

///|
fn torch_numeric(
  value : @artifacts.TorchValue,
  key : String,
  shape : Array[Int32],
) -> Array[Double] raise {
  let array = value.field(key).tensor()
  guard array.shape == shape && array.values.all(finite) else {
    fail("Torch aligned tensor shape or finite values differ: " + key)
  }
  array.values
}

///|
fn torch_network(
  net : Network,
  state : @artifacts.TorchValue,
  prefix : String,
  consumed : Array[String],
) -> Array[Double] raise {
  let parameters = []
  for i in 0..<(net.dimensions.length() - 1) {
    let index = i * (if net.layer_norm { 3 } else { 2 })
    let name = prefix + index.to_string()
    let weight = name + ".weight"
    let bias = name + ".bias"
    let nin = net.dimensions[i]
    let nout = net.dimensions[i + 1]
    parameters.append(torch_numeric(state, weight, [nout, nin]))
    consumed.push(weight)
    parameters.append(torch_numeric(state, bias, [nout]))
    consumed.push(bias)
    if net.layer_norm && i < net.dimensions.length() - 2 {
      let name = prefix + (index + 1).to_string()
      for suffix in [".weight", ".bias"] {
        let key = name + suffix
        parameters.append(torch_numeric(state, key, [nout]))
        consumed.push(key)
      }
    }
  }
  guard parameters.length() == net.parameters.length() else {
    fail("Torch aligned network packing mismatch")
  }
  parameters
}

///|
fn torch_norm(
  state : @artifacts.TorchValue,
  prefix : String,
  dim : Int32,
  consumed : Array[String],
) -> NormSnapshot raise {
  let mean = torch_numeric(state, prefix + ".mean", [dim])
  let variance = torch_numeric(state, prefix + ".var", [dim])
  let count = torch_numeric(state, prefix + ".count", [])[0]
  for suffix in [".mean", ".var", ".count"] {
    consumed.push(prefix + suffix)
  }
  guard variance.all(v => v >= 0.0) && count >= 0.0 else {
    fail("Torch aligned running statistics invalid")
  }
  { mean, variance, count, }
}

///|
fn torch_exact_keys(
  state : @artifacts.TorchValue,
  consumed : Array[String],
) -> Unit raise {
  guard state is TorchDict(fields) && fields.length() == consumed.length() else {
    fail("Torch aligned state_dict keys differ")
  }
  for key, _ in fields {
    guard consumed.contains(key) else {
      fail("unexpected Torch aligned state tensor: " + key)
    }
  }
}

///|
/// Decode the original learner.state_dict() or full aligned checkpoint payload.
/// Full payload physics data is parsed by the restricted numeric-only reader;
/// no optimizer/replay/physics/RNG state is imported into this learner.
pub fn Learner::import_torch_weights(
  self : Learner,
  root : @artifacts.TorchValue,
) -> Unit raise {
  let state = match root {
    TorchDict(fields) => fields.get("learner").unwrap_or(root)
    _ => fail("Torch aligned weights must be a dict")
  }
  let wm = state.field("wm")
  let pi = state.field("pi")
  let critic = state.field("critic")
  let wm_keys = []
  let pi_keys = []
  let critic_keys = []
  let parameters = [
    torch_network(self.wm.net, wm, "net.", wm_keys),
    torch_network(self.policy.encoder, pi, "enc.", pi_keys),
    torch_network(self.policy.decoder, pi, "dec.", pi_keys),
    torch_network(self.critic.net, critic, "net.", critic_keys),
  ]
  let norms = [
    torch_norm(wm, "in_norm", 133, wm_keys),
    torch_norm(wm, "out_norm", 70, wm_keys),
    torch_norm(pi, "obs_norm", self.mode.dim(), pi_keys),
    torch_norm(pi, "goal_norm", 73 * self.config.goal_frames, pi_keys),
    torch_norm(critic, "norm", 184 + 73 * self.config.goal_frames, critic_keys),
  ]
  torch_exact_keys(wm, wm_keys)
  torch_exact_keys(pi, pi_keys)
  torch_exact_keys(critic, critic_keys)
  let base = self.snapshot()
  self.restore_weights({ ..base, parameters, norms, })
}

///|
/// Native snapshots require matching scene and observation semantics, but may
/// use a different motion catalog/split. Optional trusted SHA binds the source.
/// Torch full checkpoints also require matching scene; bare learner state dicts
/// require explicit caller-supplied SHA and declared observation mode.
pub async fn Learner::load_weights(
  self : Learner,
  path : String,
  scene_sha256 : String,
  expected_sha256? : String,
) -> Json {
  let bytes = @fs.read_file(path).binary()
  let digest = @artifacts.sha256(bytes)
  if expected_sha256 is Some(expected) {
    guard digest == expected else {
      fail("aligned weight source SHA256 mismatch")
    }
  }
  let mut source_identity : Json = Json::null()
  let source_format = if path.has_suffix(".pt") || path.has_suffix(".pth") {
    let root = @artifacts.decode_torch_checkpoint(bytes)
    guard root is TorchDict(fields) else {
      fail("aligned Torch weight root must be dictionary")
    }
    if fields.get("identity") is Some(identity) {
      guard root.field("format")
        is TorchString("moonrobo.aligned-checkpoint.v1") else {
        fail("unsupported full aligned Torch checkpoint format")
      }
      source_identity = identity.plain_json()
      guard weight_field(source_identity, "scene_sha256") ==
        scene_sha256.to_json() else {
        fail("aligned Torch weight scene differs")
      }
      let config = root.field("config").plain_json()
      guard weight_mode(config) == mode_name(self.mode) else {
        fail("aligned Torch observation semantics differ")
      }
    } else {
      guard expected_sha256 is Some(_) else {
        fail("bare aligned learner state_dict requires --weights-sha256")
      }
      let config = root.field("config").plain_json()
      guard weight_mode(config) == mode_name(self.mode) else {
        fail("aligned Torch observation semantics differ")
      }
    }
    self.import_torch_weights(root)
    "torch-data-only-weights"
  } else {
    let checkpoint = @artifacts.load_checkpoint(
      path,
      "aligned-supermimic",
      expected_sha256=digest,
    )
    let saved : TrainingCheckpoint = @json.from_json(checkpoint.metadata)
    source_identity = saved.identity
    guard weight_field(source_identity, "scene_sha256") ==
      scene_sha256.to_json() &&
      weight_mode(weight_field(source_identity, "config")) ==
      mode_name(self.mode) else {
      fail("aligned native weight scene or observation semantics differ")
    }
    self.restore_weights(saved.learner)
    "moonbit-weights"
  }
  {
    "mode": "weights-only-not-resume",
    "source_format": source_format.to_json(),
    "source_path": path.to_json(),
    "source_sha256": digest.to_json(),
    "source_identity": source_identity,
    "optimizer_restored": false,
    "rng_restored": false,
    "replay_restored": false,
    "physical_state_restored": false,
  }
}
