///|
/// Data-only import of occupied chronological rows from the retained original
/// aligned checkpoint. No learner, optimizer, RNG or physical state is resumed.
pub(all) struct PassiveReplay {
  rows : Array[Array[@aligned.Transition]]
  identity : Json
  config : Json
} derive(Debug)

///|
fn integer(
  value : @artifacts.TorchValue,
  label : String,
  positive~ : Bool = false,
) -> Int32 raise {
  guard value is TorchInt(number) &&
    number >= (if positive { 1L } else { 0L }) &&
    number <= 2147483647L else {
    fail("invalid original replay integer: " + label)
  }
  number.to_int()
}

///|
fn text(value : @artifacts.TorchValue, expected : String) -> Unit raise {
  guard value is TorchString(actual) && actual == expected else {
    fail("unsupported original checkpoint schema: " + expected)
  }
}

///|
fn array_field(
  data : @artifacts.TorchValue,
  name : String,
  shape : Array[Int32],
  dtype : String,
) -> @artifacts.NumericArray raise {
  let array = data.field(name).tensor()
  guard array.shape == shape && array.dtype == dtype else {
    fail("original replay shape/dtype: " + name)
  }
  let mut count = 1L
  for dimension in shape {
    guard dimension >= 0 && count <= 2147483647L / dimension.to_int64().max(1L) else {
      fail("replay tensor count overflow")
    }
    count *= dimension.to_int64()
  }
  guard count == array.values.length().to_int64() &&
    array.values.all(value => !value.is_nan() && !value.is_inf()) else {
    fail("original replay nonfinite/length: " + name)
  }
  array
}

///|
fn row_vector(
  array : @artifacts.NumericArray,
  index : Int32,
  width : Int32,
) -> Array[Double] {
  array.values[index * width:(index + 1) * width].to_owned()
}

///|
fn scalar_integer(value : Double, label : String) -> Int32 raise {
  guard value >= 0 &&
    value <= 2147483647.0 &&
    value.to_int().to_double() == value else {
    fail("invalid replay index: " + label)
  }
  value.to_int()
}

///|
fn boolean(value : Double) -> Bool raise {
  guard value == 0 || value == 1 else { fail("nonboolean replay flag") }
  value == 1
}

///|
/// Preserve the original buffer.state_dict chronological layout exactly. The
/// complete eleven-field contract is mandatory, including distinct timeout and
/// physical termination; no inferred/fabricated transitions are permitted.
pub fn replay_from_torch(
  checkpoint : @artifacts.TorchValue,
) -> PassiveReplay raise {
  text(checkpoint.field("format"), "moonrobo.aligned-checkpoint.v1")
  let replay = checkpoint.field("replay")
  text(replay.field("format"), "moonrobo.aligned-replay.v1")
  let size = integer(replay.field("size"), "size", positive=true)
  let capacity = integer(replay.field("capacity"), "capacity", positive=true)
  let envs = integer(replay.field("num_envs"), "num_envs", positive=true)
  guard size <= capacity &&
    size.to_int64() * envs.to_int64() <= 2147483647L / 71L else {
    fail("invalid replay occupancy/count")
  }
  let data = replay.field("data")
  guard data is TorchDict(fields) && fields.length() == 11 else {
    fail("original replay requires exactly eleven named tensors")
  }
  let s = array_field(data, "s", [size, envs, 71], "<f4")
  let s1 = array_field(data, "s1", [size, envs, 71], "<f4")
  let a = array_field(data, "a", [size, envs, 29], "<f4")
  let a_prev = array_field(data, "a_prev", [size, envs, 29], "<f4")
  let xi = array_field(data, "xi", [size, envs, 33], "<f4")
  let reward = array_field(data, "r", [size, envs], "<f4")
  let frame = array_field(data, "f", [size, envs], "<i8")
  let step = array_field(data, "ep_step", [size, envs], "<i4")
  let done = array_field(data, "done", [size, envs], "|b1")
  let terminated = array_field(data, "terminated", [size, envs], "|b1")
  let truncated = array_field(data, "truncated", [size, envs], "|b1")
  let rows = Array::makei(size, age => {
    Array::makei(envs, env => {
      let i = age * envs + env
      let terminal = boolean(terminated.values[i])
      let timeout = boolean(truncated.values[i])
      guard boolean(done.values[i]) == (terminal || timeout) else {
        fail("original replay done differs from terminated | truncated")
      }
      @aligned.Transition::{
        s: row_vector(s, i, 71),
        s1: row_vector(s1, i, 71),
        a: row_vector(a, i, 29),
        a_prev: row_vector(a_prev, i, 29),
        xi: row_vector(xi, i, 33),
        r: reward.values[i],
        frame: scalar_integer(frame.values[i], "f"),
        ep_step: scalar_integer(step.values[i], "ep_step"),
        terminated: terminal,
        truncated: timeout,
      }
    })
  })
  let identity = checkpoint.field("identity").plain_json()
  let config = checkpoint.field("config").plain_json()
  guard identity is Object(_) && config is Object(_) else {
    fail("original checkpoint identity/config objects required")
  }
  { rows, identity, config, }
}

///|
/// Original export.py algorithm using the production MoonBit dataset decoder
/// and real compiled MuJoCo joint addresses. Model opening/forward kinematics
/// occur only when this function is explicitly invoked, never during import.
pub async fn export_torch_replay(
  checkpoint_path : String,
  expected_sha256 : String,
  motion_directory : String,
  library : String,
  scene : String,
  expected_identity? : Json,
  expected_config? : Json,
) -> Json {
  let checkpoint = @artifacts.load_torch_checkpoint(
    checkpoint_path,
    expected_sha256~,
  )
  let retained = replay_from_torch(checkpoint)
  if expected_identity is Some(identity) {
    guard retained.identity == identity else {
      fail("checkpoint identity differs from source training report")
    }
  }
  if expected_config is Some(config) {
    guard retained.config == config else {
      fail("checkpoint config differs from source training report")
    }
  }
  guard retained.identity is Object(identity) &&
    identity.get("scene_sha256") is Some(String(scene_sha)) &&
    scene_sha == @artifacts.sha256(@fs.read_file(scene).binary()) else {
    fail("original replay scene identity mismatch")
  }
  let runtime = @physics.Runtime::open(
    library,
    scene,
    require_position_servos=false,
  )
  let kin = @tracking.kinematics(runtime)
  let loaded = @aligned.load_motion_directory(
    motion_directory,
    kin,
    compute_body_features=false,
  )
  guard identity.get("motions") is Some(Array(motions)) &&
    motions.length() == loaded.motion.names.length() else {
    fail("original motion inventory mismatch")
  }
  let names : Map[String, String] = {}
  for entry in motions {
    guard entry is { "name": String(name), "sha256": String(digest), .. } &&
      !names.contains(name) else {
      fail("original motion identity schema/duplicate")
    }
    names[name] = digest
  }
  for i, name in loaded.motion.names {
    guard names.get(name) == Some(loaded.motion.source_sha256[i]) else {
      fail("original replay motion identity mismatch: " + name)
    }
  }
  for row in retained.rows {
    for transition in row {
      guard transition.frame < loaded.motion.states.length() else {
        fail("replay frame outside source corpus")
      }
    }
  }
  guard retained.config is Object(config) else { fail("config object") }
  let mode = match config.get("observation_mode") {
    None | Some(String("observable")) => @aligned.Observable
    Some(String("paper")) => @aligned.Paper
    Some(String("smc")) => @aligned.Smc
    _ => fail("original replay observation mode")
  }
  let goal_frames = match config.get("goal_frames") {
    None => 10
    Some(Number(value, ..)) => {
      guard value >= 1 && value <= 4096 && value.to_int().to_double() == value else {
        fail("original goal frame count")
      }
      value.to_int()
    }
    _ => fail("original goal frame count")
  }
  @aligned.decode_replay(
    retained.rows,
    loaded.motion,
    @tracking.joint_layout(runtime),
    scene,
    scene_sha,
    mode~,
    goal_frames~,
  )
}
