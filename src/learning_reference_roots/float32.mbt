///|
/// Operator-rounded Float32 reconstruction for legacy archives. These gates are not relaxed if reduction/transcendental differences prevent Torch parity.
fn r(x : Double) -> Double {
  x.to_float().to_double()
}

///|
fn add(a : Double, b : Double) -> Double {
  (a.to_float() + b.to_float()).to_double()
}

///|
fn sub(a : Double, b : Double) -> Double {
  (a.to_float() - b.to_float()).to_double()
}

///|
fn mul(a : Double, b : Double) -> Double {
  (a.to_float() * b.to_float()).to_double()
}

///|
fn div(a : Double, b : Double) -> Double {
  (a.to_float() / b.to_float()).to_double()
}

///|
fn fdot(a : Array[Double], b : Array[Double]) -> Double {
  let mut sum = 0.0
  for i, x in a {
    sum = add(sum, mul(x, b[i]))
  }
  sum
}

///|
fn norm(a : Array[Double]) -> Array[Double] {
  let scale = r(fdot(a, a).sqrt()).max(r(1.0e-12))
  a.map(fn(x) { div(x, scale) })
}

///|
fn dense32(layers : Array[@ref.Dense], input : Array[Double]) -> Array[Double] {
  let mut x = input
  for layer in layers {
    x = layer.weight.mapi(fn(i, row) {
      let mut total = 0.0
      for j, w in row {
        total = add(total, mul(w, x[j]))
      }
      total = add(total, layer.bias[i])
      match layer.activation {
        Linear => total
        Silu => mul(total, div(1.0, add(1.0, r(@math.exp(-total)))))
        Tanh => r(@math.tanh(total))
      }
    })
  }
  x
}

///|
fn normalize32(
  row : Array[Double],
  mean : Array[Double],
  scale : Array[Double],
) -> Array[Double] {
  Array::makei(row.length(), fn(i) { div(sub(row[i], mean[i]), scale[i]) })
}

///|
fn latent32(
  actor : @ref.ReferenceActor,
  history : Array[Array[Double]],
  command : @ref.ReferenceCommand,
) -> Array[Double] {
  let planned = normalize32(command.current, actor.goal_mean, actor.goal_scale)
  for goal in command.future {
    planned.append(normalize32(goal, actor.goal_mean, actor.goal_scale))
  }
  for valid in command.valid {
    planned.push(if valid { 1.0 } else { 0.0 })
  }
  let observed : Array[Double] = []
  for obs in history {
    observed.append(normalize32(obs, actor.obs_mean, actor.obs_scale))
  }
  let input = dense32(actor.goal_encoder, planned)
  input.append(dense32(actor.observation_encoder, observed))
  dense32(actor.decoder, input)
}

///|
fn feedback_inputs32(
  actor : @ref.ReferenceActor,
  obs : Array[Double],
  features : Array[Double],
) -> Array[Array[Double]] {
  let gx = r(obs[2 * actor.nu])
  let gy = r(obs[2 * actor.nu + 1])
  let gz = r(obs[2 * actor.nu + 2])
  let pitch = r(@math.atan2(gx, r(add(mul(gy, gy), mul(gz, gz)).sqrt())))
  let roll = r(@math.atan2(-gy, -gz))
  Array::makei(4, fn(i) {
    let axis = i % 2
    [
      r(features[axis]),
      r(features[3 + axis]),
      r(obs[actor.nu + actor.indices[i]]),
      if axis == 0 {
        pitch
      } else {
        roll
      },
      r(obs[2 * actor.nu + 3 + (if axis == 0 { 1 } else { 0 })]),
    ]
  })
}

///|
fn action32(
  actor : @ref.ReferenceActor,
  latent : Array[Double],
  history : Array[Array[Double]],
  current : Array[Double],
  features : Array[Double],
  planned : Array[Double],
) -> Array[Double] {
  let a = feedback_inputs32(actor, history[history.length() - 1], features)
  let b = feedback_inputs32(
    actor,
    @ref.reference_observation(current, nu=actor.nu),
    planned,
  )
  let residual = latent.map(fn(v) { mul(actor.output_bound, r(@math.tanh(v))) })
  for i, joint in actor.indices {
    let mut feedback = 0.0
    for k in 0..<5 {
      feedback = add(
        feedback,
        mul(sub(a[i][k], b[i][k]), actor.feedback_coefficients[i][k]),
      )
    }
    residual[joint] = add(
      residual[joint],
      @balance.clip(feedback, r(-0.45), r(0.45)),
    )
  }
  Array::makei(actor.nu, fn(i) {
    @balance.clip(
      add(
        current[i],
        @balance.clip(
          residual[i],
          r(-actor.output_bound),
          r(actor.output_bound),
        ),
      ),
      r(actor.lower[i]),
      r(actor.upper[i]),
    )
  })
}

///|
fn reward32(
  geometry : @balance.Kinematics,
  state : Array[Double],
  action : Array[Double],
  previous : Array[Double],
  desired_positions : Array[Array[Double]],
  desired_q : Array[Double],
  desired_joints : Array[Double],
  dt : Double,
) -> (Double, Bool) {
  let (local, _) = @float32.body_poses(geometry, state[7:36].to_owned())
  let q = norm(state[3:7].to_owned())
  let desired = norm(desired_q)
  let w = q[0]
  let x = q[1]
  let y = q[2]
  let z = q[3]
  let rotation = [
    sub(1.0, mul(2.0, add(mul(y, y), mul(z, z)))),
    mul(2.0, sub(mul(x, y), mul(z, w))),
    mul(2.0, add(mul(x, z), mul(y, w))),
    mul(2.0, add(mul(x, y), mul(z, w))),
    sub(1.0, mul(2.0, add(mul(x, x), mul(z, z)))),
    mul(2.0, sub(mul(y, z), mul(x, w))),
    mul(2.0, sub(mul(x, z), mul(y, w))),
    mul(2.0, add(mul(y, z), mul(x, w))),
    sub(1.0, mul(2.0, add(mul(x, x), mul(y, y)))),
  ]
  let mut body_squared = 0.0
  let mut root_squared = 0.0
  for i, p in local {
    let mut squared = 0.0
    for j in 0..<3 {
      let world = add(state[j], fdot(rotation[j * 3:j * 3 + 3].to_owned(), p))
      let d = sub(world, desired_positions[i][j])
      squared = add(squared, mul(d, d))
    }
    body_squared = add(body_squared, squared)
    if i == 0 {
      root_squared = squared
    }
  }
  body_squared = div(body_squared, local.length().to_double())
  let cosine = fdot(q, desired)
  let orientation_squared = mul(4.0, sub(1.0, mul(cosine, cosine)).max(0.0))
  let mut joint_squared = 0.0
  let mut action_squared = 0.0
  for i in 0..<action.length() {
    let d = sub(state[7 + i], desired_joints[i])
    joint_squared = add(joint_squared, mul(d, d))
    let a = div(sub(action[i], previous[i]), 0.1)
    action_squared = add(action_squared, mul(a, a))
  }
  joint_squared = div(joint_squared, action.length().to_double())
  action_squared = div(action_squared, action.length().to_double())
  let reward = mul(
    dt,
    sub(
      add(
        add(
          add(
            r(@math.exp(div(-body_squared, 0.0025))),
            mul(0.5, r(@math.exp(div(-root_squared, 0.0025)))),
          ),
          mul(0.5, r(@math.exp(div(-orientation_squared, 0.01)))),
        ),
        r(@math.exp(div(-joint_squared, 0.0009))),
      ),
      mul(0.01, action_squared),
    ),
  )
  (reward, state[2] < 0.35 || rotation[8] < 0.5)
}
