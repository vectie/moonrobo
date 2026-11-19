///|
pub(all) enum Activation {
  Linear
  Silu
  Tanh
} derive(Debug, Eq, ToJson, FromJson)

///|
/// PyTorch Linear weight order is [output][input].
pub(all) struct Dense {
  weight : Array[Array[Double]]
  bias : Array[Double]
  activation : Activation
} derive(Debug, ToJson, FromJson)

///|
pub fn Dense::forward(self : Dense, input : Array[Double]) -> Array[Double] {
  guard self.weight.length() == self.bias.length() else {
    abort("dense output shape")
  }
  self.weight.mapi((i, row) => {
    guard row.length() == input.length() else { abort("dense input shape") }
    let value = row.foldi(init=self.bias[i], (j, sum, w) => sum + w * input[j])
    match self.activation {
      Linear => value
      Silu => value / (1.0 + @math.exp(-value))
      Tanh => @math.tanh(value)
    }
  })
}

///|
fn network(layers : Array[Dense], input : Array[Double]) -> Array[Double] {
  layers.fold(init=input, (x, layer) => layer.forward(x))
}

///|
fn clamp(x : Double, lower : Double, upper : Double) -> Double {
  x.max(lower).min(upper)
}

///|
fn normalize(
  input : Array[Double],
  mean : Array[Double],
  scale : Array[Double],
) -> Array[Double] {
  guard input.length() == mean.length() && mean.length() == scale.length() else {
    abort("normalization shape")
  }
  input.mapi((i, x) => (x - mean[i]) / scale[i])
}

///|
pub fn reference_observation(
  current : Array[Double],
  nu~ : Int32 = 29,
) -> Array[Double] {
  guard nu > 0 && current.length() >= 2 * nu + 10 else {
    abort("reference goal shape")
  }
  let out = current[:2 * nu + 3].to_owned()
  out.append(current[2 * nu + 7:2 * nu + 10].to_owned())
  out.append(Array::make(nu, 0.0))
  out
}

///|
pub fn feedback_inputs(
  obs : Array[Double],
  features : Array[Double],
  indices : Array[Int32],
  nu : Int32,
) -> Array[Array[Double]] {
  guard indices.length() == 4 &&
    obs.length() == 3 * nu + 6 &&
    features.length() == 6 else {
    abort("feedback shape")
  }
  let gx = obs[2 * nu]
  let gy = obs[2 * nu + 1]
  let gz = obs[2 * nu + 2]
  let pitch = @math.atan2(gx, (gy * gy + gz * gz).sqrt())
  let roll = @math.atan2(-gy, -gz)
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
/// One sample; batched callers map forward over samples.
pub(all) struct ReferenceActor {
  nu : Int32
  history_length : Int32
  future_length : Int32
  output_bound : Double
  indices : Array[Int32]
  obs_mean : Array[Double]
  obs_scale : Array[Double]
  goal_mean : Array[Double]
  goal_scale : Array[Double]
  lower : Array[Double]
  upper : Array[Double]
  feedback_coefficients : Array[Array[Double]]
  goal_encoder : Array[Dense]
  observation_encoder : Array[Dense]
  decoder : Array[Dense]
} derive(Debug, ToJson, FromJson)

///|
pub fn ReferenceActor::latent_mean(
  self : ReferenceActor,
  history : Array[Array[Double]],
  current : Array[Double],
  future : Array[Array[Double]],
  valid : Array[Bool],
) -> Array[Double] {
  guard history.length() == self.history_length &&
    future.length() == self.future_length &&
    valid.length() == self.future_length else {
    abort("actor temporal shape")
  }
  let planned = normalize(current, self.goal_mean, self.goal_scale)
  for goal in future {
    planned.append(normalize(goal, self.goal_mean, self.goal_scale))
  }
  for mask in valid {
    planned.push(if mask { 1.0 } else { 0.0 })
  }
  let observed : Array[Double] = []
  for obs in history {
    observed.append(normalize(obs, self.obs_mean, self.obs_scale))
  }
  let latent = network(self.goal_encoder, planned)
  latent.append(network(self.observation_encoder, observed))
  network(self.decoder, latent)
}

///|
pub fn ReferenceActor::action_from_latent(
  self : ReferenceActor,
  latent : Array[Double],
  history : Array[Array[Double]],
  current : Array[Double],
  actual_features : Array[Double],
  reference_features : Array[Double],
) -> Array[Double] {
  guard latent.length() == self.nu &&
    history.length() > 0 &&
    self.indices.length() == 4 else {
    abort("actor action shape")
  }
  let actual = feedback_inputs(
    history[history.length() - 1],
    actual_features,
    self.indices,
    self.nu,
  )
  let desired = feedback_inputs(
    reference_observation(current, nu=self.nu),
    reference_features,
    self.indices,
    self.nu,
  )
  let residual = latent.map(x => self.output_bound * @math.tanh(x))
  for i, joint in self.indices {
    let feedback = actual[i].foldi(init=0.0, (j, sum, x) => {
      sum + (x - desired[i][j]) * self.feedback_coefficients[i][j]
    })
    residual[joint] += clamp(feedback, -0.45, 0.45)
  }
  residual.mapi((i, x) => {
    clamp(
      current[i] + clamp(x, -self.output_bound, self.output_bound),
      self.lower[i],
      self.upper[i],
    )
  })
}

///|
pub fn ReferenceActor::forward(
  self : ReferenceActor,
  history : Array[Array[Double]],
  current : Array[Double],
  future : Array[Array[Double]],
  valid : Array[Bool],
  actual_features : Array[Double],
  reference_features : Array[Double],
) -> Array[Double] {
  self.action_from_latent(
    self.latent_mean(history, current, future, valid),
    history,
    current,
    actual_features,
    reference_features,
  )
}

///|
pub struct ReferenceHistory {
  frames : Array[Array[Double]]
  length : Int32
}

///|
pub fn ReferenceHistory::new(length : Int32) -> ReferenceHistory {
  guard length > 0 else { abort("positive history length required") }
  { frames: [], length, }
}

///|
pub fn ReferenceHistory::push(
  self : ReferenceHistory,
  obs : Array[Double],
) -> Array[Array[Double]] {
  if self.frames.is_empty() {
    for _ in 0..<self.length {
      self.frames.push(obs.copy())
    }
  } else {
    ignore(self.frames.remove(0))
    self.frames.push(obs.copy())
  }
  self.frames.map(x => x.copy())
}
