///|
struct Optimizer {
  params : Array[@tensor.Tensor]
  adam : @tensor.Adam
  muon : Array[(@tensor.Tensor, @tensor.Tensor)]
  lr : Double
}

///|
fn Optimizer::new(
  b : @tensor.Backend,
  nets : Array[Mlp],
  lr : Double,
  beta2 : Double,
) -> Optimizer raise {
  let params = []
  let adam = []
  let muon = []
  for net in nets {
    for i, layer in net.layers {
      params.push(layer.weight)
      if i > 0 && i + 1 < net.layers.length() {
        muon.push((layer.weight, layer.weight.stop_gradient().affine(0.0)))
      } else {
        adam.push(layer.weight)
      }
      params.push(layer.bias)
      adam.push(layer.bias)
      if layer.norm_weight is Some(w) && layer.norm_bias is Some(v) {
        params.append([w, v])
        adam.append([w, v])
      }
    }
  }
  { params, lr, muon, adam: b.adam(adam, learning_rate=lr, beta2~), }
}

///|
fn Optimizer::update(
  self : Optimizer,
  loss : @tensor.Tensor,
  clip_value~ : Double = 0.0,
) -> Unit raise {
  self.zero()
  loss.backward()
  self.finish(clip_value~)
}

///|
fn Optimizer::zero(self : Optimizer) -> Unit raise {
  self.adam.zero_grad()
  for (weight, _) in self.muon {
    weight.zero_gradient()
  }
}

///|
fn Optimizer::finish(
  self : Optimizer,
  clip_value~ : Double = 0.0,
) -> Unit raise {
  self.adam.step_gencoord(self.params, clip_value~)
  for (p, momentum) in self.muon {
    p.muon_update(momentum, self.lr)
  }
}
