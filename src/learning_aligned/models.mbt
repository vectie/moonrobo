///|
pub(all) enum Activation {
  Elu
  Silu
} derive(Debug)

///|
pub(all) struct Network {
  dimensions : Array[Int32]
  parameters : Array[Double]
  activation : Activation
  layer_norm : Bool
} derive(Debug)

///|
pub fn Network::new(
  dimensions : Array[Int32],
  rng : @numeric.Rng,
  activation~ : Activation = Elu,
  layer_norm~ : Bool = false,
  zero_last~ : Bool = false,
  final_scale~ : Double = 1.0,
) -> Network {
  let parameters : Array[Double] = []
  for i in 0..<(dimensions.length() - 1) {
    let nin = dimensions[i]
    let nout = dimensions[i + 1]
    let last = i == dimensions.length() - 2
    let bound = 1.0 / nin.to_double().sqrt()
    for _ in 0..<(nin * nout) {
      parameters.push(
        if last && zero_last {
          0.0
        } else {
          (rng.uniform() * 2.0 - 1.0) *
          bound *
          (if last { final_scale } else { 1.0 })
        },
      )
    }
    for _ in 0..<nout {
      parameters.push(
        if last && (zero_last || final_scale != 1.0) {
          0.0
        } else {
          (rng.uniform() * 2.0 - 1.0) * bound
        },
      )
    }
    if layer_norm && !last {
      for _ in 0..<nout {
        parameters.push(1.0)
      }
      for _ in 0..<nout {
        parameters.push(0.0)
      }
    }
  }
  { dimensions: dimensions.copy(), parameters, activation, layer_norm, }
}

///|
pub fn Network::bind(
  self : Network,
  tape : @numeric.Tape,
) -> Array[@numeric.Value] {
  tape.vector(self.parameters)
}

///|
pub fn Network::forward(
  self : Network,
  tape : @numeric.Tape,
  params : Array[@numeric.Value],
  input : Array[@numeric.Value],
) -> Array[@numeric.Value] {
  let mut x = input
  let mut offset = 0
  for layer in 0..<(self.dimensions.length() - 1) {
    let nin = self.dimensions[layer]
    let nout = self.dimensions[layer + 1]
    let last = layer == self.dimensions.length() - 2
    let mut y = Array::makei(nout, row => {
      let mut sum = params[offset + nin * nout + row]
      for col in 0..<nin {
        sum = tape.add(sum, tape.mul(params[offset + row * nin + col], x[col]))
      }
      sum
    })
    offset += nin * nout + nout
    if self.layer_norm && !last {
      let mean = tape.mean(y)
      let centered = y.map(v => tape.sub(v, mean))
      let variance = tape.mean(centered.map(v => tape.mul(v, v)))
      let std = tape.sqrt(tape.add(variance, tape.scalar(0.00001)))
      y = Array::makei(nout, i => {
        tape.add(
          tape.mul(tape.div(centered[i], std), params[offset + i]),
          params[offset + nout + i],
        )
      })
      offset += nout * 2
    }
    if !last {
      y = y.map(v => {
        match self.activation {
          Silu => tape.silu(v)
          Elu =>
            if v.value >= 0.0 {
              v
            } else {
              tape.sub(tape.exp(v), tape.scalar(1.0))
            }
        }
      })
    }
    x = y
  }
  x
}

///|
pub fn Network::predict(self : Network, input : Array[Double]) -> Array[Double] {
  let tape = @numeric.Tape::new()
  self.forward(tape, self.bind(tape), tape.vector(input)).map(v => v.value)
}

///|
pub fn RunningNorm::apply_ad(
  self : RunningNorm,
  tape : @numeric.Tape,
  row : Array[@numeric.Value],
) -> Array[@numeric.Value] {
  Array::makei(row.length(), i => {
    tape.scale(
      tape.sub(row[i], tape.scalar(self.mean[i])),
      1.0 / (self.variance[i] + self.eps * self.eps).sqrt(),
    )
  })
}

///|
pub struct Policy {
  encoder : Network
  decoder : Network
  obs_norm : RunningNorm
  goal_norm : RunningNorm
  hist : Int32
}

///|
pub fn Policy::new(
  obs_dim : Int32,
  goal_dim : Int32,
  rng : @numeric.Rng,
  hist~ : Int32 = 10,
  z_dim~ : Int32 = 32,
  hidden~ : Array[Int32] = [2048, 1024, 512, 256],
) -> Policy {
  let enc_dims = [goal_dim]
  enc_dims.append(hidden)
  enc_dims.push(z_dim)
  let dec_dims = [z_dim + obs_dim * hist]
  dec_dims.append(hidden)
  dec_dims.push(29)
  {
    encoder: Network::new(enc_dims, rng),
    decoder: Network::new(dec_dims, rng, final_scale=0.01),
    obs_norm: RunningNorm::new(obs_dim),
    goal_norm: RunningNorm::new(goal_dim),
    hist,
  }
}

///|
pub fn Policy::forward(
  self : Policy,
  history : Array[Array[Double]],
  goal : Array[Double],
) -> Array[Double] {
  let latent = self.encoder
    .predict(self.goal_norm.apply(goal))
    .map(x => @math.tanh(x))
  for row in history {
    latent.append(self.obs_norm.apply(row))
  }
  self.decoder.predict(latent)
}

///|
pub fn Policy::update_normalizers(
  self : Policy,
  observations : Array[Array[Double]],
  goals : Array[Array[Double]],
) -> Unit {
  self.obs_norm.update(observations)
  self.goal_norm.update(goals)
}

///|
pub struct WorldModel {
  net : Network
  input_norm : RunningNorm
  output_norm : RunningNorm
}

///|
pub fn WorldModel::new(
  rng : @numeric.Rng,
  hidden~ : Array[Int32] = [2048, 2048, 2048],
) -> WorldModel {
  let dims = [133]
  dims.append(hidden)
  dims.push(70)
  {
    net: Network::new(
      dims,
      rng,
      activation=Silu,
      layer_norm=true,
      zero_last=true,
    ),
    input_norm: RunningNorm::new(133),
    output_norm: RunningNorm::new(70, eps=0.0001),
  }
}

///|
pub fn WorldModel::step(
  self : WorldModel,
  state : State,
  action : Array[Double],
  xi_n : Array[Double],
) -> State {
  let out = self.net.predict(
    self.input_norm.apply(world_inputs(state, action, xi_n)),
  )
  let std = self.output_norm.std()
  world_integrate(
    state,
    Array::makei(70, i => out[i] * std[i] + self.output_norm.mean[i]),
  )
}

///|
pub fn WorldModel::observe(self : WorldModel, transition : Transition) -> Unit {
  self.observe_batch([transition])
}

///|
pub fn WorldModel::observe_batch(
  self : WorldModel,
  transitions : Array[Transition],
) -> Unit {
  let inputs : Array[Array[Double]] = []
  let targets : Array[Array[Double]] = []
  for transition in transitions {
    let state = unflatten_state(transition.s)
    inputs.push(world_inputs(state, transition.a, normalize_xi(transition.xi)))
    targets.push(world_targets(state, unflatten_state(transition.s1)))
  }
  self.input_norm.update(inputs)
  self.output_norm.update(targets)
}

///|
pub struct Critic {
  net : Network
  norm : RunningNorm
}

///|
pub fn Critic::new(
  input_dim : Int32,
  rng : @numeric.Rng,
  hidden~ : Array[Int32] = [256, 128],
) -> Critic {
  let dims = [input_dim]
  dims.append(hidden)
  dims.push(1)
  { net: Network::new(dims, rng), norm: RunningNorm::new(input_dim), }
}

///|
pub fn Critic::predict(self : Critic, input : Array[Double]) -> Double {
  self.net.predict(self.norm.apply(input))[0]
}
