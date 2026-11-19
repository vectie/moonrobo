///|
/// Pivoted dense solve for the small damped IK normal equations.
fn solve_ik(
  matrix : Array[Array[Double]],
  rhs : Array[Double],
) -> Array[Double] raise {
  let n = rhs.length()
  let a = matrix.map(row => row.copy())
  let b = rhs.copy()
  for k in 0..<n {
    let mut pivot = k
    for i in (k + 1)..<n {
      if a[i][k].abs() > a[pivot][k].abs() {
        pivot = i
      }
    }
    guard a[pivot][k].abs() > 1.0e-12 else {
      fail("singular retargeting system")
    }
    let row = a[k]
    a[k] = a[pivot]
    a[pivot] = row
    let value = b[k]
    b[k] = b[pivot]
    b[pivot] = value
    for i in (k + 1)..<n {
      let factor = a[i][k] / a[k][k]
      for j in k..<n {
        a[i][j] -= factor * a[k][j]
      }
      b[i] -= factor * b[k]
    }
  }
  let x = Array::make(n, 0.0)
  for count in 0..<n {
    let i = n - 1 - count
    let mut rest = b[i]
    for j in (i + 1)..<n {
      rest -= a[i][j] * x[j]
    }
    x[i] = rest / a[i][i]
  }
  x
}

///|
fn ik_positions(
  kin : @aligned.Kinematics,
  state : @aligned.State,
) -> Array[Double] {
  let result = []
  for body in kin.forward(state) {
    result.append(body.p)
  }
  result
}

///|
/// Kinematic G1-to-E1 retarget. Source FK supplies task-space targets, with
/// temporal/velocity/joint bounds and inferred stance-foot locking. Reports
/// explicitly distinguish kinematic acceptance from dynamic feasibility.
pub fn retarget(
  source : @aligned.MotionLibrary,
  source_kin : @aligned.Kinematics,
  target_kin : @aligned.Kinematics,
  robot : Profile,
  max_foot_error~ : Double = 0.08,
) -> (Array[Array[Double]], Json) raise {
  guard source.names.length() == 1 &&
    source_kin.tracked.length() == 14 &&
    target_kin.tracked.length() == 14 &&
    max_foot_error > 0.0 &&
    max_foot_error <= 0.2 else {
    fail("retarget requires one clip and matched 14-body correspondence")
  }
  let zero = [0.0, 0.0, 0.0]
  let base : @aligned.State = {
    p: zero,
    rotation: @aligned.identity(),
    v: zero,
    w: zero,
    q: @aligned.default_joint_positions(),
    qd: Array::make(29, 0.0),
  }
  let src_default = source_kin.forward(base)
  let dst_default = target_kin.forward({
    ..base,
    q: robot.embed(robot.default_q),
  })
  let ratio = -(dst_default[3].p[2] + dst_default[6].p[2]) /
    2.0 /
    (-(src_default[3].p[2] + src_default[6].p[2]) / 2.0)
  guard @numeric.finite(ratio) && ratio > 0.5 && ratio < 2.0 else {
    fail("invalid retarget morphology scale")
  }
  let mut previous = robot.embed(robot.default_q)
  let locks : Array[Array[Double]?] = [None, None]
  let rows = []
  let mut maximum = 0.0
  let mut rejected = 0
  let mut contacts = 0
  let n = robot.joints.length()
  let mut ground = 1.0e9
  for f in 0..<source.states.length() {
    let bodies = source_kin.forward(source.states[f])
    ground = ground.min(bodies[3].p[2]).min(bodies[6].p[2])
  }
  for f in 0..<source.states.length() {
    let s = source.states[f]
    let bodies = source_kin.forward(s)
    let goals = bodies.map(body => body.p.map(x => x * ratio))
    for k, foot in [3, 6] {
      let speed = bodies[foot].v
        .map(x => x * x)
        .fold(init=0.0, (a, b) => a + b)
        .sqrt()
      let contact = bodies[foot].p[2] < ground + 0.08 && speed < 0.3
      if contact {
        contacts += 1
        if locks[k] is None {
          locks[k] = Some(goals[foot].copy())
        }
        goals[foot] = locks[k].unwrap().copy()
      } else {
        locks[k] = None
      }
    }
    let p = s.p.map(x => x * ratio)
    let q = previous.copy()
    for _ in 0..<24 {
      let pose = { ..s, p, q, qd: Array::make(29, 0.0), }
      let actual = ik_positions(target_kin, pose)
      let residual = Array::makei(42, i => {
        (goals[i / 3][i % 3] - actual[i]) *
        (if i / 3 == 3 || i / 3 == 6 { 4.0 } else { 1.0 })
      })
      let jacobian = Array::makei(n + 3, j => {
        let perturbed_q = q.copy()
        let perturbed_p = p.copy()
        if j < n {
          perturbed_q[j] += 0.0001
        } else {
          perturbed_p[j - n] += 0.0001
        }
        let next = ik_positions(target_kin, {
          ..pose,
          q: perturbed_q,
          p: perturbed_p,
        })
        Array::makei(42, i => {
          (next[i] - actual[i]) /
          0.0001 *
          (if i / 3 == 3 || i / 3 == 6 { 4.0 } else { 1.0 })
        })
      })
      let normal = Array::makei(n + 3, i => {
        Array::makei(n + 3, j => {
          let mut value = if i == j { 0.003 } else { 0.0 }
          for k in 0..<42 {
            value += jacobian[i][k] * jacobian[j][k]
          }
          value
        })
      })
      let rhs = Array::makei(n + 3, j => {
        let mut value = 0.0
        for k in 0..<42 {
          value += jacobian[j][k] * residual[k]
        }
        value
      })
      let delta = solve_ik(normal, rhs)
      for j in 0..<n {
        let lo = if f == 0 {
          target_kin.q_lo[j]
        } else {
          target_kin.q_lo[j].max(previous[j] - robot.velocity[j] * 0.02)
        }
        let hi = if f == 0 {
          target_kin.q_hi[j]
        } else {
          target_kin.q_hi[j].min(previous[j] + robot.velocity[j] * 0.02)
        }
        q[j] = (q[j] + delta[j].max(-0.15).min(0.15)).max(lo).min(hi)
      }
      for j in 0..<3 {
        p[j] += delta[n + j].max(-0.02).min(0.02)
      }
    }
    let final_bodies = target_kin.forward({ ..s, p, q, })
    for foot in [3, 6] {
      let error = @aligned.vec_sub(final_bodies[foot].p, goals[foot])
        .map(x => x * x)
        .fold(init=0.0, (a, b) => a + b)
        .sqrt()
      maximum = maximum.max(error)
      if error > max_foot_error {
        rejected += 1
      }
    }
    let quat = @aligned.mat_to_quat(s.rotation)
    let row = p.copy()
    row.append([quat[1], quat[2], quat[3], quat[0]])
    row.append(q)
    rows.push(row)
    previous = q
  }
  let report : Json = {
    "method": "G1 FK to constrained E1 positional IK, morphology scale, stance-foot locking",
    "frames": Json(rows.length()),
    "root_scale": Json(ratio),
    "maximum_foot_target_error_m": Json(maximum),
    "foot_error_limit_m": Json(max_foot_error),
    "rejected_foot_samples": Json(rejected),
    "stance_samples": Json(contacts),
    "accepted": Json(rejected == 0),
    "self_collision_checked": false,
    "dynamic_feasibility_checked": false,
    "scope": "kinematic candidate; require collision and tracking evaluation before admission to a production training catalog",
  }
  (rows, report)
}
