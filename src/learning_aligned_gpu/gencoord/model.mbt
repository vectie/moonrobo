///|
/// Running moments and epsilon placement of RSL-RL EmpiricalNormalization.
pub struct EmpiricalNorm {
  mut mean : @tensor.Tensor
  mut variance : @tensor.Tensor
  mut count : Int64
}

///|
pub fn EmpiricalNorm::new(
  b : @tensor.Backend,
  dim : Int32,
  device : Int32,
) -> EmpiricalNorm raise {
  {
    mean: b.from_values(
      [dim],
      Array::make(dim, 0.0),
      cuda_device=device,
      requires_grad=false,
      dtype=Float32,
    ),
    variance: b.from_values(
      [dim],
      Array::make(dim, 1.0),
      cuda_device=device,
      requires_grad=false,
      dtype=Float32,
    ),
    count: 0L,
  }
}

///|
pub fn EmpiricalNorm::update(
  self : EmpiricalNorm,
  batch : @tensor.Tensor,
) -> Unit raise {
  guard batch.shape() is [n, d] && n > 0 && self.mean.shape() == [d] else {
    fail("invalid normalization batch")
  }
  let x = batch.stop_gradient()
  let mean = x.mean_dim(0)
  let var_x = x.population_variance_dim(0)
  let total = self.count + n.to_int64()
  let rate = n.to_double() / total.to_double()
  let delta = mean.sub(self.mean)
  let next = self.mean.add(delta.affine(rate))
  self.variance = self.variance.add(
    var_x.sub(self.variance).add(delta.mul(mean.sub(next))).affine(rate),
  )
  self.mean = next
  self.count = total
}

///|
pub fn EmpiricalNorm::apply(
  self : EmpiricalNorm,
  values : @tensor.Tensor,
) -> @tensor.Tensor raise {
  values.sub(self.mean).div(self.variance.sqrt().affine(1.0, bias=0.01))
}

///|
/// PyTorch Sequential(Linear, LayerNorm, GELU, ..., Linear).
struct Mlp {
  layers : Array[@gpu.Layer]
}

///|
fn Mlp::new(like : @tensor.Tensor, dims : Array[Int32]) -> Mlp raise {
  let layers : Array[@gpu.Layer] = []
  for i in 0..<(dims.length() - 1) {
    let (weight, bias, norm_weight, norm_bias) = like.linear_parameters(
      dims[i],
      dims[i + 1],
      with_norm=i + 2 < dims.length(),
    )
    layers.push({ weight, bias, norm_weight, norm_bias, })
  }
  { layers, }
}

///|
fn Mlp::forward(
  self : Mlp,
  input : @tensor.Tensor,
  frozen~ : Bool = false,
) -> @tensor.Tensor raise {
  let param = (t : @tensor.Tensor) => if frozen { t.stop_gradient() } else { t }
  let mut x = input
  for layer in self.layers {
    x = x.linear(param(layer.weight), param(layer.bias))
    if layer.norm_weight is Some(scale) && layer.norm_bias is Some(offset) {
      x = x.layer_norm(param(scale), param(offset), eps=1.0e-5).gelu()
    }
  }
  x
}

///|
pub struct GenModel {
  backend : @tensor.Backend
  dynamics : Mlp
  encoder : Mlp
  velocity_encoder : Mlp
  decoder : Mlp
  critic : Mlp
  state_norm : EmpiricalNorm
  action_norm : EmpiricalNorm
  obs_norm : EmpiricalNorm
  velocity_norm : EmpiricalNorm
  goal_norm : EmpiricalNorm
  scale : @tensor.Tensor
  offset : @tensor.Tensor
  dt : Double
  decimation : Int32
}

///|
pub fn GenModel::new(
  b : @tensor.Backend,
  scale : @tensor.Tensor,
  offset : @tensor.Tensor,
  context_dim~ : Int32,
  device~ : Int32,
  dt~ : Double,
  decimation~ : Int32,
  world_hidden~ : Array[Int32] = [2048, 2048, 2048],
  policy_hidden~ : Array[Int32] = [2048, 1024, 512, 256],
  critic_hidden~ : Array[Int32] = [256, 128],
) -> GenModel raise {
  guard scale.shape() == [29] &&
    offset.shape() == [29] &&
    context_dim > 0 &&
    dt > 0 &&
    decimation > 0 else {
    fail("invalid G1 action space, context or control clock")
  }
  let make = (input : Int32, hidden : Array[Int32], output : Int32) => {
    let dims = [input]
    dims.append(hidden)
    dims.push(output)
    Mlp::new(scale, dims)
  }
  {
    backend: b,
    dynamics: make(68 + 29 + context_dim, world_hidden, 35),
    encoder: make(640, policy_hidden, 32),
    velocity_encoder: make(3, policy_hidden, 32),
    decoder: make(32 + 68, policy_hidden, 29),
    critic: make(68 + 670 + context_dim, critic_hidden, 1),
    state_norm: EmpiricalNorm::new(b, 68, device),
    action_norm: EmpiricalNorm::new(b, 29, device),
    obs_norm: EmpiricalNorm::new(b, 68, device),
    goal_norm: EmpiricalNorm::new(b, 640, device),
    velocity_norm: EmpiricalNorm::new(b, 3, device),
    scale,
    offset,
    dt,
    decimation,
  }
}

///|
pub fn GenModel::observe(
  self : GenModel,
  s : GenState,
  a : @tensor.Tensor,
  g : Goals,
) -> Unit raise {
  self.state_norm.update(s.reduced)
  self.action_norm.update(a.mul(self.scale).add(self.offset))
  self.obs_norm.update(s.reduced)
  self.goal_norm.update(g.actor)
}

///|
pub fn GenModel::act(
  self : GenModel,
  s : GenState,
  g : Goals,
  frozen~ : Bool = false,
) -> @tensor.Tensor raise {
  let z = self.encoder.forward(self.goal_norm.apply(g.actor), frozen~).tanh()
  self.decoder.forward(
    self.backend.concat([z, self.obs_norm.apply(s.reduced)], axis=1),
    frozen~,
  )
}

///|
pub fn GenModel::value(
  self : GenModel,
  s : GenState,
  g : Goals,
  ctx : @tensor.Tensor,
  frozen~ : Bool = false,
) -> @tensor.Tensor raise {
  self.critic.forward(
    self.backend.concat([s.reduced, g.world, ctx], axis=1),
    frozen~,
  )
}

///|
pub fn GenModel::step(
  self : GenModel,
  s : GenState,
  a : @tensor.Tensor,
  ctx : @tensor.Tensor,
  frozen~ : Bool = false,
) -> GenState raise {
  let x = self.backend.concat(
    [
      self.state_norm.apply(s.reduced),
      self.action_norm.apply(a.mul(self.scale).add(self.offset)),
      ctx,
    ],
    axis=1,
  )
  s.advance(
    self.backend,
    self.dynamics.forward(x, frozen~),
    dt=self.dt,
    decimation=self.decimation,
  )
}
