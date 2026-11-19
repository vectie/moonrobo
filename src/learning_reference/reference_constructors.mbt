///|
fn initialized_dense(
  nin : Int32,
  nout : Int32,
  activation : Activation,
  rng : @numeric.Rng,
  zero~ : Bool = false,
) -> Dense {
  let bound = 1.0 / nin.to_double().sqrt()
  {
    weight: Array::makei(nout, _ => {
      Array::makei(nin, _ => {
        if zero {
          0.0
        } else {
          (2.0 * rng.uniform() - 1.0) * bound
        }
      })
    }),
    bias: Array::makei(nout, _ => {
      if zero {
        0.0
      } else {
        (2.0 * rng.uniform() - 1.0) * bound
      }
    }),
    activation,
  }
}

///|
/// Portable RNG draws deliberately differ from Torch; imported weights retain
/// the exact architecture and ordering, while new training needs parity testing.
pub fn ReferenceActor::new(
  goal_dim : Int32,
  nu : Int32,
  lower : Array[Double],
  upper : Array[Double],
  coefficients : Array[Array[Double]],
  indices : Array[Int32],
  rng : @numeric.Rng,
  history_length~ : Int32 = 10,
  future_length~ : Int32 = 10,
  width~ : Int32 = 128,
  latent_dim~ : Int32 = 32,
  output_bound~ : Double = 0.6,
) -> ReferenceActor {
  guard goal_dim > 0 &&
    nu > 0 &&
    history_length > 0 &&
    future_length >= 0 &&
    width > 0 &&
    latent_dim > 0 &&
    output_bound > 0.0 else {
    abort("actor dimensions must be positive")
  }
  guard lower.length() == nu &&
    upper.length() == nu &&
    coefficients.length() == 4 &&
    indices.length() == 4 &&
    indices.all(i => i >= 0 && i < nu) else {
    abort("actor actuator layout")
  }
  let obs_dim = 3 * nu + 6
  {
    nu,
    history_length,
    future_length,
    output_bound,
    indices: indices.copy(),
    lower: lower.copy(),
    upper: upper.copy(),
    feedback_coefficients: coefficients.map(row => row.copy()),
    obs_mean: Array::make(obs_dim, 0.0),
    obs_scale: Array::make(obs_dim, 1.0),
    goal_mean: Array::make(goal_dim, 0.0),
    goal_scale: Array::make(goal_dim, 1.0),
    goal_encoder: [
      initialized_dense(
        (future_length + 1) * goal_dim + future_length,
        width,
        Silu,
        rng,
      ),
      initialized_dense(width, 64, Silu, rng),
      initialized_dense(64, latent_dim, Tanh, rng),
    ],
    observation_encoder: [
      initialized_dense(history_length * obs_dim, 64, Silu, rng),
      initialized_dense(64, 64, Silu, rng),
    ],
    decoder: [
      initialized_dense(latent_dim + 64, width, Silu, rng),
      initialized_dense(width, nu, Linear, rng, zero=true),
    ],
  }
}

///|
pub fn ReferenceValue::new(
  actor : ReferenceActor,
  state_mean : Array[Double],
  state_scale : Array[Double],
  clips : Int32,
  rng : @numeric.Rng,
) -> ReferenceValue {
  let n = 71 +
    actor.history_length * actor.obs_mean.length() +
    actor.goal_mean.length() +
    6 +
    2 +
    clips +
    2 +
    4
  {
    state_mean: state_mean.copy(),
    state_scale: state_scale.copy(),
    obs_mean: actor.obs_mean.copy(),
    obs_scale: actor.obs_scale.copy(),
    goal_mean: actor.goal_mean.copy(),
    goal_scale: actor.goal_scale.copy(),
    clips,
    net: [
      initialized_dense(n, 128, Silu, rng),
      initialized_dense(128, 64, Silu, rng),
      initialized_dense(64, 1, Linear, rng, zero=true),
    ],
  }
}

///|
pub fn ReferenceActor::fit_normalization(
  self : ReferenceActor,
  points : Array[TrainingPoint],
  floor : Double,
) -> Unit {
  let obs = @numeric.fit_normalization(
    points.map(point => point.history[point.history.length() - 1]),
    floor,
  )
  let goal = @numeric.fit_normalization(
    points.map(point => point.current),
    floor,
  )
  for i in 0..<self.obs_mean.length() {
    self.obs_mean[i] = obs.mean[i]
    self.obs_scale[i] = obs.scale[i]
  }
  for i in 0..<self.goal_mean.length() {
    self.goal_mean[i] = goal.mean[i]
    self.goal_scale[i] = goal.scale[i]
  }
}

///|
struct HingeSpec {
  observation_index : Int32
  axis : Array[Double]
  anchor : Array[Double]
  reference : Double
} derive(FromJson)

///|
struct BodySpec {
  parent : Int32
  position : Array[Double]
  quaternion_wxyz : Array[Double]
  com_position : Array[Double]
  mass : Double
  joints : Array[HingeSpec]
} derive(FromJson)

///|
struct FootSpec {
  body : Int32
  position : Array[Double]
} derive(FromJson)

///|
struct GeometrySpec {
  format : String
  joint_names : Array[String]
  bodies : Array[BodySpec]
  feet : Array[FootSpec]
} derive(FromJson)

///|
pub fn kinematics_from_spec(json : Json) -> @balance.Kinematics raise {
  let spec : GeometrySpec = @json.from_json(json)
  guard spec.format == "moonrobo.balance-kinematics.v1" &&
    !spec.bodies.is_empty() &&
    !spec.feet.is_empty() else {
    fail("invalid balance kinematics specification")
  }
  {
    nu: spec.joint_names.length(),
    bodies: spec.bodies.map(body => {
      (
        {
          parent: body.parent,
          position: body.position,
          quaternion_wxyz: body.quaternion_wxyz,
          com_position: body.com_position,
          mass: body.mass,
          joints: body.joints.map(joint => {
            (
              {
                observation_index: joint.observation_index,
                axis: joint.axis,
                anchor: joint.anchor,
                reference: joint.reference,
              } : @balance.Hinge)
          }),
        } : @balance.Body)
    }),
    feet: spec.feet.map(site => {
      ({ body: site.body, position: site.position, } : @balance.Foot)
    }),
  }
}
