///|
pub fn from_observation(
  geometry : @balance.Kinematics,
  observation : Array[Double],
) -> Array[Double] {
  let obs = observation.map(round)
  let positions = [[0.0, 0.0, 0.0]]
  let rotations = [@balance.identity()]
  for i in 1..<geometry.bodies.length() {
    let body = geometry.bodies[i]
    let pr = rotations[body.parent]
    let pp = positions[body.parent]
    let mut r = matmul(pr, quaternion_matrix(body.quaternion_wxyz.map(round)))
    let offset = matvec(pr, body.position.map(round))
    let mut p = Array::makei(3, fn(j) { add(pp[j], offset[j]) })
    for joint in body.joints {
      let delta = matvec(r, joint.anchor.map(round))
      let anchor = Array::makei(3, fn(j) { add(p[j], delta[j]) })
      let angle = sub(obs[joint.observation_index], joint.reference)
      r = matmul(r, rotation_vector(joint.axis.map(fn(v) { mul(v, angle) })))
      let rotated = matvec(r, joint.anchor.map(round))
      p = Array::makei(3, fn(j) { sub(anchor[j], rotated[j]) })
    }
    positions.push(p)
    rotations.push(r)
  }
  let mut mass = 0.0
  for body in geometry.bodies {
    mass = add(mass, body.mass)
  }
  let com = [0.0, 0.0, 0.0]
  for i, body in geometry.bodies {
    let center = matvec(rotations[i], body.com_position.map(round))
    let fraction = div(body.mass, mass)
    for j in 0..<3 {
      com[j] = add(com[j], mul(add(positions[i][j], center[j]), fraction))
    }
  }
  let support = [0.0, 0.0, 0.0]
  for foot in geometry.feet {
    let offset = matvec(rotations[foot.body], foot.position.map(round))
    for j in 0..<3 {
      support[j] = add(support[j], add(positions[foot.body][j], offset[j]))
    }
  }
  let difference = Array::makei(3, fn(j) {
    sub(com[j], div(support[j], geometry.feet.length().to_double()))
  })
  let gravity = Array::makei(3, fn(j) { obs[2 * geometry.nu + j] })
  let norm = @balance.clip(
    sqrt(dot(gravity, gravity)),
    round(1.0e-12),
    1.0 / 0.0,
  )
  let unit = gravity.map(fn(v) { div(v, norm) })
  let projected = dot(difference, unit)
  Array::makei(3, fn(j) { sub(difference[j], mul(unit[j], projected)) })
}

///|
/// Float32-rounded local body poses for downstream reference rewards.
pub fn body_poses(
  geometry : @balance.Kinematics,
  q : Array[Double],
) -> (Array[Array[Double]], Array[Array[Double]]) {
  let positions = [[0.0, 0.0, 0.0]]
  let rotations = [@balance.identity()]
  for i in 1..<geometry.bodies.length() {
    let body = geometry.bodies[i]
    let pr = rotations[body.parent]
    let pp = positions[body.parent]
    let mut r = matmul(pr, quaternion_matrix(body.quaternion_wxyz.map(round)))
    let offset = matvec(pr, body.position.map(round))
    let mut p = Array::makei(3, fn(j) { add(pp[j], offset[j]) })
    for joint in body.joints {
      let delta = matvec(r, joint.anchor.map(round))
      let anchor = Array::makei(3, fn(j) { add(p[j], delta[j]) })
      let angle = sub(q[joint.observation_index], joint.reference)
      r = matmul(r, rotation_vector(joint.axis.map(fn(v) { mul(v, angle) })))
      let rotated = matvec(r, joint.anchor.map(round))
      p = Array::makei(3, fn(j) { sub(anchor[j], rotated[j]) })
    }
    positions.push(p)
    rotations.push(r)
  }
  (positions, rotations)
}
