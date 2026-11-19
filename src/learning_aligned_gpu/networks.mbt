///|
pub(all) struct Layer {
  weight : @tensor.Tensor
  bias : @tensor.Tensor
  norm_weight : @tensor.Tensor?
  norm_bias : @tensor.Tensor?
}

///|
/// Execution choice only; both paths use affine population-variance LayerNorm.
pub(all) enum LayerNormMode {
  Expanded
  Native
  Submitted
  FusedTail
} derive(Eq, Debug, ToJson, FromJson)

///|
/// SMC-style MLP compute precision. Master parameters and Adam stay FP32.
pub(all) enum MlpPrecision {
  Fp32
  Bf16
} derive(Eq, Debug, ToJson, FromJson)

///|
/// Preserve the original separate matmul/bias path for paired comparisons.
pub(all) enum LinearMode {
  MatmulBias
  NativeLinear
} derive(Eq, Debug, ToJson, FromJson)

///|
pub(all) struct Network {
  layers : Array[Layer]
  activation : @aligned.Activation
  layer_norm_mode : LayerNormMode
  mlp_precision : MlpPrecision
  linear_mode : LinearMode
}

///|
/// Initialization follows the scalar port's PyTorch Linear distribution/layout.
/// Seeded bit patterns follow MoonBit Rng, not PyTorch's separate generator.
pub fn Network::new(
  backend : @tensor.Backend,
  dims : Array[Int32],
  rng : @numeric.Rng,
  cuda_device~ : Int32 = -1,
  activation~ : @aligned.Activation = Elu,
  layer_norm~ : Bool = false,
  layer_norm_mode~ : LayerNormMode = Expanded,
  mlp_precision~ : MlpPrecision = Fp32,
  linear_mode~ : LinearMode = MatmulBias,
  zero_last~ : Bool = false,
  final_scale~ : Double = 1.0,
) -> Network raise {
  guard dims.length() >= 2 && dims.all(d => d > 0) else {
    fail("invalid network widths")
  }
  guard linear_mode != NativeLinear || backend.has_linear() else {
    fail(
      "native Linear requested but tensor plugin lacks the optional extension",
    )
  }
  guard !layer_norm || layer_norm_mode != Native || backend.has_layer_norm() else {
    fail(
      "native LayerNorm requested but tensor plugin lacks the optional extension",
    )
  }
  guard !layer_norm ||
    layer_norm_mode != Submitted ||
    backend.has_layer_norm_submitted() else {
    fail("submitted expanded LayerNorm extension unavailable")
  }
  guard mlp_precision != Bf16 || backend.has_bf16_linear() else {
    fail(
      "BF16 MLP requested but tensor plugin lacks the optional precision extension",
    )
  }
  guard !layer_norm ||
    layer_norm_mode != FusedTail ||
    (
      backend.has_ln_silu_tail() &&
      cuda_device >= 0 &&
      mlp_precision == Fp32 &&
      activation is Silu
    ) else {
    fail("fused LN tail requires CUDA FP32 SiLU and its optional plugin")
  }
  let layers = []
  for i in 0..<(dims.length() - 1) {
    let nin = dims[i]
    let nout = dims[i + 1]
    guard nin <= 2147483647 / nout else {
      fail("network layer exceeds array capacity")
    }
    let last = i == dims.length() - 2
    let bound = 1.0 / nin.to_double().sqrt()
    let weight = backend.from_values(
      [nout, nin],
      Array::makei(nout * nin, _ => {
        if last && zero_last {
          0.0
        } else {
          (rng.uniform() * 2.0 - 1.0) *
          bound *
          (if last { final_scale } else { 1.0 })
        }
      }),
      cuda_device~,
      requires_grad=true,
      dtype=Float32,
    )
    let bias = backend.from_values(
      [nout],
      Array::makei(nout, _ => {
        if last && (zero_last || final_scale != 1.0) {
          0.0
        } else {
          (rng.uniform() * 2.0 - 1.0) * bound
        }
      }),
      cuda_device~,
      requires_grad=true,
      dtype=Float32,
    )
    let (norm_weight, norm_bias) = if layer_norm && !last {
      (
        Some(
          backend.from_values(
            [nout],
            Array::make(nout, 1.0),
            cuda_device~,
            requires_grad=true,
            dtype=Float32,
          ),
        ),
        Some(
          backend.from_values(
            [nout],
            Array::make(nout, 0.0),
            cuda_device~,
            requires_grad=true,
            dtype=Float32,
          ),
        ),
      )
    } else {
      (None, None)
    }
    layers.push({ weight, bias, norm_weight, norm_bias, })
  }
  { layers, activation, layer_norm_mode, mlp_precision, linear_mode, }
}

///|
pub fn Network::parameters(self : Network) -> Array[@tensor.Tensor] {
  let out = []
  for layer in self.layers {
    out.push(layer.weight)
    out.push(layer.bias)
    if layer.norm_weight is Some(x) {
      out.push(x)
    }
    if layer.norm_bias is Some(x) {
      out.push(x)
    }
  }
  out
}

///|
/// Frozen weights share storage; input gradients remain available during BPTT.
pub fn Network::frozen(self : Network) -> Network raise {
  {
    activation: self.activation,
    layer_norm_mode: self.layer_norm_mode,
    mlp_precision: self.mlp_precision,
    linear_mode: self.linear_mode,
    layers: self.layers.map(layer => {
      weight: layer.weight.stop_gradient(),
      bias: layer.bias.stop_gradient(),
      norm_weight: layer.norm_weight.map(x => x.stop_gradient()),
      norm_bias: layer.norm_bias.map(x => x.stop_gradient()),
    }),
  }
}

///|
pub fn Network::forward(
  self : Network,
  input : @tensor.Tensor,
) -> @tensor.Tensor raise {
  let diagnostic = @tensor.operator_diagnostics_enabled()
  let mut x = input
  for i, layer in self.layers {
    let mut activated = false
    let layer_range = if diagnostic {
      @tensor.operator_range_begin("diag.network.layer.\{i}")
    } else {
      0L
    }
    errdefer @tensor.operator_range_cancel(layer_range)
    let linear_range = if diagnostic {
      @tensor.operator_range_begin("diag.network.linear")
    } else {
      0L
    }
    errdefer @tensor.operator_range_cancel(linear_range)
    x = match self.mlp_precision {
      Fp32 =>
        match self.linear_mode {
          MatmulBias => x.matmul(layer.weight.transpose()).add(layer.bias)
          NativeLinear => x.linear(layer.weight, layer.bias)
        }
      Bf16 => x.linear_bf16(layer.weight, layer.bias)
    }
    @tensor.operator_range_end(linear_range)
    if layer.norm_weight is Some(weight) && layer.norm_bias is Some(bias) {
      let norm_range = if diagnostic {
        @tensor.operator_range_begin(
          match self.layer_norm_mode {
            Expanded => "diag.network.ln.expanded"
            Native => "diag.network.ln.native"
            Submitted => "diag.network.ln.submitted"
            FusedTail => "diag.network.ln.fused_tail"
          },
        )
      } else {
        0L
      }
      errdefer @tensor.operator_range_cancel(norm_range)
      // CUDA autocast puts LayerNorm in FP32. Keep the existing expanded/native
      // choice independent: this precision candidate does not promote native LN.
      if self.mlp_precision == Bf16 {
        x = x.cast_float(Float32)
      }
      x = match self.layer_norm_mode {
        Native => x.layer_norm(weight, bias, eps=1.0e-5)
        Submitted => x.layer_norm_submitted(weight, bias, eps=1.0e-5)
        FusedTail => {
          let centered = x.sub(x.mean_dim(-1, keepdim=true))
          let variance = centered.square().mean_dim(-1, keepdim=true)
          activated = true
          centered.ln_silu_tail(variance, weight, bias, eps=1.0e-5)
        }
        Expanded => {
          let centered = x.sub(x.mean_dim(-1, keepdim=true))
          centered
          .div(
            centered
            .square()
            .mean_dim(-1, keepdim=true)
            .affine(1.0, bias=1.0e-5)
            .sqrt(),
          )
          .mul(weight)
          .add(bias)
        }
      }
      @tensor.operator_range_end(norm_range)
    }
    if i + 1 != self.layers.length() && !activated {
      let activation_range = if diagnostic {
        @tensor.operator_range_begin("diag.network.activation")
      } else {
        0L
      }
      errdefer @tensor.operator_range_cancel(activation_range)
      x = match self.activation {
        Elu => x.elu()
        Silu => x.silu()
      }
      @tensor.operator_range_end(activation_range)
    }
    @tensor.operator_range_end(layer_range)
  }
  if self.mlp_precision == Bf16 {
    x.cast_float(Float32)
  } else {
    x
  }
}

///|
pub(all) struct RunningNorm {
  mut mean : @tensor.Tensor
  mut variance : @tensor.Tensor
  mut count : Double
  dim : Int32
  eps : Double
  max_count : Double
  // Explicit, fixed-shape BF16-input package. Default disabled; not restored
  // from checkpoints. Full actor/critic acceptance is required before training.
  mut compiled_bf16_input : @tensor.CompiledBlock?
  // Original FP32 Welford + update order; separate opt-in numerical candidate.
  mut smc_statistics : Bool
}

///|
pub fn RunningNorm::new(
  backend : @tensor.Backend,
  dim : Int32,
  cuda_device~ : Int32 = -1,
  eps~ : Double = 0.01,
  max_count~ : Double = 2.0e8,
) -> RunningNorm raise {
  guard dim > 0 && eps > 0.0 && max_count > 0.0 else {
    fail("invalid running normalizer dimensions or limits")
  }
  {
    mean: backend.from_values(
      [dim],
      Array::make(dim, 0.0),
      cuda_device~,
      requires_grad=false,
      dtype=Float32,
    ),
    variance: backend.from_values(
      [dim],
      Array::make(dim, 1.0),
      cuda_device~,
      requires_grad=false,
      dtype=Float32,
    ),
    count: 0.0,
    dim,
    eps,
    max_count,
    compiled_bf16_input: None,
    smc_statistics: false,
  }
}

///|
pub fn RunningNorm::update(
  self : RunningNorm,
  values : @tensor.Tensor,
  collective~ : @tensor.Collective? = None,
) -> Unit raise {
  let shape = values.shape()
  guard !shape.is_empty() && shape[shape.length() - 1] == self.dim else {
    fail("normalizer input width mismatch")
  }
  if self.count >= self.max_count {
    return
  }
  let rows = values.stop_gradient().reshape([-1, self.dim])
  let n = rows.shape()[0].to_double()
  if collective is Some(group) {
    // Pool count, first and second raw moments. Averaging per-rank variance
    // alone would drop the between-rank part of the variance.
    let backend = self.mean.backend
    let count = backend.from_values(
      [1],
      [n],
      cuda_device=group.cuda_device,
      requires_grad=false,
      dtype=Float32,
    )
    let moments = group.all_reduce(
      backend.concat([rows.sum_dim(0), rows.square().sum_dim(0), count], axis=0),
    )
    let count = moments.narrow(0, self.dim * 2, 1).values()[0]
    self.merge_raw_moments(
      moments.narrow(0, 0, self.dim),
      moments.narrow(0, self.dim, self.dim),
      count,
    )
    return
  }
  if n == 0.0 {
    return
  }
  if self.smc_statistics {
    let rows = rows.cast_float(Float32)
    let mean = rows.mean_dim(0)
    let variance = rows.population_variance_dim(0)
    let denominator = self.mean.backend
      .from_values(
        [1],
        [self.count],
        cuda_device=self.mean.cuda_device(),
        requires_grad=false,
        dtype=Float32,
      )
      .affine(1.0, bias=n)
    let total = denominator.values()[0]
    let delta = mean.sub(self.mean)
    self.mean = self.mean.add(delta.affine(n).div(denominator))
    self.variance = self.variance
      .affine(self.count)
      .add(variance.affine(n))
      .add(delta.square().affine(self.count).affine(n).div(denominator))
      .div(denominator)
    self.count = total
    return
  }
  let total = self.count + n
  let mean = rows.mean_dim(0)
  let variance = rows.sub(mean).square().mean_dim(0)
  let delta = mean.sub(self.mean)
  self.mean = self.mean.add(delta.affine(n / total))
  self.variance = self.variance
    .affine(self.count)
    .add(variance.affine(n))
    .add(delta.square().affine(self.count * n / total))
    .affine(1.0 / total)
  self.count = total
}

///|
pub fn RunningNorm::std(self : RunningNorm) -> @tensor.Tensor raise {
  self.variance.affine(1.0, bias=self.eps * self.eps).sqrt()
}

///|
pub fn RunningNorm::apply(
  self : RunningNorm,
  values : @tensor.Tensor,
) -> @tensor.Tensor raise {
  if self.compiled_bf16_input is Some(block) {
    guard self.eps == 0.01 else {
      fail("compiled BF16 normalization requires the exported epsilon")
    }
    return block.forward([values, self.mean, self.variance])
  }
  values.sub(self.mean).div(self.std())
}

///|
pub(all) struct WorldModel {
  net : Network
  input_norm : RunningNorm
  output_norm : RunningNorm
  // Experimental compiled MLP for fitting only. Frozen actor rollouts keep
  // their original path and shape until separately validated packages exist.
  mut compiled_fitting_mlp : @tensor.CompiledBlock?
  mut compiled_fitting_window : (@tensor.CompiledBlock, @tensor.CompiledBlock)?
}

///|
pub fn WorldModel::new(
  backend : @tensor.Backend,
  rng : @numeric.Rng,
  cuda_device~ : Int32 = -1,
  hidden~ : Array[Int32] = [2048, 2048, 2048],
  layer_norm_mode~ : LayerNormMode = Expanded,
  linear_mode~ : LinearMode = MatmulBias,
  mlp_precision~ : MlpPrecision = Fp32,
) -> WorldModel raise {
  let dims = [133]
  dims.append(hidden)
  dims.push(70)
  {
    net: Network::new(
      backend,
      dims,
      rng,
      cuda_device~,
      activation=Silu,
      layer_norm=true,
      layer_norm_mode~,
      linear_mode~,
      mlp_precision~,
      zero_last=true,
    ),
    input_norm: RunningNorm::new(backend, 133, cuda_device~),
    output_norm: RunningNorm::new(backend, 70, cuda_device~, eps=0.0001),
    compiled_fitting_mlp: None,
    compiled_fitting_window: None,
  }
}

///|
pub fn WorldModel::delta(
  self : WorldModel,
  inputs : @tensor.Tensor,
  frozen_net? : Network,
) -> @tensor.Tensor raise {
  let range = @tensor.operator_range_begin("diag.world.mlp")
  errdefer @tensor.operator_range_cancel(range)
  let net = frozen_net.unwrap_or(self.net)
  let output = net
    .forward(self.input_norm.apply(inputs))
    .mul(self.output_norm.std())
    .add(self.output_norm.mean)
  @tensor.operator_range_end(range)
  output
}

///|
pub(all) struct Policy {
  backend : @tensor.Backend
  encoder : Network
  decoder : Network
  obs_norm : RunningNorm
  goal_norm : RunningNorm
  hist : Int32
  obs_dim : Int32
  action_mask : @tensor.Tensor?
}

///|
pub fn Policy::new(
  backend : @tensor.Backend,
  obs_dim : Int32,
  goal_dim : Int32,
  rng : @numeric.Rng,
  cuda_device~ : Int32 = -1,
  hist~ : Int32 = 10,
  hidden~ : Array[Int32] = [2048, 1024, 512, 256],
  linear_mode~ : LinearMode = MatmulBias,
  mlp_precision~ : MlpPrecision = Fp32,
  active_joints~ : Int32 = 29,
) -> Policy raise {
  guard active_joints > 0 && active_joints <= 29 else {
    fail("policy active joint count must be in 1..29")
  }
  let enc = [goal_dim]
  enc.append(hidden)
  enc.push(32)
  let dec = [32 + obs_dim * hist]
  dec.append(hidden)
  dec.push(29)
  {
    backend,
    encoder: Network::new(
      backend,
      enc,
      rng,
      cuda_device~,
      mlp_precision~,
      linear_mode~,
    ),
    decoder: Network::new(
      backend,
      dec,
      rng,
      cuda_device~,
      mlp_precision~,
      final_scale=0.01,
      linear_mode~,
    ),
    obs_norm: RunningNorm::new(backend, obs_dim, cuda_device~),
    goal_norm: RunningNorm::new(backend, goal_dim, cuda_device~),
    hist,
    obs_dim,
    action_mask: if active_joints == 29 {
      None
    } else {
      Some(
        backend.from_values(
          [1, 29],
          Array::makei(29, i => if i < active_joints { 1.0 } else { 0.0 }),
          cuda_device~,
          requires_grad=false,
          dtype=Float32,
        ),
      )
    },
  }
}

///|
pub fn Policy::parameters(self : Policy) -> Array[@tensor.Tensor] {
  let p = self.encoder.parameters()
  p.append(self.decoder.parameters())
  p
}

///|
pub fn Policy::update_normalizers(
  self : Policy,
  observations : @tensor.Tensor,
  goals : @tensor.Tensor,
  collective~ : @tensor.Collective? = None,
) -> Unit raise {
  self.obs_norm.update(observations, collective~)
  self.goal_norm.update(goals, collective~)
}

///|
pub fn Policy::forward(
  self : Policy,
  history : @tensor.Tensor,
  goals : @tensor.Tensor,
) -> @tensor.Tensor raise {
  let batch = history.shape()[0]
  let encoder_range = @tensor.operator_range_begin("diag.policy.encoder")
  errdefer @tensor.operator_range_cancel(encoder_range)
  let z = self.encoder.forward(self.goal_norm.apply(goals)).tanh()
  @tensor.operator_range_end(encoder_range)
  let h = self.obs_norm
    .apply(history)
    .reshape([batch, self.hist * self.obs_dim])
  let decoder_range = @tensor.operator_range_begin("diag.policy.decoder")
  errdefer @tensor.operator_range_cancel(decoder_range)
  let output = self.decoder.forward(self.backend.concat([z, h], axis=-1))
  @tensor.operator_range_end(decoder_range)
  self.project_actions(output)
}

///|
pub fn Policy::project_actions(
  self : Policy,
  action : @tensor.Tensor,
) -> @tensor.Tensor raise {
  match self.action_mask {
    None => action
    Some(mask) => action.mul(mask)
  }
}

///|
pub(all) struct Critic {
  net : Network
  norm : RunningNorm
}

///|
pub fn Critic::new(
  backend : @tensor.Backend,
  input_dim : Int32,
  rng : @numeric.Rng,
  cuda_device~ : Int32 = -1,
  hidden~ : Array[Int32] = [256, 128],
  linear_mode~ : LinearMode = MatmulBias,
  mlp_precision~ : MlpPrecision = Fp32,
) -> Critic raise {
  let dims = [input_dim]
  dims.append(hidden)
  dims.push(1)
  {
    net: Network::new(
      backend,
      dims,
      rng,
      cuda_device~,
      mlp_precision~,
      linear_mode~,
    ),
    norm: RunningNorm::new(backend, input_dim, cuda_device~),
  }
}

///|
pub fn Critic::forward(
  self : Critic,
  inputs : @tensor.Tensor,
  frozen_net? : Network,
) -> @tensor.Tensor raise {
  self.forward_observed(inputs, frozen_net, None, false)
}

///|
fn Critic::forward_observed(
  self : Critic,
  inputs : @tensor.Tensor,
  frozen_net : Network?,
  trace : CriticTrace?,
  bootstrap : Bool,
) -> @tensor.Tensor raise {
  let range = @tensor.operator_range_begin("diag.critic.mlp")
  errdefer @tensor.operator_range_cancel(range)
  let normalized = self.norm.apply(inputs)
  if trace is Some(recorder) {
    recorder.normalized(normalized, bootstrap)
  }
  let output = frozen_net.unwrap_or(self.net).forward(normalized).reshape([-1])
  @tensor.operator_range_end(range)
  output
}
