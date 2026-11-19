///|
fn dot(a : Array[Double], b : Array[Double]) -> Double {
  a.foldi(init=0.0, (i, sum, x) => sum + x * b[i])
}

///|
fn unit(x : Array[Double]) -> Array[Double] {
  let norm = dot(x, x).sqrt().max(1.0e-12)
  x.map(v => v / norm)
}

///|
fn cross(a : Array[Double], b : Array[Double]) -> Array[Double] {
  [
    a[1] * b[2] - a[2] * b[1],
    a[2] * b[0] - a[0] * b[2],
    a[0] * b[1] - a[1] * b[0],
  ]
}

///|
fn matvec(m : Array[Array[Double]], x : Array[Double]) -> Array[Double] {
  m.map(row => dot(row, x))
}

///|
fn skew(x : Array[Double]) -> Array[Array[Double]] {
  [[0.0, -x[2], x[1]], [x[2], 0.0, -x[0]], [-x[1], x[0], 0.0]]
}

///|
fn matmul(
  a : Array[Array[Double]],
  b : Array[Array[Double]],
) -> Array[Array[Double]] {
  Array::makei(3, i => {
    Array::makei(3, j => {
      a[i][0] * b[0][j] + a[i][1] * b[1][j] + a[i][2] * b[2][j]
    })
  })
}

///|
fn rotation_vector(x : Array[Double]) -> Array[Array[Double]] {
  let theta2 = dot(x, x)
  let theta = theta2.sqrt()
  let a = if theta < 1.0e-6 {
    1.0 - theta2 / 6.0 + theta2 * theta2 / 120.0
  } else {
    @math.sin(theta) / theta
  }
  let b = if theta < 1.0e-6 {
    0.5 - theta2 / 24.0 + theta2 * theta2 / 720.0
  } else {
    (1.0 - @math.cos(theta)) / theta2
  }
  let k = skew(x)
  let k2 = matmul(k, k)
  Array::makei(3, i => {
    Array::makei(3, j => {
      (if i == j { 1.0 } else { 0.0 }) + a * k[i][j] + b * k2[i][j]
    })
  })
}

///|
pub fn observer_memory(
  obs : Array[Double],
  features : Array[Double],
  nu~ : Int32 = 29,
) -> Array[Double] {
  guard features.length() == 6 && obs.length() >= 2 * nu + 6 else {
    abort("observer memory shape")
  }
  let memory = features[:3].to_owned()
  memory.append(obs[2 * nu:2 * nu + 6].to_owned())
  memory.append(features[3:].to_owned())
  memory
}

///|
/// error is the kinematic COM error from geometry.from_observations, or the
/// error reused from reference_reward. EMA history is transported without reset.
pub fn observer_advance(
  obs : Array[Double],
  memory : Array[Double],
  dt : Double,
  error : Array[Double],
  nu~ : Int32 = 29,
) -> (Array[Double], Array[Double]) {
  guard dt > 0.0 && memory.length() == 12 && error.length() == 3 else {
    abort("observer state shape")
  }
  let e0 = memory[:3].to_owned()
  let g0 = memory[3:6].to_owned()
  let w0 = memory[6:9].to_owned()
  let v0 = memory[9:12].to_owned()
  let g = obs[2 * nu:2 * nu + 3].to_owned()
  let w = obs[2 * nu + 3:2 * nu + 6].to_owned()
  let transport = rotation_vector(w.mapi((i, x) => -0.5 * dt * (x + w0[i])))
  let predicted = matvec(transport, unit(g0))
  let gravity = unit(g)
  let k = skew(cross(predicted, gravity))
  let k2 = matmul(k, k)
  let denominator = (1.0 + dot(predicted, gravity)).max(1.0e-8)
  let correction = Array::makei(3, i => {
    Array::makei(3, j => {
      (if i == j { 1.0 } else { 0.0 }) + k[i][j] + k2[i][j] / denominator
    })
  })
  let transport = matmul(correction, transport)
  let velocity = matvec(transport, v0)
  let previous = matvec(transport, e0)
  let features = error.copy()
  features.append(
    Array::makei(3, i => 0.8 * velocity[i] + 0.2 * (error[i] - previous[i]) / dt),
  )
  (features, observer_memory(obs, features, nu~))
}

///|
pub fn quaternion_matrix(q : Array[Double]) -> Array[Array[Double]] {
  let q = unit(q)
  let w = q[0]
  let x = q[1]
  let y = q[2]
  let z = q[3]
  [
    [1.0 - 2.0 * (y * y + z * z), 2.0 * (x * y - w * z), 2.0 * (x * z + w * y)],
    [2.0 * (x * y + w * z), 1.0 - 2.0 * (x * x + z * z), 2.0 * (y * z - w * x)],
    [2.0 * (x * z - w * y), 2.0 * (y * z + w * x), 1.0 - 2.0 * (x * x + y * y)],
  ]
}

///|
pub(all) struct RewardResult {
  reward : Double
  fallen : Bool
  error : Array[Double]
} derive(Debug)

///|
/// FK inputs are local body origins/rotations evaluated for state[7:36].
/// This keeps the reward independent of MuJoCo while reusing the same FK output
/// for body tracking, COM, feet and the next observer, as in the Python version.
pub fn reference_reward(
  state : Array[Double],
  action : Array[Double],
  previous : Array[Double],
  desired_positions : Array[Array[Double]],
  desired_quaternion : Array[Double],
  desired_joints : Array[Double],
  local_positions : Array[Array[Double]],
  local_rotations : Array[Array[Array[Double]]],
  com_positions : Array[Array[Double]],
  mass_fraction : Array[Double],
  site_bodies : Array[Int32],
  site_positions : Array[Array[Double]],
  dt~ : Double = 0.02,
) -> RewardResult {
  guard state.length() >= 36 &&
    action.length() == previous.length() &&
    !action.is_empty() &&
    !local_positions.is_empty() &&
    !site_bodies.is_empty() else {
    abort("reward shape")
  }
  let rotation = quaternion_matrix(state[3:7].to_owned())
  let positions = local_positions.map(p => {
    matvec(rotation, p).mapi((i, x) => x + state[i])
  })
  let squared = positions.mapi((i, p) => {
    p.foldi(init=0.0, (j, sum, x) => {
      sum + (x - desired_positions[i][j]) * (x - desired_positions[i][j])
    })
  })
  let body_squared = squared.fold(init=0.0, (a, b) => a + b) /
    squared.length().to_double()
  let q = unit(state[3:7].to_owned())
  let r = unit(desired_quaternion)
  let cosine = dot(q, r)
  let orientation_squared = 4.0 * (1.0 - cosine * cosine).max(0.0)
  let joint_squared = desired_joints.foldi(init=0.0, (i, sum, x) => {
      sum + (state[7 + i] - x) * (state[7 + i] - x)
    }) /
    desired_joints.length().to_double()
  let action_squared = action.foldi(init=0.0, (i, sum, x) => {
      sum + (x - previous[i]) * (x - previous[i]) / 0.01
    }) /
    action.length().to_double()
  let reward = dt *
    (
      @math.exp(-body_squared / 0.0025) +
      0.5 * @math.exp(-squared[0] / 0.0025) +
      0.5 * @math.exp(-orientation_squared / 0.01) +
      @math.exp(-joint_squared / 0.0009) -
      0.01 * action_squared
    )
  let gravity = [-rotation[2][0], -rotation[2][1], -rotation[2][2]]
  let com = [0.0, 0.0, 0.0]
  for i, p in local_positions {
    let offset = matvec(local_rotations[i], com_positions[i])
    for j in 0..<3 {
      com[j] += (p[j] + offset[j]) * mass_fraction[i]
    }
  }
  let feet = [0.0, 0.0, 0.0]
  for i, body in site_bodies {
    let offset = matvec(local_rotations[body], site_positions[i])
    for j in 0..<3 {
      feet[j] += (local_positions[body][j] + offset[j]) /
        site_bodies.length().to_double()
    }
  }
  let difference = com.mapi((i, x) => x - feet[i])
  let vertical = dot(difference, gravity)
  {
    reward,
    fallen: state[2] < 0.35 || -gravity[2] < 0.5,
    error: difference.mapi((i, x) => x - gravity[i] * vertical),
  }
}

///|
pub(all) struct ReferenceCommand {
  current : Array[Double]
  future : Array[Array[Double]]
  valid : Array[Bool]
} derive(Debug)

///|
pub fn reference_command(
  goals : Array[Array[Double]],
  step : Int32,
  future_length : Int32,
) -> ReferenceCommand {
  guard goals.length() > 0 && step >= 0 && future_length >= 0 else {
    abort("reference command bounds")
  }
  let length = goals.length() - 1
  let step = step.min(length)
  {
    current: goals[step].copy(),
    future: Array::makei(future_length, i => {
      goals[(step + i + 1).min(length)].copy()
    }),
    valid: Array::makei(future_length, i => step + i + 1 <= length),
  }
}
