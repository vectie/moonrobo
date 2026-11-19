///|
/// Active-set box-constrained quadratic step. Re-solving free coordinates
/// avoids the incorrect solve-then-clamp update at saturated joints.
fn bounded_ik(
  matrix : Array[Array[Double]],
  rhs : Array[Double],
  lo : Array[Double],
  hi : Array[Double],
) -> Array[Double] raise {
  let a = matrix.map(row => row.copy())
  let b = rhs.copy()
  let fixed = Array::make(rhs.length(), false)
  let mut x = solve_ik(a, b)
  for _ in 0..<rhs.length() {
    let mut worst = -1
    let mut excess = 1.0e-10
    for j in 0..<x.length() {
      if !fixed[j] {
        let e = (lo[j] - x[j]).max(x[j] - hi[j])
        if e > excess {
          excess = e
          worst = j
        }
      }
    }
    if worst < 0 {
      break
    }
    let value = x[worst].max(lo[worst]).min(hi[worst])
    fixed[worst] = true
    for j in 0..<x.length() {
      if j != worst {
        b[j] -= a[j][worst] * value
        a[j][worst] = 0.0
        a[worst][j] = 0.0
      }
    }
    a[worst][worst] = 1.0
    b[worst] = value
    x = solve_ik(a, b)
  }
  Array::makei(x.length(), j => x[j].max(lo[j]).min(hi[j]))
}

///|
fn task_jacobians(
  kin : @aligned.Kinematics,
  s : @aligned.State,
  n : Int32,
) -> (
  Array[@aligned.BodyState],
  Array[Array[Array[Double]]],
  Array[Array[Array[Double]]],
) {
  let all = kin.forward(s, all_bodies=true)
  let positions = []
  let rotations = []
  for tracked in kin.tracked {
    let jp = Array::makei(n + 6, _ => [0.0, 0.0, 0.0])
    let jr = Array::makei(n + 6, _ => [0.0, 0.0, 0.0])
    for k in 0..<3 {
      jp[n + k][k] = 1.0
    }
    for k in 0..<3 {
      let axis = [0.0, 0.0, 0.0]
      axis[k] = 1.0
      jp[n + 3 + k] = @aligned.cross(
        axis,
        @aligned.vec_sub(all[tracked].p, s.p),
      )
      jr[n + 3 + k] = axis
    }
    let mut node = tracked
    while kin.bodies[node].parent >= 0 {
      let spec = kin.bodies[node]
      if spec.joint >= 0 {
        let par = all[spec.parent]
        let off = @aligned.mat_mul(par.rotation, spec.offset_rotation)
        let axis = @aligned.mat_vec(off, spec.axis)
        let pivot = @aligned.vec_add(
          @aligned.vec_add(par.p, @aligned.mat_vec(par.rotation, spec.offset_p)),
          @aligned.mat_vec(off, spec.pivot),
        )
        jp[spec.joint] = @aligned.cross(
          axis,
          @aligned.vec_sub(all[tracked].p, pivot),
        )
        jr[spec.joint] = axis
      }
      node = spec.parent
    }
    positions.push(jp)
    rotations.push(jr)
  }
  (kin.tracked.map(i => all[i]), positions, rotations)
}

///|
pub(all) enum ArmOrientation {
  Original
  Shoulders
  Elbows
  ShouldersAndElbows
  ArmsOnly
  ArmsGuarded
} derive(Eq)

///|
/// Match the pre-existing distal-arm residual scale. Both the IK step and its
/// line search must use exactly the same active terms and weights.
fn rotation_weight(b : Int32, stance : Bool, arms : ArmOrientation) -> Double {
  match b {
    3 | 6 => if stance { 3.0 } else { 0.8 }
    7 => 0.25
    10 | 13 => 0.12
    8 | 11 =>
      if arms == Shoulders || arms == ShouldersAndElbows {
        0.12
      } else {
        0.0
      }
    9 | 12 =>
      if arms == Elbows || arms == ShouldersAndElbows {
        0.12
      } else {
        0.0
      }
    _ => 0.0
  }
}

///|
fn ArmOrientation::label(self : ArmOrientation) -> String {
  match self {
    Original => "original"
    Shoulders => "shoulders"
    Elbows => "elbows"
    ShouldersAndElbows => "both"
    ArmsOnly => "arms-only"
    ArmsGuarded => "arms-guarded"
  }
}

///|
/// A single fraction for the whole clip preserves the convex joint position
/// and velocity bounds. Geometry is nonlinear and is screened after mixing.
fn blended_arm_q(
  q : Array[Double],
  base : Array[Double],
  columns : Array[Int32],
  fraction : Double,
) -> Array[Double] {
  let out = q.copy()
  for j in columns {
    let start = base[7 + j]
    out[j] = start + fraction * (q[j] - start)
  }
  out
}

///|
fn trajectory_cost(
  kin : @aligned.Kinematics,
  pose : @aligned.State,
  goals : Array[Array[Double]],
  rotations : Array[Array[Double]],
  contacts : Array[Bool],
  runtime : @sim.Runtime?,
  layout : @aligned.JointLayout?,
  arms : ArmOrientation,
) -> (Double, Double) raise {
  let actual = kin.forward(pose)
  let mut cost = 0.0
  let mut self_depth = 0.0
  let root_angle = angle(pose.rotation, rotations[0])
  cost += 0.25 * root_angle * root_angle
  for b in 0..<14 {
    let foot = b == 3 || b == 6
    let stance = (b == 3 && contacts[0]) || (b == 6 && contacts[1])
    let weight = if stance {
      30.0
    } else if foot {
      6.0
    } else if b == 10 || b == 13 {
      2.0
    } else {
      1.0
    }
    let e = distance(actual[b].p, goals[b])
    cost += weight * weight * e * e
    let rw = rotation_weight(b, stance, arms)
    if rw > 0.0 {
      let e = angle(actual[b].rotation, rotations[b])
      cost += rw * rw * e * e
    }
  }
  if runtime is Some(rt) && layout is Some(addresses) {
    set_pose(rt, addresses, pose)
    for c in rt.collision_contacts() {
      if c.body_a > 0 && c.body_b > 0 {
        self_depth = self_depth.max(-c.distance)
      }
      if c.body_a >= 0 && c.body_b >= 0 && c.distance < 0.003 {
        let e = (0.003 - c.distance) * 15.0
        cost += e * e
      }
    }
  }
  (cost, self_depth)
}

///|
/// G1's zero forearm points forward. E1's zero forearm hangs down.
/// Match those anatomical frames when deriving offsets, leaving the poses in
/// the source motion (and the E1-to-E1 vendor transfer) unchanged.
fn source_bind_pose(
  kin : @aligned.Kinematics,
  zero : @aligned.State,
  legacy_zero_bind : Bool,
) -> @aligned.State raise {
  if legacy_zero_bind || kin.bodies[kin.tracked[0]].name != "pelvis" {
    return zero
  }
  let q = zero.q.copy()
  for (marker, name) in [(9, "left_elbow_link"), (12, "right_elbow_link")] {
    let elbow = kin.bodies[kin.tracked[marker]]
    guard elbow.name == name && elbow.joint >= 0 && elbow.joint < q.length() else {
      fail("invalid G1 elbow marker: " + name)
    }
    q[elbow.joint] = @math.PI / 2.0
  }
  { ..zero, q, }
}

///|
/// Angles between the physical shoulder, elbow and distal markers. Equal
/// weight for each side and frame. World directions retain root orientation.
fn arm_fidelity(
  source : @aligned.MotionLibrary,
  rows : Array[Array[Double]],
  source_kin : @aligned.Kinematics,
  target_kin : @aligned.Kinematics,
) -> Json raise {
  fn direction(
    a : @aligned.BodyState,
    b : @aligned.BodyState,
  ) -> Array[Double] raise {
    let length = distance(a.p, b.p)
    guard length > 1.0e-6 else { fail("coincident arm markers") }
    @aligned.vec_scale(@aligned.vec_sub(b.p, a.p), 1.0 / length)
  }
  fn degrees(a : Array[Double], b : Array[Double]) -> Double {
    let cosine = a[0] * b[0] + a[1] * b[1] + a[2] * b[2]
    @math.acos(cosine.max(-1.0).min(1.0)) * 180.0 / @math.PI
  }
  let mut bend = 0.0
  let mut forearm = 0.0
  for f, row in rows {
    let src = source_kin.forward(source.states[f])
    let dst = target_kin.forward(state_of_row(row))
    for j in [8, 11] {
      let a = direction(src[j + 1], src[j + 2])
      let b = direction(dst[j + 1], dst[j + 2])
      forearm += degrees(a, b)
      bend += (degrees(direction(src[j], src[j + 1]), a) -
      degrees(direction(dst[j], dst[j + 1]), b)).abs()
    }
  }
  let count = (2 * rows.length()).to_double()
  {
    "mean_elbow_bend_error_deg": bend / count,
    "mean_world_forearm_error_deg": forearm / count,
  }
}

///|
/// Full trajectory constrained IK with analytic task Jacobians. Retained source
/// frames and any global time scaling are declared by the caller.
fn fit_trajectory(
  source : @aligned.MotionLibrary,
  source_kin : @aligned.Kinematics,
  target_kin : @aligned.Kinematics,
  robot : Profile,
  collision_runtime~ : @sim.Runtime? = None,
  smooth~ : Bool = false,
  legacy_zero_bind~ : Bool = false,
  self_depth_limit? : Double,
  arms~ : ArmOrientation = Original,
  fixed_base? : Array[Array[Double]],
  arm_fraction~ : Double = 1.0,
  target_z_shift~ : Double = 0.0,
) -> (Array[Array[Double]], Json) raise {
  let n = robot.joints.length()
  guard arm_fraction == 1.0 ||
    (fixed_base is Some(_) && arm_fraction > 0.0 && arm_fraction < 1.0) else {
    fail("invalid arm correction fraction")
  }
  let columns = Array::makei(n + 6, i => i).filter(i => {
    fixed_base is None || (i < n && robot.joints[i].contains("_arm_"))
  })
  if fixed_base is Some(rows) {
    guard !smooth &&
      rows.length() == source.states.length() &&
      !columns.is_empty() else {
      fail("invalid fixed-base arm trajectory")
    }
  }
  let layout = collision_runtime.map(rt => {
    rt.configure_collision(true)
    @tracking.joint_layout(rt, names=robot.joints)
  })
  let sole_boxes = collision_runtime.map(rt => {
    ["l_leg_ankle_roll_link", "r_leg_ankle_roll_link"].map(name => {
      rt.body_box(id_of_body(rt, name))
    })
  })
  let zero : @aligned.State = {
    p: [0.0, 0.0, 0.0],
    rotation: @aligned.identity(),
    v: [0.0, 0.0, 0.0],
    w: [0.0, 0.0, 0.0],
    q: Array::make(29, 0.0),
    qd: Array::make(29, 0.0),
  }
  let src_bind = source_kin.forward(
    source_bind_pose(source_kin, zero, legacy_zero_bind),
  )
  let dst_bind = target_kin.forward(zero)
  let parents = [-1, 0, 1, 2, 0, 4, 5, 0, 7, 8, 9, 7, 11, 12]
  let lengths = Array::makei(14, b => {
    if b == 0 {
      1.0
    } else {
      distance(dst_bind[b].p, dst_bind[parents[b]].p) /
      distance(src_bind[b].p, src_bind[parents[b]].p).max(1.0e-6)
    }
  })
  let leg_scale = (
      distance(dst_bind[1].p, dst_bind[3].p) +
      distance(dst_bind[4].p, dst_bind[6].p)
    ) /
    (
      distance(src_bind[1].p, src_bind[3].p) +
      distance(src_bind[4].p, src_bind[6].p)
    )
  let corrections = Array::makei(14, b => {
    @aligned.mat_mul(
      @aligned.transpose(src_bind[b].rotation),
      dst_bind[b].rotation,
    )
  })
  let source_bodies = Array::makei(source.states.length(), i => {
    source_kin.forward(source.states[i])
  })
  let mut floor = 1.0e9
  for bodies in source_bodies {
    for b in [3, 6] {
      floor = floor.min(bodies[b].p[2])
    }
  }
  let locks : Array[Array[Double]?] = [None, None]
  let mut previous = robot.embed(robot.default_q)
  let mut previous_p = source.states[0].p.map(x => x * leg_scale)
  let mut previous_rotation = source.states[0].rotation.copy()
  let rows = []
  let position_targets = []
  let rotation_targets = []
  let mut worst_stance = 0.0
  let mut worst_stance_angle = 0.0
  let mut square_body = 0.0
  let mut stance_samples = 0
  let mut maximum_hand_angle = 0.0
  let mut maximum_foot_error = 0.0
  let mut rejected_foot_samples = 0
  let mut source_square = 0.0
  let mut maximum_root_angle = 0.0
  let stance_flags : Array[Array[Bool]] = []
  for f in 0..<source.states.length() {
    let s = source.states[f]
    let bodies = source_bodies[f]
    let goals : Array[Array[Double]] = [s.p.map(x => x * leg_scale)]
    for b in 1..<14 {
      let parent = parents[b]
      let source_bind_delta = @aligned.vec_scale(
        @aligned.vec_sub(src_bind[b].p, src_bind[parent].p),
        lengths[b],
      )
      let target_bind_delta = @aligned.vec_sub(
        dst_bind[b].p,
        dst_bind[parent].p,
      )
      let anatomical_offset = @aligned.mat_vec(
        @aligned.mat_mul(
          bodies[parent].rotation,
          @aligned.transpose(src_bind[parent].rotation),
        ),
        @aligned.vec_sub(target_bind_delta, source_bind_delta),
      )
      goals.push(
        @aligned.vec_add(
          goals[parent],
          @aligned.vec_add(
            @aligned.vec_scale(
              @aligned.vec_sub(bodies[b].p, bodies[parent].p),
              lengths[b],
            ),
            anatomical_offset,
          ),
        ),
      )
    }
    let goal_rotations = Array::makei(14, b => {
      @aligned.mat_mul(bodies[b].rotation, corrections[b])
    })
    let contacts = [false, false]
    for k, b in [3, 6] {
      let speed = bodies[b].v
        .map(x => x * x)
        .fold(init=0.0, (a, b) => a + b)
        .sqrt()
      contacts[k] = bodies[b].p[2] < floor + 0.04 && speed < 0.25
      if contacts[k] {
        if locks[k] is None {
          locks[k] = Some(goals[b].copy())
        }
        goals[b] = locks[k].unwrap().copy()
        if sole_boxes is Some(boxes) {
          let (center, size) = boxes[k]
          let r = goal_rotations[b]
          // Project the inferred support target onto the actual sole plane.
          // Source ankle height is not a floor-contact constraint.
          goals[b][2] = -(r[6] * center[0] + r[7] * center[1] + r[8] * center[2]) +
            r[6].abs() * size[0] +
            r[7].abs() * size[1] +
            r[8].abs() * size[2]
        }
      } else {
        locks[k] = None
      }
    }
    if fixed_base is Some(_) {
      for goal in goals {
        goal[2] += target_z_shift
      }
    }
    stance_flags.push(contacts)
    let desired_p = s.p.map(x => x * leg_scale)
    let base = fixed_base.map(rows => rows[f])
    let p = if base is Some(row) {
      row[:3].to_owned()
    } else if f == 0 {
      desired_p.copy()
    } else {
      let delta = @aligned.vec_sub(s.p, source.states[f - 1].p)
      Array::makei(3, k => previous_p[k] + delta[k] * leg_scale)
    }
    let q = previous.copy()
    let mut rotation = if base is Some(row) {
      state_of_row(row).rotation
    } else if f == 0 {
      s.rotation.copy()
    } else {
      @aligned.mat_mul(
        @aligned.mat_mul(
          s.rotation,
          @aligned.transpose(source.states[f - 1].rotation),
        ),
        previous_rotation,
      )
    }
    let lo = Array::makei(n, j => {
      if f == 0 {
        target_kin.q_lo[j]
      } else {
        target_kin.q_lo[j].max(previous[j] - robot.velocity[j] * 0.02)
      }
    })
    let hi = Array::makei(n, j => {
      if f == 0 {
        target_kin.q_hi[j]
      } else {
        target_kin.q_hi[j].min(previous[j] + robot.velocity[j] * 0.02)
      }
    })
    if base is Some(row) {
      for j in 0..<n {
        q[j] = if columns.contains(j) {
          row[7 + j].max(lo[j]).min(hi[j])
        } else {
          row[7 + j]
        }
      }
    }
    for iteration in 0..<(if f == 0 { 50 } else { 15 }) {
      let pose = { ..s, p, q, rotation, qd: Array::make(29, 0.0), }
      let (actual, jp, jr) = task_jacobians(target_kin, pose, n)
      let residual : Array[Double] = []
      let jac : Array[Array[Double]] = []
      for b in 0..<14 {
        let foot = b == 3 || b == 6
        let stance = (b == 3 && contacts[0]) || (b == 6 && contacts[1])
        let weight = if stance {
          30.0
        } else if foot {
          6.0
        } else if b == 10 || b == 13 {
          2.0
        } else {
          1.0
        }
        for axis in 0..<3 {
          residual.push((goals[b][axis] - actual[b].p[axis]) * weight)
          jac.push(Array::makei(n + 6, j => jp[b][j][axis] * weight))
        }
        let rw = rotation_weight(b, stance, arms)
        if rw > 0.0 {
          let r = @aligned.so3_log(
            @aligned.mat_mul(
              goal_rotations[b],
              @aligned.transpose(actual[b].rotation),
            ),
          )
          for axis in 0..<3 {
            residual.push(r[axis] * rw)
            jac.push(Array::makei(n + 6, j => jr[b][j][axis] * rw))
          }
        }
      }
      let root_error = @aligned.so3_log(
        @aligned.mat_mul(s.rotation, @aligned.transpose(rotation)),
      )
      for axis in 0..<3 {
        residual.push(root_error[axis] * 0.5)
        jac.push(
          Array::makei(n + 6, j => if j == n + 3 + axis { 0.5 } else { 0.0 }),
        )
      }
      if collision_runtime is Some(rt) && layout is Some(addresses) {
        set_pose(rt, addresses, pose)
        for contact in rt.collision_contacts() {
          if contact.body_a < 0 ||
            contact.body_b < 0 ||
            contact.distance >= 0.003 {
            continue
          }
          let a = if contact.body_a == 0 {
            Array::makei(3, _ => Array::make(addresses.nv, 0.0))
          } else {
            rt.point_jacobian(contact.point, contact.body_a)
          }
          let b = if contact.body_b == 0 {
            Array::makei(3, _ => Array::make(addresses.nv, 0.0))
          } else {
            rt.point_jacobian(contact.point, contact.body_b)
          }
          let weight = 15.0
          residual.push((0.003 - contact.distance) * weight)
          jac.push(
            Array::makei(n + 6, j => {
              let mut gradient = 0.0
              for k in 0..<3 {
                let velocity = if j < n + 3 {
                  let dof = if j < n {
                    addresses.qvel_addresses[j]
                  } else {
                    j - n
                  }
                  b[k][dof] - a[k][dof]
                } else {
                  let mut v = 0.0
                  for l in 0..<3 {
                    v += (b[k][3 + l] - a[k][3 + l]) *
                      rotation[(j - n - 3) * 3 + l]
                  }
                  v
                }
                gradient += contact.normal_a_to_b[k] * velocity
              }
              gradient * weight
            }),
          )
        }
      }
      let normal = columns.map(i => {
        columns.map(j => {
          let mut v = if i == j { 0.002 } else { 0.0 }
          for row in jac {
            v += row[i] * row[j]
          }
          v
        })
      })
      let rhs = columns.map(j => {
        let mut v = 0.0
        for i, row in jac {
          v += row[j] * residual[i]
        }
        v
      })
      let step_lo = columns.map(j => {
        if j < n {
          (lo[j] - q[j]).max(-0.2)
        } else if j < n + 3 {
          -0.025
        } else {
          -0.08
        }
      })
      let step_hi = columns.map(j => {
        if j < n {
          (hi[j] - q[j]).min(0.2)
        } else if j < n + 3 {
          0.025
        } else {
          0.08
        }
      })
      let solved = bounded_ik(normal, rhs, step_lo, step_hi)
      let delta = Array::make(n + 6, 0.0)
      for k, j in columns {
        delta[j] = solved[k]
      }
      let (before, depth_before) = trajectory_cost(
        target_kin, pose, goals, goal_rotations, contacts, collision_runtime, layout,
        arms,
      )
      let mut scale = 1.0
      let mut change = 0.0
      for attempt in 0..<6 {
        let next_q = q.copy()
        let next_p = p.copy()
        for j in columns {
          if j >= n {
            continue
          }
          next_q[j] = (q[j] + delta[j] * scale).max(lo[j]).min(hi[j])
        }
        for j in 0..<3 {
          let value = p[j] + delta[n + j] * scale
          next_p[j] = if base is Some(_) {
            p[j]
          } else if f == 0 {
            value
          } else {
            value.max(previous_p[j] - 0.1).min(previous_p[j] + 0.1)
          }
        }
        let dr = Array::makei(3, k => delta[n + 3 + k] * scale)
        let candidate_rotation = @aligned.mat_mul(
          @aligned.so3_exp(dr),
          rotation,
        )
        let offset = @aligned.so3_log(
          @aligned.mat_mul(candidate_rotation, @aligned.transpose(s.rotation)),
        )
        let magnitude = offset
          .map(x => x * x)
          .fold(init=0.0, (a, b) => a + b)
          .sqrt()
        let next_rotation = if base is Some(_) {
          rotation
        } else {
          @aligned.mat_mul(
            @aligned.so3_exp(
              offset.map(x => {
                x * (if magnitude > 0.5 { 0.5 / magnitude } else { 1.0 })
              }),
            ),
            s.rotation,
          )
        }
        let (after, depth_after) = trajectory_cost(
          target_kin,
          { ..pose, p: next_p, q: next_q, rotation: next_rotation, },
          goals,
          goal_rotations,
          contacts,
          collision_runtime,
          layout,
          arms,
        )
        let feasible = match self_depth_limit {
          None => true
          Some(limit) => depth_after <= limit.max(depth_before)
        }
        if feasible && after <= before + 1.0e-12 {
          for j in 0..<n {
            change = change.max((next_q[j] - q[j]).abs())
            q[j] = next_q[j]
          }
          for j in 0..<3 {
            change = change.max((next_p[j] - p[j]).abs())
            p[j] = next_p[j]
          }
          change = change.max(angle(rotation, next_rotation))
          rotation = next_rotation
          break
        }
        scale *= 0.5
        if attempt == 5 {
          change = 0.0
        }
      }
      if iteration >= 2 && change < 1.0e-5 {
        break
      }
    }
    let export_q = if base is Some(row) && arm_fraction != 1.0 {
      blended_arm_q(q, row, columns, arm_fraction)
    } else {
      q
    }
    let fitted = target_kin.forward({ ..s, p, q: export_q, rotation, })
    if smooth {
      position_targets.push(goals)
      rotation_targets.push(goal_rotations)
    }
    maximum_root_angle = maximum_root_angle.max(angle(rotation, s.rotation))
    for b in 0..<14 {
      let err = distance(fitted[b].p, goals[b])
      square_body += err * err
      source_square += 1.0
    }
    for k, b in [3, 6] {
      if !smooth {
        let e = distance(fitted[b].p, goals[b])
        maximum_foot_error = maximum_foot_error.max(e)
        if e > 0.08 {
          rejected_foot_samples += 1
        }
      }
      if contacts[k] {
        stance_samples += 1
        worst_stance = worst_stance.max(distance(fitted[b].p, goals[b]))
        worst_stance_angle = worst_stance_angle.max(
          angle(fitted[b].rotation, goal_rotations[b]),
        )
      }
    }
    for b in [10, 13] {
      maximum_hand_angle = maximum_hand_angle.max(
        angle(fitted[b].rotation, goal_rotations[b]),
      )
    }
    let quat = @aligned.mat_to_quat(rotation)
    let row = p.copy()
    row.append([quat[1], quat[2], quat[3], quat[0]])
    row.append(q)
    if base is Some(fixed) {
      let result = fixed.copy()
      for j in columns {
        result[7 + j] = export_q[j]
      }
      rows.push(result)
    } else {
      rows.push(row)
    }
    previous = q
    previous_p = p
    previous_rotation = rotation
  }
  let fitted_rows = if smooth {
    smooth_locomotion(smooth_locomotion(smooth_locomotion(rows)))
  } else {
    rows
  }
  if smooth {
    // Recompute acceptance on the filtered poses against the original IK goals.
    square_body = 0.0
    worst_stance = 0.0
    worst_stance_angle = 0.0
    maximum_root_angle = 0.0
    maximum_hand_angle = 0.0
    for f, row in fitted_rows {
      let s = state_of_row(row)
      let actual = target_kin.forward(s)
      maximum_root_angle = maximum_root_angle.max(
        angle(s.rotation, source.states[f].rotation),
      )
      for b in 0..<14 {
        let e = distance(actual[b].p, position_targets[f][b])
        square_body += e * e
      }
      for k, b in [3, 6] {
        let e = distance(actual[b].p, position_targets[f][b])
        maximum_foot_error = maximum_foot_error.max(e)
        if e > 0.08 {
          rejected_foot_samples += 1
        }
        if stance_flags[f][k] {
          worst_stance = worst_stance.max(
            distance(actual[b].p, position_targets[f][b]),
          )
          worst_stance_angle = worst_stance_angle.max(
            angle(actual[b].rotation, rotation_targets[f][b]),
          )
        }
      }
      for b in [10, 13] {
        maximum_hand_angle = maximum_hand_angle.max(
          angle(actual[b].rotation, rotation_targets[f][b]),
        )
      }
    }
  }
  (
    fitted_rows,
    {
      "method": "analytic whole-body position/orientation IK; anatomical offsets; bounded QP joint/velocity steps; line search; inferred stance locks; native collision penalties and model-derived sole support when runtime supplied; bounded root translation",
      "frames": rows.length(),
      "leg_scale": leg_scale,
      "body_rms_m": (square_body / source_square).sqrt(),
      "stance_position_max_m": worst_stance,
      "stance_rotation_max_rad": worst_stance_angle,
      "hand_rotation_max_rad": maximum_hand_angle,
      "root_rotation_deviation_max_rad": maximum_root_angle,
      "stance_samples": stance_samples,
      "maximum_foot_target_error_m": maximum_foot_error,
      "foot_error_limit_m": 0.08,
      "rejected_foot_samples": rejected_foot_samples,
      "stance_flags": stance_flags,
      "contacts": "inferred source ankle height and speed; not measured forces",
      "dynamic_feasibility_certified": false,
    },
  )
}
