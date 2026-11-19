///|
fn horizontal_speed(
  rows : Array[Array[Double]],
  start : Int32,
  frames : Int32,
  fps : Double,
) -> Double {
  let mut length = 0.0
  for f in (start + 1)..<(start + frames) {
    let dx = rows[f][0] - rows[f - 1][0]
    let dy = rows[f][1] - rows[f - 1][1]
    length += (dx * dx + dy * dy).sqrt()
  }
  length * fps / (frames - 1).to_double()
}

///|
/// Take the first qualifying, whole eight-second window in each recording
/// quarter. Candidate selection only sees the source motion, before IK.
fn moving_starts(
  rows : Array[Array[Double]],
  minimum_speed : Double,
) -> Array[Int32] {
  let starts = []
  for part in 0..<4 {
    let end = rows.length() * (part + 1) / 4
    for start = rows.length() * part / 4; start + 241 <= end; start = start + 30 {
      if horizontal_speed(rows, start, 241, 30.0) >= minimum_speed {
        starts.push(start)
        break
      }
    }
  }
  starts
}

///|
/// Symmetric 9-tap binomial kernel at 50 Hz. Keep each quaternion in the
/// centre frame's hemisphere and renormalize before checking FK and contacts.
fn smooth_locomotion(rows : Array[Array[Double]]) -> Array[Array[Double]] {
  let kernel = [1.0, 8.0, 28.0, 56.0, 70.0, 56.0, 28.0, 8.0, 1.0]
  Array::makei(rows.length(), f => {
    let row = Array::make(rows[f].length(), 0.0)
    for k, w in kernel {
      let sample = rows[(f + k - 4).max(0).min(rows.length() - 1)]
      let mut dot = 0.0
      for j in 3..<7 {
        dot += sample[j] * rows[f][j]
      }
      for j, x in sample {
        let sign = if j >= 3 && j < 7 && dot < 0.0 { -1.0 } else { 1.0 }
        row[j] += sign * w * x / 256.0
      }
    }
    let mut norm = 0.0
    for j in 3..<7 {
      norm += row[j] * row[j]
    }
    for j in 3..<7 {
      row[j] = row[j] / norm.sqrt()
    }
    row
  })
}

///|
fn acceleration_p95(
  motion : @aligned.MotionLibrary,
  axes : Int32,
) -> Array[Double] {
  let values : Array[Array[Double]] = [[], [], []]
  for f in 2..<(motion.states.length() - 2) {
    let a = motion.states[f - 1]
    let b = motion.states[f + 1]
    values[0].push(distance(a.v, b.v) / 0.04)
    values[1].push(distance(a.w, b.w) / 0.04)
    let mut max_joint = 0.0
    for j in 0..<axes {
      max_joint = max_joint.max((b.qd[j] - a.qd[j]).abs() / 0.04)
    }
    values[2].push(max_joint)
  }
  values.map(xs => {
    xs.sort()
    xs[(xs.length() - 1) * 95 / 100]
  })
}

///|
/// Evaluate the local tracking demands of the final reference using the same
/// bounded E1 servos and native timestep as the trainer. Each 100 ms window
/// starts at its reference pose and velocity, including the floating base.
fn locomotion_screen(
  rows : Array[Array[Double]],
  source : @aligned.MotionLibrary,
  rt : @sim.Runtime,
  kin : @aligned.Kinematics,
  robot : Profile,
) -> Json raise {
  let target = @aligned.MotionLibrary::new(
    [{ name: "locomotion", sha256: "internal", rows, }],
    kin,
    source_fps=50.0,
    compute_body_features=false,
  )
  let src = acceleration_p95(source, 29)
  let dst = acceleration_p95(target, robot.joints.length())
  let limits = [
    (src[0] * 2.0).max(3.0),
    (src[1] * 2.0).max(15.0),
    (src[2] * 2.0).max(50.0),
  ]
  let mut smooth = true
  for k in 0..<3 {
    smooth = smooth && dst[k] <= limits[k]
  }
  let layout = @tracking.joint_layout(rt, names=robot.joints)
  rt.set_timestep(0.005)
  rt.set_friction(1.0)
  rt.set_ground_friction(1.0)
  for j, name in robot.joints {
    rt.configure_joint_actuator(
      name,
      robot.stiffness[j],
      robot.damping[j],
      robot.effort[j],
      robot.armature[j],
    )
  }
  let mut windows = 0
  let mut worst_pos = 0.0
  let mut worst_ori = 0.0
  let mut worst_joint = 0.0
  let mut worst_torque_ratio = 0.0
  let mut contact_steps = 0
  let mut steps = 0
  for start = 0; start < rows.length() - 1; start = start + 5 {
    let s = target.states[start]
    rt.reset_data()
    set_pose(rt, layout, s)
    let raw = rt.state()
    let omega = @aligned.mat_vec(@aligned.transpose(s.rotation), s.w)
    for k in 0..<3 {
      raw[layout.nq + k] = s.v[k]
      raw[layout.nq + 3 + k] = omega[k]
    }
    for j, address in layout.qvel_addresses {
      raw[layout.nq + address] = s.qd[j]
    }
    rt.set_state(raw)
    windows += 1
    for f in (start + 1)..<=(start + 5).min(rows.length() - 1) {
      let ref = target.states[f]
      ignore(rt.step(ref.q[:robot.joints.length()].to_owned(), 4))
      let measured = @tracking.state(rt, layout)
      worst_pos = worst_pos.max(distance(measured.p, ref.p))
      worst_ori = worst_ori.max(angle(measured.rotation, ref.rotation))
      let mut square = 0.0
      for j, tau in rt.actuator_force() {
        let error = measured.q[j] - ref.q[j]
        square += error * error
        worst_torque_ratio = worst_torque_ratio.max(tau.abs() / robot.effort[j])
      }
      worst_joint = worst_joint.max(
        (square / robot.joints.length().to_double()).sqrt(),
      )
      if rt.collision_contacts().any(c => c.body_a == 0 || c.body_b == 0) {
        contact_steps += 1
      }
      steps += 1
    }
  }
  let dynamic_ok = worst_pos <= 0.08 &&
    worst_ori <= 0.30 &&
    worst_joint <= 0.25 &&
    contact_steps > 0 &&
    worst_torque_ratio <= 1.00001
  {
    "accepted": smooth && dynamic_ok,
    "smooth": smooth,
    "bounded_servo_tracking": dynamic_ok,
    "acceleration_order": ["root m/s2", "root rad/s2", "max joint rad/s2"],
    "source_p95": src,
    "target_p95": dst,
    "p95_limits": limits,
    "binomial_taps": 9,
    "passes": 3,
    "window_steps": 5,
    "windows": windows,
    "steps": steps,
    "ground_contact_steps": contact_steps,
    "peak_actuator_effort_fraction": worst_torque_ratio,
    "max_root_error_m": worst_pos,
    "max_root_angle_rad": worst_ori,
    "max_joint_rms_rad": worst_joint,
    "limits": {
      "max_root_error_m": 0.08,
      "max_root_angle_rad": 0.30,
      "max_joint_rms_rad": 0.25,
    },
    "scope": "local forward dynamics from reference resets with effort-limited servos and simulated contacts",
  }
}
