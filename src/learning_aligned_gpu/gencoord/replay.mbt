///|
struct ValidWindows {
  slots : Array[Int32]
  mut head : Int32
  mut count : Int32
  mut streak : Int32
}

///|
fn ValidWindows::insert(
  self : ValidWindows,
  step : Int32,
  done_ : Bool,
) -> Unit {
  let cap = self.slots.length()
  if self.count > 0 && self.slots[self.head] <= step - cap {
    self.head = (self.head + 1) % cap
    self.count -= 1
  }
  if self.streak >= 7 {
    self.slots[(self.head + self.count) % cap] = step - 7
    self.count += 1
  }
  self.streak = if done_ { 0 } else { (self.streak + 1).min(7) }
}

///|
pub struct GenReplay {
  data : @tensor.Tensor
  times : @tensor.Tensor
  windows : Array[ValidWindows]
  cap : Int32
  ctx_dim : Int32
  mut steps : Int32
}

///|
pub fn GenReplay::new(
  like : @tensor.Tensor,
  frame : @tensor.Tensor,
  envs : Int32,
  ctx_dim : Int32,
  cap~ : Int32 = 1000,
) -> GenReplay raise {
  guard cap >= 8 && envs > 0 && ctx_dim > 0 && envs <= 2147483647 / cap else {
    fail("invalid GenCoord replay dimensions")
  }
  {
    data: like.new_zeros([cap * envs, 129 + ctx_dim]),
    times: frame.new_zeros([cap * envs]),
    windows: Array::makei(envs, _ => {
      slots: Array::make(cap, 0),
      head: 0,
      count: 0,
      streak: 0,
    }),
    cap,
    ctx_dim,
    steps: 0,
  }
}

///|
pub fn GenReplay::insert(
  self : GenReplay,
  b : @tensor.Backend,
  state : @tensor.Tensor,
  act : @tensor.Tensor,
  prev : @tensor.Tensor,
  ctx : @tensor.Tensor,
  times : @tensor.Tensor,
  done_ : Array[Bool],
) -> Unit raise {
  let n = self.windows.length()
  guard done_.length() == n &&
    state.shape() == [n, 71] &&
    act.shape() == [n, 29] &&
    prev.shape() == [n, 29] &&
    ctx.shape() == [n, self.ctx_dim] &&
    times.shape() == [n] &&
    times.dtype() == Int64 else {
    fail("invalid replay transition")
  }
  let slot = self.steps % self.cap * n
  self.data
  .narrow(0, slot, n)
  .copy_values_from(b.concat([state, act, prev, ctx], axis=1))
  self.times.narrow(0, slot, n).copy_values_from(times)
  for i, ended in done_ {
    self.windows[i].insert(self.steps, ended)
  }
  self.steps += 1
}

///|
fn GenReplay::indices(
  self : GenReplay,
  length : Int32,
  batch : Int32,
) -> @tensor.Tensor raise {
  guard (length == 1 || length == 8) && self.steps >= length && batch > 0 else {
    fail("replay window unavailable")
  }
  let n = self.windows.length()
  let weights = self.data.backend.from_values(
    [n],
    self.windows.map(w => if length == 1 || w.count > 0 { 1.0 } else { 0.0 }),
    cuda_device=self.data.cuda_device(),
    dtype=Float32,
    requires_grad=false,
  )
  let environments = weights.sample_with_replacement(batch).values()
  let uniforms = weights.uniform_samples(batch).values()
  let filled = self.steps.min(self.cap)
  let vals = Array::make(batch * length, 0.0)
  for i in 0..<batch {
    let env = environments[i].to_int()
    let index = (count : Int32) => {
      (Float::from_double(uniforms[i]) * Float::from_int(count)).to_int()
    }
    let start = if length == 8 {
      let w = self.windows[env]
      w.slots[(w.head + index(w.count)) % self.cap]
    } else {
      self.steps - filled + index(filled)
    }
    for t in 0..<length {
      vals[i * length + t] = ((start + t) % self.cap * n + env).to_double()
    }
  }
  self.data.backend.from_values(
    [batch * length],
    vals,
    cuda_device=self.data.cuda_device(),
    requires_grad=false,
    dtype=Int64,
  )
}

///|
pub fn GenReplay::fit_world(
  self : GenReplay,
  learner : GenLearner,
  batch : Int32,
) -> Double raise {
  let width = 129 + self.ctx_dim
  let x = self.data
    .index_select(self.indices(8, batch))
    .reshape([batch, 8, width])
  learner.fit_world(
    x.narrow(2, 0, 71),
    x.narrow(2, 71, 29),
    x.narrow(1, 0, 1).reshape([batch, width]).narrow(1, 129, self.ctx_dim),
  )
}

///|
pub fn GenReplay::actor_start(
  self : GenReplay,
  batch : Int32,
) -> (GenState, @tensor.Tensor, @tensor.Tensor, @tensor.Tensor) raise {
  let idx = self.indices(1, batch)
  let x = self.data.index_select(idx)
  (
    GenState::from_replay(self.data.backend, x.narrow(1, 0, 71)),
    x.narrow(1, 100, 29),
    x.narrow(1, 129, self.ctx_dim),
    self.times.index_select(idx),
  )
}
