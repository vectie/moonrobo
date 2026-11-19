///|
fn g_dot(
  t : @numeric.Tape,
  a : Array[@numeric.Value],
  b : Array[@numeric.Value],
) -> @numeric.Value {
  let mut sum = t.scalar(0.0)
  for i, x in a {
    sum = t.add(sum, t.mul(x, b[i]))
  }
  sum
}

///|
fn g_unit(
  t : @numeric.Tape,
  x : Array[@numeric.Value],
) -> Array[@numeric.Value] {
  let square = g_dot(t, x, x)
  let norm = if square.value < 1.0e-24 {
    t.scalar(1.0e-12)
  } else {
    t.sqrt(square)
  }
  x.map(v => t.div(v, norm))
}

///|
fn g_mv(
  t : @numeric.Tape,
  a : Array[@numeric.Value],
  x : Array[@numeric.Value],
) -> Array[@numeric.Value] {
  Array::makei(3, i => g_dot(t, a[i * 3:i * 3 + 3].to_owned(), x))
}

///|
fn g_mm(
  t : @numeric.Tape,
  a : Array[@numeric.Value],
  b : Array[@numeric.Value],
) -> Array[@numeric.Value] {
  Array::makei(9, i => {
    g_dot(
      t,
      a[i / 3 * 3:i / 3 * 3 + 3].to_owned(),
      Array::makei(3, j => b[j * 3 + i % 3]),
    )
  })
}

///|
fn g_skew(
  t : @numeric.Tape,
  x : Array[@numeric.Value],
) -> Array[@numeric.Value] {
  [
    t.scalar(0.0),
    t.scale(x[2], -1.0),
    x[1],
    x[2],
    t.scalar(0.0),
    t.scale(x[0], -1.0),
    t.scale(x[1], -1.0),
    x[0],
    t.scalar(0.0),
  ]
}

///|
fn g_rotation(
  t : @numeric.Tape,
  x : Array[@numeric.Value],
) -> Array[@numeric.Value] {
  let theta2 = g_dot(t, x, x)
  let (a, b) = if theta2.value < 1.0e-12 {
    (
      t.add(t.scalar(1.0), t.scale(theta2, -1.0 / 6.0)),
      t.add(t.scalar(0.5), t.scale(theta2, -1.0 / 24.0)),
    )
  } else {
    let theta = t.sqrt(theta2)
    (
      t.div(t.sin(theta), theta),
      t.div(t.sub(t.scalar(1.0), t.cos(theta)), theta2),
    )
  }
  let k = g_skew(t, x)
  let kk = g_mm(t, k, k)
  Array::makei(9, i => {
    t.add(
      t.scalar(if i / 3 == i % 3 { 1.0 } else { 0.0 }),
      t.add(t.mul(a, k[i]), t.mul(b, kk[i])),
    )
  })
}

///|
fn g_quaternion(
  t : @numeric.Tape,
  quaternion : Array[@numeric.Value],
) -> Array[@numeric.Value] {
  let q = g_unit(t, quaternion)
  let w = q[0]
  let x = q[1]
  let y = q[2]
  let z = q[3]
  let diagonal = (a, b) => {
    t.sub(t.scalar(1.0), t.scale(t.add(t.mul(a, a), t.mul(b, b)), 2.0))
  }
  let minus = (a, b, c, d) => t.scale(t.sub(t.mul(a, b), t.mul(c, d)), 2.0)
  let plus = (a, b, c, d) => t.scale(t.add(t.mul(a, b), t.mul(c, d)), 2.0)
  [
    diagonal(y, z),
    minus(x, y, w, z),
    plus(x, z, w, y),
    plus(x, y, w, z),
    diagonal(x, z),
    minus(y, z, w, x),
    minus(x, z, w, y),
    plus(y, z, w, x),
    diagonal(x, y),
  ]
}

///|
pub fn body_poses_graph(
  geometry : @balance.Kinematics,
  t : @numeric.Tape,
  q : Array[@numeric.Value],
) -> (Array[Array[@numeric.Value]], Array[Array[@numeric.Value]]) {
  let positions = [t.vector([0.0, 0.0, 0.0])]
  let rotations = [t.vector(@balance.identity())]
  for i in 1..<geometry.bodies.length() {
    let body = geometry.bodies[i]
    let parent_rotation = rotations[body.parent]
    let parent_position = positions[body.parent]
    let mut r = g_mm(
      t,
      parent_rotation,
      t.vector(@balance.quaternion_matrix(body.quaternion_wxyz)),
    )
    let offset = g_mv(t, parent_rotation, t.vector(body.position))
    let mut p = Array::makei(3, j => t.add(parent_position[j], offset[j]))
    for joint in body.joints {
      let delta = g_mv(t, r, t.vector(joint.anchor))
      let anchor = Array::makei(3, j => t.add(p[j], delta[j]))
      let angle = t.sub(q[joint.observation_index], t.scalar(joint.reference))
      r = g_mm(t, r, g_rotation(t, joint.axis.map(x => t.scale(angle, x))))
      let rotated = g_mv(t, r, t.vector(joint.anchor))
      p = Array::makei(3, j => t.sub(anchor[j], rotated[j]))
    }
    positions.push(p)
    rotations.push(r)
  }
  (positions, rotations)
}

///|
fn balance_error_graph(
  geometry : @balance.Kinematics,
  t : @numeric.Tape,
  p : Array[Array[@numeric.Value]],
  r : Array[Array[@numeric.Value]],
  gravity : Array[@numeric.Value],
) -> Array[@numeric.Value] {
  let com = t.vector([0.0, 0.0, 0.0])
  let mass = geometry.bodies.fold(init=0.0, (sum, body) => sum + body.mass)
  guard mass > 0.0 && !geometry.feet.is_empty() else {
    abort("positive geometry mass and feet required")
  }
  for i, body in geometry.bodies {
    let center = g_mv(t, r[i], t.vector(body.com_position))
    for j in 0..<3 {
      com[j] = t.add(
        com[j],
        t.scale(t.add(p[i][j], center[j]), body.mass / mass),
      )
    }
  }
  for site in geometry.feet {
    let offset = g_mv(t, r[site.body], t.vector(site.position))
    for j in 0..<3 {
      com[j] = t.sub(
        com[j],
        t.scale(
          t.add(p[site.body][j], offset[j]),
          1.0 / geometry.feet.length().to_double(),
        ),
      )
    }
  }
  let vertical = g_dot(t, com, gravity)
  com.mapi((i, x) => t.sub(x, t.mul(gravity[i], vertical)))
}

///|
pub fn from_observation_graph(
  geometry : @balance.Kinematics,
  t : @numeric.Tape,
  observation : Array[@numeric.Value],
) -> Array[@numeric.Value] {
  let (p, r) = body_poses_graph(
    geometry,
    t,
    observation[:geometry.nu].to_owned(),
  )
  balance_error_graph(
    geometry,
    t,
    p,
    r,
    g_unit(t, observation[2 * geometry.nu:2 * geometry.nu + 3].to_owned()),
  )
}

///|
pub fn reference_reward_graph(
  geometry : @balance.Kinematics,
  t : @numeric.Tape,
  state : Array[@numeric.Value],
  action : Array[@numeric.Value],
  previous : Array[@numeric.Value],
  desired_positions : Array[Array[Double]],
  desired_quaternion : Array[Double],
  desired_joints : Array[Double],
  dt~ : Double = 0.02,
) -> (@numeric.Value, Bool, Array[@numeric.Value]) {
  let (p, r) = body_poses_graph(geometry, t, state[7:36].to_owned())
  let rotation = g_quaternion(t, state[3:7].to_owned())
  let squared = p.mapi((i, local) => {
    let world = g_mv(t, rotation, local)
    let error = Array::makei(3, j => {
      t.sub(t.add(world[j], state[j]), t.scalar(desired_positions[i][j]))
    })
    g_dot(t, error, error)
  })
  let body_squared = t.mean(squared)
  let q = g_unit(t, state[3:7].to_owned())
  let cosine = g_dot(t, q, t.vector(unit(desired_quaternion)))
  let orientation_squared = t.scale(
    t.clamp(t.sub(t.scalar(1.0), t.mul(cosine, cosine)), 0.0, 1.0e300),
    4.0,
  )
  let joint_errors = desired_joints.mapi((i, x) => {
    let error = t.sub(state[7 + i], t.scalar(x))
    t.mul(error, error)
  })
  let control_errors = action.mapi((i, x) => {
    let error = t.scale(t.sub(x, previous[i]), 10.0)
    t.mul(error, error)
  })
  let body_reward = t.exp(t.scale(body_squared, -1.0 / 0.0025))
  let root_reward = t.scale(t.exp(t.scale(squared[0], -1.0 / 0.0025)), 0.5)
  let orientation_reward = t.scale(
    t.exp(t.scale(orientation_squared, -100.0)),
    0.5,
  )
  let joint_reward = t.exp(t.scale(t.mean(joint_errors), -1.0 / 0.0009))
  let smoothness = t.scale(t.mean(control_errors), -0.01)
  let reward = t.scale(
    t.add(
      t.add(body_reward, root_reward),
      t.add(t.add(orientation_reward, joint_reward), smoothness),
    ),
    dt,
  )
  let gravity = [
    t.scale(rotation[6], -1.0),
    t.scale(rotation[7], -1.0),
    t.scale(rotation[8], -1.0),
  ]
  (
    reward,
    state[2].value < 0.35 || -gravity[2].value < 0.5,
    balance_error_graph(geometry, t, p, r, gravity),
  )
}

///|
pub fn observer_memory_graph(
  t : @numeric.Tape,
  observation : Array[@numeric.Value],
  features : Array[@numeric.Value],
  nu~ : Int32 = 29,
) -> Array[@numeric.Value] {
  ignore(t)
  let result = features[:3].to_owned()
  result.append(observation[2 * nu:2 * nu + 6].to_owned())
  result.append(features[3:].to_owned())
  result
}

///|
pub fn observer_advance_graph(
  t : @numeric.Tape,
  observation : Array[@numeric.Value],
  memory : Array[@numeric.Value],
  dt : Double,
  error : Array[@numeric.Value],
  nu~ : Int32 = 29,
) -> (Array[@numeric.Value], Array[@numeric.Value]) {
  let g = g_unit(t, observation[2 * nu:2 * nu + 3].to_owned())
  let w = observation[2 * nu + 3:2 * nu + 6].to_owned()
  let transport = g_rotation(
    t,
    w.mapi((i, x) => t.scale(t.add(x, memory[6 + i]), -0.5 * dt)),
  )
  let predicted = g_mv(t, transport, g_unit(t, memory[3:6].to_owned()))
  let cross = [
    t.sub(t.mul(predicted[1], g[2]), t.mul(predicted[2], g[1])),
    t.sub(t.mul(predicted[2], g[0]), t.mul(predicted[0], g[2])),
    t.sub(t.mul(predicted[0], g[1]), t.mul(predicted[1], g[0])),
  ]
  let k = g_skew(t, cross)
  let k2 = g_mm(t, k, k)
  let denominator = t.clamp(
    t.add(t.scalar(1.0), g_dot(t, predicted, g)),
    1.0e-8,
    1.0e300,
  )
  let correction = Array::makei(9, i => {
    t.add(
      t.scalar(if i / 3 == i % 3 { 1.0 } else { 0.0 }),
      t.add(k[i], t.div(k2[i], denominator)),
    )
  })
  let transport = g_mm(t, correction, transport)
  let velocity = g_mv(t, transport, memory[9:12].to_owned())
  let previous = g_mv(t, transport, memory[:3].to_owned())
  let features = error.copy()
  features.append(
    Array::makei(3, i => {
      t.add(
        t.scale(velocity[i], 0.8),
        t.scale(t.sub(error[i], previous[i]), 0.2 / dt),
      )
    }),
  )
  (features, observer_memory_graph(t, observation, features, nu~))
}

///|
pub fn observation_graph(
  t : @numeric.Tape,
  state : Array[@numeric.Value],
  action : Array[@numeric.Value],
) -> Array[@numeric.Value] {
  let rotation = g_quaternion(t, state[3:7].to_owned())
  let obs = state[7:36].to_owned()
  obs.append(state[42:71].to_owned())
  obs.append([
    t.scale(rotation[6], -1.0),
    t.scale(rotation[7], -1.0),
    t.scale(rotation[8], -1.0),
  ])
  obs.append(state[39:42].to_owned())
  obs.append(action)
  obs
}
