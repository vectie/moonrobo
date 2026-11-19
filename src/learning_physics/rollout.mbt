///|
pub(all) struct JointSines {
  amplitude : Array[Double]
  bias : Array[Double]
  frequency_hz : Array[Double]
  phase_rad : Array[Double]
} derive(Debug, ToJson, FromJson)

///|
pub(all) struct Case {
  id : String
  family : String
  split : String
  keyframe : String
  motion : String
  friction : Double
} derive(Debug, ToJson, FromJson)

///|
pub(all) struct Transition {
  time_s : Double
  state : Array[Double]
  observation : Array[Double]
  applied_action : Array[Double]
  next_state : Array[Double]
  goal : Array[Double]
  reward : Double
  terminated : Bool
  truncated : Bool
} derive(Debug, ToJson, FromJson)

///|
pub(all) struct ReplayFrame {
  time_s : Double
  qpos : Array[Double]
  target : Array[Double]
  root_height_m : Double
  upright_z : Double
  contacts : Int32
} derive(Debug, ToJson, FromJson)

///|
pub(all) struct Episode {
  id : String
  source_family : String
  split : String
  context : Array[Double]
  steps : Array[Transition]
  case_id : String
  reference_nominal_rad : Array[Double]
} derive(Debug, ToJson, FromJson)

///|
pub(all) struct Trial {
  episode_id : String
  case_id : String
  seed : Int32
  controller : String
  split : String
  steps : Int32
  failed : Bool
  joint_rmse_rad : Double
  min_root_height_m : Double
  simulated_seconds : Double
  end_reason : String
  replay : Array[ReplayFrame]
} derive(Debug, ToJson, FromJson)

///|
/// Caller supplies reproducible draws. NumPy PCG64 seed equivalence is not assumed.
pub fn pose_offset(
  names : Array[String],
  lower : Double,
  waist : Double,
  upper : Double,
  uniform : Array[Double],
) -> Array[Double] raise PhysicsError {
  if uniform.length() != names.length() ||
    [lower, waist, upper].any(v => v.is_nan() || v.is_inf() || v < 0) {
    raise Invalid("invalid pose amplitudes or draw width")
  }
  Array::makei(names.length(), i => {
    let name = names[i]
    let amplitude = if name.has_prefix("waist_") {
      waist
    } else if ["shoulder", "elbow", "wrist"].any(part => name.contains(part)) {
      upper
    } else {
      lower
    }
    amplitude * uniform[i]
  })
}

///|
pub fn Runtime::reference(
  self : Runtime,
  nominal : Array[Double],
  motion : String,
  t : Double,
  offset? : Array[Double],
  schedule? : JointSines,
) -> Array[Double] raise PhysicsError {
  let target = nominal.copy()
  let names = self.joint_names()
  match motion {
    "pose_offset" => {
      guard offset is Some(offset) && offset.length() == target.length() else {
        raise Invalid("pose offset reference needs one offset per actuator")
      }
      for i, v in offset {
        target[i] += v
      }
      return self.clip_control(target)
    }
    "random_joint_sines" => {
      guard schedule is Some(s) else {
        raise Invalid("joint-sine reference requires schedule")
      }
      if [
          s.amplitude.length(),
          s.bias.length(),
          s.frequency_hz.length(),
          s.phase_rad.length(),
        ].any(n => n != target.length()) {
        raise Invalid("joint-sine schedule width differs")
      }
      for i in 0..<target.length() {
        target[i] += s.bias[i] +
          s.amplitude[i] *
          @math.sin(2 * @math.PI * s.frequency_hz[i] * t + s.phase_rad[i])
      }
      return self.clip_control(target)
    }
    "arm_wave" =>
      for i, name in names {
        if name.contains("shoulder_pitch") {
          target[i] += 0.12 * @math.sin(2 * @math.PI * 0.5 * t)
        }
      }
    "waist_sway" =>
      for i, name in names {
        if name.contains("waist_yaw") {
          target[i] += 0.08 * @math.sin(2 * @math.PI * 0.5 * t)
        }
      }
    "stand" => ()
    _ => raise Invalid("unknown reference motion: " + motion)
  }
  target
}

///|
/// Actual MuJoCo stepping. Injected normal draws permit shared Python/MoonBit fixtures.
pub fn Runtime::rollout(
  self : Runtime,
  case : Case,
  seed : Int32,
  controller : String,
  seconds : Double,
  dt : Double,
  normal : () -> Double,
  fall_height~ : Double = 0.35,
  fall_upright~ : Double = 0.5,
  action_noise_std~ : Double = 0.0,
  policy? : (Array[Double], Array[Double]) -> Array[Double],
  offset? : Array[Double],
  schedule? : JointSines,
  trace? : (Int32, Array[Double], Array[Double]) -> Unit,
) -> (Episode, Trial) raise PhysicsError {
  if action_noise_std.is_nan() ||
    action_noise_std.is_inf() ||
    action_noise_std < 0 {
    raise Invalid("action noise must be finite and nonnegative")
  }
  if controller != "unpowered" &&
    controller != "position" &&
    controller != "policy" {
    raise Invalid("unknown controller")
  }
  if controller == "policy" && policy is None {
    raise Invalid("policy controller needs inference callback")
  }
  let substeps = self.control_substeps(dt)
  let count = @math.round(seconds / dt).to_int()
  if count < 1 ||
    (count.to_double() * dt - seconds).abs() > seconds.abs() * 1.0e-9 {
    raise Invalid("duration must be a positive multiple of control_dt")
  }
  self.reset(case.keyframe, case.friction, unpowered=controller == "unpowered")
  let (nq, _, _, nu) = self.dimensions()
  for i in 0..<nu {
    set_native(self, 1, i, normal() * 0.01)
  }
  // Forward after velocity perturbations without advancing simulation time.
  step_native(self, 0)
  let initial = self.state()
  let indices = self.q_indices()
  let nominal = indices.map(i => initial[i])
  let mut previous = self.clip_control(nominal)
  let steps : Array[Transition] = []
  let replay : Array[ReplayFrame] = []
  let mut squared_error = 0.0
  let mut min_height = 1.0 / 0.0
  for i in 0..<count {
    let goal = self.reference(
      nominal,
      case.motion,
      i.to_double() * dt,
      offset?,
      schedule?,
    )
    let before = self.state()
    let observation = self.observation(previous)
    let action = if controller == "unpowered" {
      Array::make(nu, 0.0)
    } else {
      let requested = if controller == "position" {
        goal
      } else {
        policy.unwrap()(observation, goal)
      }
      let noisy = requested.map(v => v + normal() * action_noise_std)
      self.clip_control(noisy)
    }
    if trace is Some(callback) {
      callback(i, action.copy(), goal.copy())
    }
    let after = self.step(action, substeps)
    let height = self.root_height()
    let upright = self.upright()
    let fallen = height < fall_height || upright < fall_upright
    let mut error = 0.0
    for j, q in indices {
      let d = after[q] - goal[j]
      error += d * d
    }
    error /= nu.to_double()
    squared_error += error
    min_height = if height < min_height { height } else { min_height }
    steps.push({
      time_s: i.to_double() * dt,
      state: before,
      observation,
      applied_action: action,
      next_state: after,
      goal,
      reward: @math.exp(-error / 0.09),
      terminated: fallen,
      truncated: !fallen && i == count - 1,
    })
    replay.push({
      time_s: (i + 1).to_double() * dt,
      qpos: Array::makei(nq, j => after[j]),
      target: goal,
      root_height_m: height,
      upright_z: upright,
      contacts: self.contacts(),
    })
    previous = action.copy()
    if fallen {
      break
    }
  }
  let id = "\{case.id}-\{controller}-seed-\{seed}"
  let failed = steps[steps.length() - 1].terminated
  (
    {
      id,
      source_family: case.family,
      split: case.split,
      context: [
        case.friction,
        if controller == "unpowered" {
          0.0
        } else {
          1.0
        },
      ],
      steps,
      case_id: case.id,
      reference_nominal_rad: nominal,
    },
    {
      episode_id: id,
      case_id: case.id,
      seed,
      controller,
      split: case.split,
      steps: steps.length(),
      failed,
      joint_rmse_rad: (squared_error / steps.length().to_double()).sqrt(),
      min_root_height_m: min_height,
      simulated_seconds: steps.length().to_double() * dt,
      end_reason: if failed {
        "fall"
      } else {
        "time_limit"
      },
      replay,
    },
  )
}

///|
fn axes(prefix : String, count : Int32, unit : String) -> Array[Json] {
  Array::makei(count, i => { "name": "\{prefix}.\{i}", "unit": unit })
}

///|
/// Motion dataset layout remains compatible with the existing MoonBit window tools.
pub fn Runtime::dataset(
  self : Runtime,
  episodes : Array[Episode],
  source_revision : String,
  dt~ : Double,
  episode_json? : Array[Json],
) -> Json {
  let (nq, nv, na, _) = self.dimensions()
  let names = self.joint_names()
  let q = axes("qpos", nq, "rad")
  for i in 0..<3 {
    q[i] = { "name": "qpos.\{i}", "unit": "m" }
  }
  for i in 3..<7 {
    q[i] = { "name": "qpos.\{i}", "unit": "1" }
  }
  let v = axes("qvel", nv, "rad/s")
  for i in 0..<3 {
    v[i] = { "name": "qvel.\{i}", "unit": "m/s" }
  }
  q.append(v)
  q.append(axes("activation", na, "1"))
  let observations : Array[Json] = names.map(n => {
    "name": n + ".position",
    "unit": "rad",
  })
  observations.append(
    names.map(n => { "name": n + ".velocity", "unit": "rad/s" }),
  )
  observations.append(axes("projected_gravity", 3, "1"))
  observations.append(axes("root_angular_velocity", 3, "rad/s"))
  observations.append(
    names.map(n => { "name": n + ".previous_setpoint", "unit": "rad" }),
  )
  let actions : Array[Json] = names.map(n => {
    "name": n + ".setpoint",
    "unit": "rad",
  })
  let goals : Array[Json] = names.map(n => {
    "name": n + ".target",
    "unit": "rad",
  })
  let eps = episode_json.unwrap_or(episodes.map(e => e.to_json()))
  {
    "format": "moonrobo.motion-dataset.v1",
    "dataset_id": "g1-cpu-physics",
    "model_ref": "mujoco-menagerie:\{source_revision}:unitree_g1/scene_mjx.xml",
    "provenance": "MuJoCo CPU transitions; original procedural references, not mocap or hardware",
    "frame_convention": "MuJoCo qpos/qvel; world Z up; free-root quaternion wxyz; gravity in root frame",
    "dt_s": dt,
    "state_axes": q,
    "observation_axes": observations,
    "action_axes": actions,
    "goal_axes": goals,
    "context_axes": [
      { "name": "sliding_friction", "unit": "1" },
      { "name": "actuation_enabled", "unit": "1" },
    ],
    "episodes": eps,
  }
}
