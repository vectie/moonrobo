///|
fn validate_dense(
  layer : Dense,
  nin : Int32,
  nout : Int32,
  activation : Activation,
) -> Unit raise {
  guard layer.weight.length() == nout &&
    layer.bias.length() == nout &&
    layer.activation == activation else {
    fail("reference network layer layout differs")
  }
  guard layer.bias.all(value => finite(value)) else {
    fail("nonfinite reference network bias")
  }
  for row in layer.weight {
    guard row.length() == nin && row.all(value => finite(value)) else {
      fail("reference network weight shape or finiteness differs")
    }
  }
}

///|
pub fn ReferenceActor::validate(self : ReferenceActor) -> Unit raise {
  let goal_dim = self.goal_mean.length()
  guard self.nu > 0 &&
    self.history_length > 0 &&
    self.future_length >= 0 &&
    self.output_bound > 0.0 &&
    finite(self.output_bound) else {
    fail("invalid reference actor architecture")
  }
  guard self.obs_mean.length() == 3 * self.nu + 6 &&
    self.obs_scale.length() == self.obs_mean.length() &&
    self.goal_scale.length() == goal_dim &&
    goal_dim >= 2 * self.nu + 10 else {
    fail("reference actor normalization layout differs")
  }
  guard self.obs_scale.all(value => finite(value) && value > 0.0) &&
    self.goal_scale.all(value => finite(value) && value > 0.0) &&
    self.obs_mean.all(value => finite(value)) &&
    self.goal_mean.all(value => finite(value)) else {
    fail("invalid reference normalization")
  }
  guard self.lower.length() == self.nu &&
    self.upper.length() == self.nu &&
    self.indices.length() == 4 &&
    self.feedback_coefficients.length() == 4 else {
    fail("reference actor actuator layout differs")
  }
  for i in 0..<self.nu {
    guard finite(self.lower[i]) &&
      finite(self.upper[i]) &&
      self.lower[i] <= self.upper[i] else {
      fail("invalid actuator bounds")
    }
  }
  for i, index in self.indices {
    guard index >= 0 && index < self.nu && !self.indices[:i].contains(index) else {
      fail("invalid or duplicate feedback joint index")
    }
    guard self.feedback_coefficients[i].length() == 5 &&
      self.feedback_coefficients[i].all(value => finite(value)) else {
      fail("invalid feedback coefficient layout")
    }
  }
  guard self.goal_encoder.length() == 3 &&
    self.observation_encoder.length() == 2 &&
    self.decoder.length() == 2 else {
    fail("reference encoder/decoder topology differs")
  }
  let width = self.goal_encoder[0].bias.length()
  let latent_dim = self.goal_encoder[2].bias.length()
  guard width > 0 && latent_dim > 0 else {
    fail("empty actor hidden dimensions")
  }
  validate_dense(
    self.goal_encoder[0],
    (self.future_length + 1) * goal_dim + self.future_length,
    width,
    Silu,
  )
  validate_dense(self.goal_encoder[1], width, 64, Silu)
  validate_dense(self.goal_encoder[2], 64, latent_dim, Tanh)
  validate_dense(
    self.observation_encoder[0],
    self.history_length * self.obs_mean.length(),
    64,
    Silu,
  )
  validate_dense(self.observation_encoder[1], 64, 64, Silu)
  validate_dense(self.decoder[0], latent_dim + 64, width, Silu)
  validate_dense(self.decoder[1], width, self.nu, Linear)
}

///|
pub fn ReferenceActor::fixed_buffers(self : ReferenceActor) -> Json {
  {
    "obs_mean": self.obs_mean,
    "obs_scale": self.obs_scale,
    "goal_mean": self.goal_mean,
    "goal_scale": self.goal_scale,
    "lower": self.lower,
    "upper": self.upper,
    "feedback_coefficients": self.feedback_coefficients,
  }
}
