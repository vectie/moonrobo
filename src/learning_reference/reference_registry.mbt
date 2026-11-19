///|
pub fn json_number(value : Json) -> Double raise {
  match value {
    Number(x, ..) => x
    _ => fail("expected JSON number")
  }
}

///|
pub fn json_integer(value : Json) -> Int32 raise {
  let x = json_number(value)
  guard x >= 0.0 && x <= 2147483647.0 && x.to_int().to_double() == x else {
    fail("expected nonnegative integer")
  }
  x.to_int()
}

///|
pub fn json_boolean(value : Json) -> Bool raise {
  match value {
    True => true
    False => false
    _ => fail("expected JSON boolean")
  }
}

///|
pub fn json_fields(value : Json) -> Map[String, Json] raise {
  match value {
    Object(fields) => fields.copy()
    _ => fail("expected JSON object")
  }
}

///|
pub fn path_child(folder : String, file : String) -> String {
  if file.has_prefix("/") {
    file
  } else {
    folder + "/" + file
  }
}

///|
pub fn path_name(path : String) -> String {
  path.split("/").collect().last().unwrap().to_owned()
}

///|
pub fn trial_summary(trials : Array[Json]) -> Json raise {
  guard !trials.is_empty() else { fail("empty registry trials") }
  let mut falls = 0
  let mut survival = 0.0
  let mut joint = 0.0
  for trial in trials {
    if json_boolean(json_field(trial, "failed")) {
      falls += 1
    }
    survival += json_number(json_field(trial, "simulated_seconds"))
    joint += json_number(json_field(trial, "joint_rmse_rad"))
  }
  {
    "trials": trials.length(),
    "falls": falls,
    "mean_survival_s": survival / trials.length().to_double(),
    "mean_joint_rmse_rad": joint / trials.length().to_double(),
  }
}

///|
pub async fn source_digest(path : String) -> String {
  @artifacts.sha256(@fs.read_file(path).binary())
}

///|
pub async fn load_record_arrays(
  folder : String,
  record : Json,
) -> Map[String, @artifacts.NumericArray] {
  let path = path_child(folder, json_text(json_field(record, "file")))
  let raw = @fs.read_file(path).binary()
  guard @artifacts.sha256(raw) == json_text(json_field(record, "sha256")) else {
    fail("recorded reference physics changed")
  }
  @artifacts.decode_npz(raw)
}

///|
pub fn numeric_matrix(
  arrays : Map[String, @artifacts.NumericArray],
  name : String,
) -> Array[Array[Double]] raise {
  ({ metadata: Json::null(), layout: Json::null(), arrays, } : ReferenceArchive).matrix(
    name,
  )
}

///|
/// Pose/contact reconstruction uses MuJoCo forward on archived state, matching
/// the original exporter rather than replacing contacts with kinematic guesses.
pub fn trace_trial(
  runtime : @physics.Runtime,
  reference : ReferenceArchive,
  record : Json,
  trial : Json,
  arrays : Map[String, @artifacts.NumericArray],
  include_reference : Bool,
  dt : Double,
) -> Json raise {
  let context = json_array(json_field(record, "context"))
  runtime.set_friction(json_number(context[0]))
  let origin = json_integer(json_field(record, "origin_step"))
  let state = numeric_matrix(arrays, "next_state")
  let action = numeric_matrix(arrays, "applied_action")
  let target = reference.matrix("state")
  let positions = reference.arrays["body_position"]
  let rotations = reference.arrays["body_rotation"]
  let root = runtime.root_body_index() - 1
  let q_indices = runtime.q_indices()
  let bodies = positions.shape[1]
  let replay : Array[Json] = []
  for i, s in state {
    runtime.set_recorded_state(s, action[i])
    let actual_positions = runtime.body_positions(include_world=false)
    let actual_rotations = runtime.body_rotations(include_world=false)
    let phase = origin + i + 1
    let desired = Array::makei(bodies, b => {
      positions.values[(phase * bodies + b) * 3:(phase * bodies + b + 1) * 3].to_owned()
    })
    let desired_rotation = rotations.values[(phase * bodies + root) * 9:(
      phase * bodies + root + 1
    ) *
    9].to_owned()
    let root_difference = actual_positions[root].mapi((j, x) => {
      x - desired[root][j]
    })
    let body_squared = actual_positions.foldi(init=0.0, (b, total, p) => {
        total +
        p.foldi(init=0.0, (j, sum, x) => {
          sum + (x - desired[b][j]) * (x - desired[b][j])
        })
      }) /
      bodies.to_double()
    let trace = dot(desired_rotation, actual_rotations[root])
    let orientation = @math.acos(clamp((trace - 1.0) / 2.0, -1.0, 1.0))
    let joint = q_indices.fold(init=0.0, (sum, j) => {
        sum + (s[j] - target[phase][j]) * (s[j] - target[phase][j])
      }) /
      q_indices.length().to_double()
    replay.push({
      "time_s": (i + 1).to_double() * dt,
      "root_height_m": runtime.root_height(),
      "upright_z": runtime.upright(),
      "contacts": runtime.contacts(),
      "root_position_error_m": dot(root_difference, root_difference).sqrt(),
      "body_position_error_m": body_squared.sqrt(),
      "root_orientation_error_rad": orientation,
      "joint_rmse_rad": joint.sqrt(),
    })
  }
  let result = json_fields(trial)
  result["seed"] = json_field(reference.metadata, "source_reset_seed")
  result["reference_start_time_s"] = (origin.to_double() * dt).to_json()
  result["end_reason"] = (if json_boolean(json_field(trial, "failed")) {
    "fall"
  } else {
    "time_limit"
  }).to_json()
  result["replay"] = replay.to_json()
  if include_reference {
    let frames : Array[Json] = []
    for i in (origin + 1)..<target.length() {
      frames.push({
        "time_s": (i - origin).to_double() * dt,
        "root_height_m": positions.values[(i * bodies + root) * 3 + 2],
        "upright_z": rotations.values[(i * bodies + root) * 9 + 8],
      })
    }
    result["reference_replay"] = frames.to_json()
  }
  result.to_json()
}

///|
pub fn dataset(
  runtime : @physics.Runtime,
  episode : Json,
  manifest : Json,
  dt : Double,
  provenance : String,
) -> Json raise {
  let (nq, nv, na, _) = runtime.dimensions()
  let names = runtime.joint_names()
  let axes = (prefix : String, count : Int32, unit : String) => {
    Array::makei(count, i => ({ "name": "\{prefix}.\{i}", "unit": unit } : Json))
  }
  let q_axes = axes("qpos", nq, "rad")
  for i in 0..<3 {
    q_axes[i] = { "name": "qpos.\{i}", "unit": "m" }
  }
  for i in 3..<7 {
    q_axes[i] = { "name": "qpos.\{i}", "unit": "1" }
  }
  let v_axes = axes("qvel", nv, "rad/s")
  for i in 0..<3 {
    v_axes[i] = { "name": "qvel.\{i}", "unit": "m/s" }
  }
  let state_axes = q_axes.copy()
  state_axes.append(v_axes)
  state_axes.append(axes("activation", na, "1"))
  let joint_axes = (suffix : String, unit : String) => {
    names.map(name => ({ "name": name + suffix, "unit": unit } : Json))
  }
  let observation_axes = joint_axes(".position", "rad")
  observation_axes.append(joint_axes(".velocity", "rad/s"))
  observation_axes.append(axes("projected_gravity", 3, "1"))
  observation_axes.append(axes("root_angular_velocity", 3, "rad/s"))
  observation_axes.append(joint_axes(".previous_setpoint", "rad"))
  {
    "format": "moonrobo.motion-dataset.v1",
    "dataset_id": "g1-cpu-physics",
    "model_ref": json_field(manifest, "model_ref"),
    "provenance": provenance,
    "frame_convention": "MuJoCo qpos/qvel; world Z up; free-root quaternion wxyz; gravity in root frame",
    "dt_s": dt,
    "state_axes": state_axes,
    "observation_axes": observation_axes,
    "action_axes": joint_axes(".setpoint", "rad"),
    "goal_axes": json_field(json_field(manifest, "layout"), "goal_axes"),
    "context_axes": [
      { "name": "sliding_friction", "unit": "1" },
      { "name": "actuation_enabled", "unit": "1" },
    ],
    "episodes": [episode],
  }
}

///|
pub fn representative_episode(
  reference : ReferenceArchive,
  record : Json,
  arrays : Map[String, @artifacts.NumericArray],
  dt : Double,
  train : Bool,
) -> Json raise {
  let state = numeric_matrix(arrays, "state")
  let next = numeric_matrix(arrays, "next_state")
  let observation = numeric_matrix(arrays, "observation")
  let action = numeric_matrix(arrays, "applied_action")
  let goals = reference.goals()
  let origin = json_integer(json_field(record, "origin_step"))
  let count = json_integer(json_field(record, "steps"))
  let steps = Array::makei(count, i => {
    (
      {
        "time_s": i.to_double() * dt,
        "state": state[i],
        "observation": observation[i],
        "applied_action": action[i],
        "next_state": next[i],
        "goal": goals[origin + i + 1],
        "reward": arrays["reward"].values[i],
        "terminated": arrays["terminated"].values[i] != 0.0,
        "truncated": arrays["truncated"].values[i] != 0.0,
      } : Json)
  })
  {
    "id": json_field(record, "episode_id"),
    "source_family": json_field(record, "source_family"),
    "split": if train {
      "train".to_json()
    } else {
      json_field(record, "split")
    },
    "context": json_field(record, "context"),
    "steps": steps,
  }
}
