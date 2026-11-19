///|
/// Exact ordering: goal encoder, observation encoder, decoder; each Linear's
/// row-major weights followed by bias, matching named_parameters in Python.
pub fn ReferenceActor::parameters(self : ReferenceActor) -> Array[Double] {
  let result : Array[Double] = []
  for layers in [self.goal_encoder, self.observation_encoder, self.decoder] {
    for layer in layers {
      for row in layer.weight {
        result.append(row)
      }
      result.append(layer.bias)
    }
  }
  result
}

///|
pub fn ReferenceActor::set_parameters(
  self : ReferenceActor,
  parameters : Array[Double],
) -> Unit {
  let mut offset = 0
  for layers in [self.goal_encoder, self.observation_encoder, self.decoder] {
    for layer in layers {
      for row in layer.weight {
        for j in 0..<row.length() {
          row[j] = parameters[offset]
          offset += 1
        }
      }
      for j in 0..<layer.bias.length() {
        layer.bias[j] = parameters[offset]
        offset += 1
      }
    }
  }
  guard offset == parameters.length() else { abort("actor parameter count") }
}

///|
fn dense_graph(
  layers : Array[Dense],
  tape : @numeric.Tape,
  parameters : Array[@numeric.Value],
  start : Int32,
  inputs : Array[@numeric.Value],
) -> (Array[@numeric.Value], Int32) {
  let mut offset = start
  let mut values = inputs
  for layer in layers {
    let nin = values.length()
    let nout = layer.bias.length()
    let next = Array::makei(nout, i => {
      guard layer.weight[i].length() == nin else { abort("graph dense shape") }
      let mut sum = parameters[offset + nin * nout + i]
      for j in 0..<nin {
        sum = tape.add(
          sum,
          tape.mul(parameters[offset + i * nin + j], values[j]),
        )
      }
      match layer.activation {
        Linear => sum
        Silu => tape.silu(sum)
        Tanh => tape.tanh(sum)
      }
    })
    offset += nin * nout + nout
    values = next
  }
  (values, offset)
}

///|
fn normalize_graph(
  tape : @numeric.Tape,
  input : Array[@numeric.Value],
  mean : Array[Double],
  scale : Array[Double],
) -> Array[@numeric.Value] {
  input.mapi((i, x) => {
    tape.scale(tape.sub(x, tape.scalar(mean[i])), 1.0 / scale[i])
  })
}

///|
pub fn ReferenceActor::latent_graph(
  self : ReferenceActor,
  tape : @numeric.Tape,
  parameters : Array[@numeric.Value],
  history : Array[Array[@numeric.Value]],
  current : Array[@numeric.Value],
  future : Array[Array[@numeric.Value]],
  valid : Array[Bool],
) -> Array[@numeric.Value] {
  let planned = normalize_graph(tape, current, self.goal_mean, self.goal_scale)
  for frame in future {
    planned.append(
      normalize_graph(tape, frame, self.goal_mean, self.goal_scale),
    )
  }
  for mask in valid {
    planned.push(tape.scalar(if mask { 1.0 } else { 0.0 }))
  }
  let observed : Array[@numeric.Value] = []
  for frame in history {
    observed.append(normalize_graph(tape, frame, self.obs_mean, self.obs_scale))
  }
  let (latent, offset) = dense_graph(
    self.goal_encoder,
    tape,
    parameters,
    0,
    planned,
  )
  let (encoded_observation, offset) = dense_graph(
    self.observation_encoder,
    tape,
    parameters,
    offset,
    observed,
  )
  latent.append(encoded_observation)
  dense_graph(self.decoder, tape, parameters, offset, latent).0
}

///|
/// The feedback input graph preserves the policy-input gradient edge.
fn feedback_graph(
  tape : @numeric.Tape,
  obs : Array[@numeric.Value],
  features : Array[@numeric.Value],
  indices : Array[Int32],
  nu : Int32,
) -> Array[Array[@numeric.Value]] {
  let gx = obs[2 * nu]
  let gy = obs[2 * nu + 1]
  let gz = obs[2 * nu + 2]
  let pitch = tape.atan2(
    gx,
    tape.sqrt(tape.add(tape.mul(gy, gy), tape.mul(gz, gz))),
  )
  let roll = tape.atan2(tape.scale(gy, -1.0), tape.scale(gz, -1.0))
  indices.mapi((i, joint) => {
    let axis = i % 2
    let omega = if axis == 0 { 4 } else { 3 }
    [
      features[axis],
      features[axis + 3],
      obs[nu + joint],
      if axis == 0 {
        pitch
      } else {
        roll
      },
      obs[2 * nu + omega],
    ]
  })
}

///|
pub fn ReferenceActor::action_graph(
  self : ReferenceActor,
  tape : @numeric.Tape,
  latent : Array[@numeric.Value],
  history : Array[Array[@numeric.Value]],
  current : Array[@numeric.Value],
  actual_features : Array[@numeric.Value],
  reference_features : Array[@numeric.Value],
) -> Array[@numeric.Value] {
  let desired_obs = current[:2 * self.nu + 3].to_owned()
  desired_obs.append(current[2 * self.nu + 7:2 * self.nu + 10].to_owned())
  desired_obs.append(Array::makei(self.nu, _ => tape.scalar(0.0)))
  let actual = feedback_graph(
    tape,
    history[history.length() - 1],
    actual_features,
    self.indices,
    self.nu,
  )
  let desired = feedback_graph(
    tape,
    desired_obs,
    reference_features,
    self.indices,
    self.nu,
  )
  let residual = latent.map(x => tape.scale(tape.tanh(x), self.output_bound))
  for i, joint in self.indices {
    let mut feedback = tape.scalar(0.0)
    for j in 0..<5 {
      feedback = tape.add(
        feedback,
        tape.scale(
          tape.sub(actual[i][j], desired[i][j]),
          self.feedback_coefficients[i][j],
        ),
      )
    }
    residual[joint] = tape.add(
      residual[joint],
      tape.clamp(feedback, -0.45, 0.45),
    )
  }
  residual.mapi((i, x) => {
    tape.clamp(
      tape.add(current[i], tape.clamp(x, -self.output_bound, self.output_bound)),
      self.lower[i],
      self.upper[i],
    )
  })
}

///|
pub fn supervised_actor_step(
  actor : ReferenceActor,
  optimizer : @numeric.Adam,
  points : Array[TrainingPoint],
  reference_only~ : Bool = false,
) -> Double {
  guard !points.is_empty() else { abort("empty supervised minibatch") }
  let tape = @numeric.Tape::new()
  let values = actor.parameters()
  let parameters = tape.vector(values)
  let graph_parameters = parameters.copy()
  if reference_only {
    let mut offset = 0
    for layers in [actor.goal_encoder, actor.observation_encoder] {
      for layer in layers {
        offset += layer.weight.fold(init=layer.bias.length(), (n, row) => {
          n + row.length()
        })
      }
    }
    let latent_dim = actor.goal_encoder[actor.goal_encoder.length() - 1].bias.length()
    for i, row in actor.decoder[0].weight {
      for j in latent_dim..<row.length() {
        let index = offset + i * row.length() + j
        graph_parameters[index] = tape.scalar(values[index])
      }
    }
  }
  let losses : Array[@numeric.Value] = []
  for point in points {
    let history = point.history.map(row => tape.vector(row))
    let current = tape.vector(point.current)
    let latent = actor.latent_graph(
      tape,
      graph_parameters,
      history,
      current,
      point.future.map(row => tape.vector(row)),
      point.valid,
    )
    let zero = tape.vector(Array::make(6, 0.0))
    let action = actor.action_graph(tape, latent, history, current, zero, zero)
    for i, value in action {
      let error = tape.sub(value, tape.scalar(point.target[i]))
      losses.push(tape.mul(error, error))
    }
  }
  let loss = tape.mean(losses)
  guard finite(loss.value) else { abort("nonfinite supervised actor loss") }
  tape.backward(loss)
  ignore(optimizer.step(values, tape, parameters))
  actor.set_parameters(values)
  loss.value
}

///|
pub(all) struct PpoPoint {
  history : Array[Array[Double]]
  current : Array[Double]
  future : Array[Array[Double]]
  valid : Array[Bool]
  latent : Array[Double]
  old_mean : Array[Double]
  advantage : Double
  visitation_weight : Double
}

///|
/// One PPO minibatch. visitation_weight is normalized over the full collection,
/// preserving Python's weighting rather than renormalizing each minibatch.
pub fn ppo_actor_step(
  actor : ReferenceActor,
  optimizer : @numeric.Adam,
  points : Array[PpoPoint],
  std : Double,
  clip : Double,
) -> Double {
  guard !points.is_empty() && std > 0.0 else { abort("PPO minibatch shape") }
  let tape = @numeric.Tape::new()
  let values = actor.parameters()
  let parameters = tape.vector(values)
  let losses : Array[@numeric.Value] = []
  for point in points {
    let mean = actor.latent_graph(
      tape,
      parameters,
      point.history.map(row => tape.vector(row)),
      tape.vector(point.current),
      point.future.map(row => tape.vector(row)),
      point.valid,
    )
    let mut log_ratio = tape.scalar(0.0)
    for i, value in mean {
      let delta = tape.sub(tape.scalar(point.latent[i]), value)
      let old = point.latent[i] - point.old_mean[i]
      log_ratio = tape.add(
        log_ratio,
        tape.scale(
          tape.sub(tape.scalar(old * old), tape.mul(delta, delta)),
          0.5 / (std * std),
        ),
      )
    }
    let ratio = tape.exp(log_ratio)
    let clipped = tape.clamp(ratio, 1.0 - clip, 1.0 + clip)
    losses.push(
      tape.scale(
        tape.minimum(
          tape.scale(ratio, point.advantage),
          tape.scale(clipped, point.advantage),
        ),
        -point.visitation_weight,
      ),
    )
  }
  let loss = tape.mean(losses)
  guard finite(loss.value) else { abort("nonfinite reference PPO loss") }
  tape.backward(loss)
  ignore(optimizer.step(values, tape, parameters))
  actor.set_parameters(values)
  loss.value
}
