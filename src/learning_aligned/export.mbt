///|
pub(all) struct JointLayout {
  nq : Int32
  nv : Int32
  na : Int32
  qpos_addresses : Array[Int32]
  qvel_addresses : Array[Int32]
} derive(Debug, ToJson, FromJson)

///|
pub fn mujoco_state(
  state : Array[Double],
  layout : JointLayout,
) -> Array[Double] raise {
  guard state.length() == 71 &&
    layout.na == 0 &&
    layout.nq >= 7 &&
    layout.nv >= 6 &&
    layout.qpos_addresses.length() == 29 &&
    layout.qvel_addresses.length() == 29 else {
    fail("invalid aligned71 layout or unsupported actuator activation state")
  }
  let qpos = Array::make(layout.nq, 0.0)
  let qvel = Array::make(layout.nv, 0.0)
  for i in 0..<7 {
    qpos[i] = state[i]
  }
  for i in 0..<3 {
    qvel[i] = state[i + 7]
  }
  let angular = mat_vec(
    transpose(quat_to_mat(state[3:7].to_owned())),
    state[10:13].to_owned(),
  )
  for i in 0..<3 {
    qvel[i + 3] = angular[i]
  }
  for i in 0..<29 {
    let qa = layout.qpos_addresses[i]
    let va = layout.qvel_addresses[i]
    guard qa >= 7 && qa < layout.nq && va >= 6 && va < layout.nv else {
      fail("compiled MuJoCo joint address outside layout")
    }
    qpos[qa] = state[i + 13]
    qvel[va] = state[i + 42]
  }
  qpos.append(qvel)
  qpos
}

///|
priv struct ExportStep {
  time_s : Double
  state : Array[Double]
  next_state : Array[Double]
  observation : Array[Double]
  applied_action : Array[Double]
  goal : Array[Double]
  reward : Double
  terminated : Bool
  truncated : Bool
} derive(ToJson)

///|
priv struct ExportEpisode {
  id : String
  source_family : String
  split : String
  context : Array[Double]
  steps : Array[ExportStep]
} derive(ToJson)

///|
fn axes(prefix : String, n : Int32, unit : String) -> Array[Json] {
  Array::makei(n, i => {
    "name": "\{prefix}.\{i}".to_json(),
    "unit": unit.to_json(),
  })
}

///|
pub fn decode_replay(
  replay : Array[Array[Transition]],
  motion : MotionLibrary,
  layout : JointLayout,
  scene : String,
  scene_sha256 : String,
  mode~ : ObservationMode = Observable,
  goal_frames~ : Int32 = 10,
) -> Json raise {
  guard !replay.is_empty() && !replay[0].is_empty() else {
    fail("checkpoint replay is empty")
  }
  let num_envs = replay[0].length()
  for row in replay {
    guard row.length() == num_envs else {
      fail("inconsistent replay environment dimensions")
    }
  }
  let episodes : Array[ExportEpisode] = []
  for env in 0..<num_envs {
    let mut current : ExportEpisode? = None
    for age, row in replay {
      let tr = row[env]
      let boundary = age == 0 || !contiguous(replay[(age - 1).max(0)][env], tr)
      if boundary {
        if current is Some(ep) {
          episodes.push(ep)
        }
        current = Some({
          id: "aligned-env-\{env}-replay-\{age}",
          source_family: motion.names[motion.clip_id[tr.frame]],
          split: "train",
          context: tr.xi.copy(),
          steps: [],
        })
      }
      guard current is Some(ep) else { fail("missing replay episode") }
      guard ep.context == tr.xi else {
        fail("sim context changed inside replay episode")
      }
      ep.steps.push({
        time_s: tr.ep_step.to_double() * control_dt,
        state: mujoco_state(tr.s, layout),
        next_state: mujoco_state(tr.s1, layout),
        observation: observation(
          unflatten_state(tr.s),
          tr.a_prev,
          tr.xi,
          default_joint_positions(),
          motion.states[tr.frame],
          mode,
        ),
        applied_action: action_to_setpoint(
          tr.a,
          calibration=tr.xi[1:30].to_owned(),
        ),
        goal: motion.goal(tr.frame, goal_frames),
        reward: tr.r,
        terminated: tr.terminated,
        truncated: tr.truncated,
      })
    }
    if current is Some(ep) {
      episodes.push(ep)
    }
  }
  let qaxes = axes("qpos", layout.nq, "rad")
  let vaxes = axes("qvel", layout.nv, "rad/s")
  for i in 0..<3 {
    qaxes[i] = { "name": "qpos.\{i}".to_json(), "unit": "m" }
    vaxes[i] = { "name": "qvel.\{i}".to_json(), "unit": "m/s" }
  }
  for i in 3..<7 {
    qaxes[i] = { "name": "qpos.\{i}".to_json(), "unit": "1" }
  }
  qaxes.append(vaxes)
  let names = joint_names()
  let obsaxes : Array[Json] = names.map(name => {
    "name": (name + ".relative_position").to_json(),
    "unit": "rad",
  })
  obsaxes.append(
    names.map(name => {
      "name": (name + ".velocity").to_json(),
      "unit": "rad/s",
    }),
  )
  obsaxes.append(axes("angular_velocity_local", 3, "rad/s"))
  obsaxes.append(axes("projected_gravity", 3, "1"))
  obsaxes.append(
    names.map(name => {
      "name": (name + ".previous_normalized_action").to_json(),
      "unit": "1",
    }),
  )
  if mode != Paper {
    obsaxes.append(axes("reference_relative_orientation_6d", 6, "1"))
  }
  if mode == Observable {
    obsaxes.append(axes("reference_relative_position_local", 3, "m"))
  }
  let context_axes : Array[Json] = [{ "name": "friction", "unit": "1" }]
  context_axes.append(
    names.map(name => {
      "name": (name + ".calibration").to_json(),
      "unit": "rad",
    }),
  )
  context_axes.append(axes("torso_com_offset", 3, "m"))
  {
    "format": "moonrobo.motion-dataset.v1",
    "dataset_id": "g1-aligned-replay",
    "model_ref": ("mujoco:" + scene + ":sha256:" + scene_sha256).to_json(),
    "provenance": "Retained training replay only; clean observations and preview goals reconstructed from saved physical states. No held-out split; no evaluation transitions included.",
    "frame_convention": "Explicit aligned71 to compiled MuJoCo qpos/qvel; root quaternion wxyz, linear velocity world, angular velocity body-local; actions default+calibration+joint-scale*normalized_action; preview qd*0.1.",
    "dt_s": control_dt.to_json(),
    "state_axes": qaxes.to_json(),
    "observation_axes": obsaxes.to_json(),
    "action_axes": names
    .map(name => { "name": (name + ".setpoint").to_json(), "unit": "rad" })
    .to_json(),
    "goal_axes": axes("reference_preview", 73 * goal_frames, "mixed-scaled").to_json(),
    "context_axes": context_axes.to_json(),
    "episodes": episodes.to_json(),
  }
}
