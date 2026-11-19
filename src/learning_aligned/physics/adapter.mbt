///|
pub fn kinematics(
  runtime : @native_physics.Runtime,
  names~ : Array[String] = @aligned.joint_names(),
  tracked_names~ : Array[String] = @aligned.tracked_body_names(),
  root_name~ : String = "pelvis",
) -> @aligned.Kinematics raise {
  guard names.length() > 0 && names.length() <= 29 else {
    fail("physical joint count must be in 1..29")
  }
  let joint_by_name : Map[String, Int32] = Map([])
  for i in 0..<names.length() {
    joint_by_name[names[i]] = i
  }
  let mut root = -1
  for b in 1..<runtime.body_count() {
    if runtime.body_name(b) == root_name {
      root = b
      break
    }
  }
  guard root > 0 else { fail("compiled model has no pelvis") }
  let bodies : Array[@aligned.BodySpec] = []
  let local : Map[Int32, Int32] = Map([])
  for b in 1..<runtime.body_count() {
    let parent = runtime.body_parent(b)
    if b != root && !local.contains(parent) {
      continue
    }
    let joints = runtime.body_joint_ids(b)
    guard joints.length() <= 1 else {
      fail("G1 FK expects at most one joint per body")
    }
    let jid = joints.get(0).unwrap_or(-1)
    let name = runtime.body_name(b)
    let joint = if b == root {
      guard jid >= 0 && runtime.joint_type(jid) == 0 else {
        fail("G1 pelvis requires free joint")
      }
      -1
    } else if jid < 0 {
      -1
    } else {
      guard runtime.joint_type(jid) == 3 else {
        fail("G1 non-root joint must be hinge")
      }
      guard joint_by_name.get(runtime.joint_name(jid)) is Some(index) else {
        fail("unknown G1 hinge joint")
      }
      index
    }
    local[b] = bodies.length()
    bodies.push({
      name,
      parent: if b == root {
        -1
      } else {
        local[parent]
      },
      joint,
      axis: if jid < 0 {
        [0.0, 0.0, 1.0]
      } else {
        runtime.joint_axis(jid)
      },
      offset_p: runtime.body_offset_pos(b),
      offset_rotation: @aligned.quat_to_mat(runtime.body_offset_quat(b)),
      pivot: if jid < 0 {
        [0.0, 0.0, 0.0]
      } else {
        runtime.joint_pivot(jid)
      },
      qref: if jid < 0 || b == root {
        0.0
      } else {
        runtime.joint_qref(jid)
      },
    })
  }
  let tracked : Array[Int32] = []
  for name in tracked_names {
    let mut found = -1
    for i, body in bodies {
      if body.name == name {
        found = i
        break
      }
    }
    guard found >= 0 else {
      fail("compiled model misses tracked body: " + name)
    }
    tracked.push(found)
  }
  let lo = Array::make(29, 0.0)
  let hi = Array::make(29, 0.0)
  let seen = Array::make(names.length(), false)
  for jid in 0..<runtime.joint_count() {
    if joint_by_name.get(runtime.joint_name(jid)) is Some(j) {
      let (l, h) = runtime.joint_limits(jid)
      lo[j] = l
      hi[j] = h
      seen[j] = true
    }
  }
  guard seen.all(x => x) else { fail("compiled model misses G1 joints") }
  { bodies, tracked, q_lo: lo, q_hi: hi, }
}

///|
pub fn joint_layout(
  runtime : @native_physics.Runtime,
  names~ : Array[String] = @aligned.joint_names(),
) -> @aligned.JointLayout raise {
  let (nq, nv, na, _) = runtime.dimensions()
  let by_name : Map[String, Int32] = Map([])
  for i in 0..<runtime.joint_count() {
    by_name[runtime.joint_name(i)] = i
  }
  let qa : Array[Int32] = []
  let va : Array[Int32] = []
  for name in names {
    guard by_name.get(name) is Some(id) else {
      fail("compiled model misses G1 joint: " + name)
    }
    qa.push(runtime.joint_qpos_address(id))
    va.push(runtime.joint_velocity_address(id))
  }
  { nq, nv, na, qpos_addresses: qa, qvel_addresses: va, }
}

///|
pub fn state(
  runtime : @native_physics.Runtime,
  layout : @aligned.JointLayout,
) -> @aligned.State {
  let raw = runtime.state()
  let rotation = @aligned.quat_to_mat(raw[3:7].to_owned())
  {
    p: raw[0:3].to_owned(),
    rotation,
    v: raw[layout.nq:layout.nq + 3].to_owned(),
    w: @aligned.mat_vec(rotation, raw[layout.nq + 3:layout.nq + 6].to_owned()),
    q: layout.qpos_addresses.map(i => raw[i]),
    qd: layout.qvel_addresses.map(i => raw[layout.nq + i]),
  }
}
