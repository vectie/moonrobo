///|
pub struct GenLearner {
  model : GenModel
  geometry : @geometry.Context
  world_optimizer : Optimizer
  actor_optimizer : Optimizer
  critic_optimizer : Optimizer
}

///|
pub fn GenLearner::new(
  model : GenModel,
  geometry : @geometry.Context,
  lr~ : Double = 0.0002,
) -> GenLearner raise {
  let b = model.backend
  {
    model,
    geometry: geometry
    .with_heading_mode(GenCoordYaw)
    .with_rotation_error_mode(GenCoordTraceAcos),
    world_optimizer: Optimizer::new(b, [model.dynamics], lr, 0.999),
    actor_optimizer: Optimizer::new(b, [model.encoder, model.decoder], lr, 0.95),
    critic_optimizer: Optimizer::new(b, [model.critic], lr, 0.999),
  }
}

///|
/// One of ten separate optimizer steps. Each replay sample has eight stored
/// states; the last action has no target in this window.
pub fn GenLearner::fit_world(
  self : GenLearner,
  flat : @tensor.Tensor,
  actions : @tensor.Tensor,
  context : @tensor.Tensor,
) -> Double raise {
  guard flat.shape() is [n, 8, 71] && actions.shape() == [n, 8, 29] else {
    fail("invalid world replay window")
  }
  let b = self.model.backend
  let state_at = (t : Int32) => {
    GenState::from_replay(b, flat.narrow(1, t, 1).reshape([n, 71]))
  }
  let mut s = state_at(0)
  let errors = []
  for t in 0..<7 {
    s = self.model.step(s, actions.narrow(1, t, 1).reshape([n, 29]), context)
    errors.push(s.fit_error(b, state_at(t + 1)))
  }
  let loss = b.stack(errors).mean()
  self.world_optimizer.update(loss)
  loss.values()[0]
}

///|
/// A short-lived view on reference frames, shared by collection and imagination.
/// Each row's clip end is inclusive. Windows are gathered on demand.
pub struct GenMotions {
  fields : Array[@tensor.Tensor]
  offsets : @tensor.Tensor
}

///|
pub fn GenMotions::new(
  b : @tensor.Backend,
  frames : @tensor.Tensor,
) -> GenMotions raise {
  guard frames.shape() is [n, 71] && n > 0 else {
    fail("invalid G1 motion tensor")
  }
  {
    fields: [frames],
    offsets: b.from_values(
      [1, 10],
      Array::makei(10, i => (5 * i).to_double()),
      cuda_device=frames.cuda_device(),
      requires_grad=false,
      dtype=Int64,
    ),
  }
}

///|
pub fn GenMotions::window(
  self : GenMotions,
  time : @tensor.Tensor,
  last : @tensor.Tensor,
) -> @tensor.Tensor raise {
  let n = time.shape()[0]
  let indices = time.reshape([n, 1]).add(self.offsets)
  let ends = last.reshape([n, 1])
  let idx = indices.greater(ends).select_where(ends, indices)
  self.rows(idx.reshape([-1])).reshape([n, 10, 71])
}

///|
pub fn GenMotions::at(
  self : GenMotions,
  b : @tensor.Backend,
  time : @tensor.Tensor,
) -> @geometry.State raise {
  @geometry.State::from_flat71(b, self.rows(time.reshape([-1])))
}

///|
fn critic_input(
  b : @tensor.Backend,
  s : GenState,
  goals : Goals,
  context : @tensor.Tensor,
) -> @tensor.Tensor raise {
  b.concat([s.reduced, goals.world, context], axis=1)
}

///|
/// The actor's bootstrap differentiates with respect to its input. Critic
/// fitting uses detached observations and the original, uncapped V in GAE.
fn GenLearner::actor_block(
  self : GenLearner,
  motions : GenMotions,
  initial : GenState,
  previous_action : @tensor.Tensor,
  context : @tensor.Tensor,
  start : @tensor.Tensor,
  last : @tensor.Tensor,
  height~ : Double,
  tilt~ : Double,
  horizon~ : Int32,
  fraction~ : Double,
) -> (Double, @tensor.Tensor, @tensor.Tensor) raise {
  let b = self.model.backend
  let n = initial.reduced.shape()[0]
  let mut s = initial
  let mut time = start.reshape([n])
  let ends = last.reshape([n])
  let mut previous = previous_action
  let mut survive = s.reduced.narrow(1, 0, 1).affine(0.0, bias=1.0)
  let mut ret = survive.affine(0.0)
  let mut discount = 1.0
  let mut goals = s.goals(b, motions.window(time, ends))
  let inputs = []
  let rewards = []
  let dones = []
  let max_value = self.model.dt * 5.0 / (1.0 - 0.99)
  for _ in 0..<horizon {
    inputs.push(critic_input(b, s, goals, context).stop_gradient())
    let action = self.model.act(s, goals)
    let reference = motions.at(b, time)
    s = self.model.step(s, action, context, frozen=true)
    let reward = self.geometry
      .reward(s.geometry(b), reference, action, previous)
      .reshape([n, 1])
    let done_ = s.failure(b, reference, height~, tilt~)
    ret = ret.add(survive.mul(reward).affine(discount))
    survive = survive.mul(done_.affine(-1.0, bias=1.0))
    rewards.push(reward.stop_gradient())
    dones.push(done_.stop_gradient())
    previous = action
    // Keep integer frame cursors; Tensor.affine is a floating-point operator.
    time = time.add(time.less(ends))
    goals = s.goals(b, motions.window(time, ends))
    discount *= 0.99
  }
  let tail_input = critic_input(b, s, goals, context)
  let tail = self.model.critic.forward(tail_input, frozen=true)
  let total = ret.add(
    survive.mul(tail.clamp(@double.neg_infinity, max_value)).affine(discount),
  )
  let mean = total.mean()
  mean.affine(-fraction).backward()
  let features = b.concat(inputs)
  let values = self.model.critic
    .forward(features, frozen=true)
    .reshape([horizon, n, 1])
  let last_value = tail.stop_gradient()
  let mut next = last_value
  let mut advantage = last_value.affine(0.0)
  let targets = []
  for i in 0..<horizon {
    let t = horizon - 1 - i
    let value = values.narrow(0, t, 1).reshape([n, 1])
    let alive = dones[t].affine(-1.0, bias=1.0)
    let delta = rewards[t].add(alive.mul(next).affine(0.99)).sub(value)
    advantage = delta.add(alive.mul(advantage).affine(0.99 * 0.95))
    targets.push(
      advantage
      .add(value)
      .clamp(@double.neg_infinity, max_value)
      .stop_gradient(),
    )
    next = value
  }
  targets.rev_in_place()
  (
    mean.values()[0],
    features.reshape([horizon, n, -1]),
    b.concat(targets).reshape([horizon, n, 1]),
  )
}

///|
/// Accumulate the full-batch actor gradient before clipping and updating. Join
/// rollout data in time-major order before the global critic shuffle.
pub fn GenLearner::improve(
  self : GenLearner,
  motions : GenMotions,
  initial : GenState,
  previous_action : @tensor.Tensor,
  context : @tensor.Tensor,
  start : @tensor.Tensor,
  last : @tensor.Tensor,
  permutation : @tensor.Tensor,
  height~ : Double,
  tilt~ : Double,
  horizon~ : Int32 = 32,
  microbatch? : Int32,
) -> (Double, Double) raise {
  let b = self.model.backend
  let n = initial.reduced.shape()[0]
  let block = microbatch.unwrap_or(n)
  guard block > 0 &&
    horizon > 0 &&
    n > 0 &&
    horizon * n % 4 == 0 &&
    permutation.shape() == [horizon * n] else {
    fail("invalid policy batch or critic shuffle")
  }
  self.actor_optimizer.zero()
  let inputs = []
  let targets = []
  let mut ret = 0.0
  for i in 0..<((n + block - 1) / block) {
    let offset = i * block
    let size = block.min(n - offset)
    let part = (x : @tensor.Tensor) => x.narrow(0, offset, size)
    let s = {
      position: part(initial.position),
      quat: part(initial.quat),
      reduced: part(initial.reduced),
    }
    let fraction = size.to_double() / n.to_double()
    let (mean, features, y) = self.actor_block(
      motions,
      s,
      part(previous_action),
      part(context),
      part(start),
      part(last),
      height~,
      tilt~,
      horizon~,
      fraction~,
    )
    ret += mean * fraction
    inputs.push(features)
    targets.push(y)
  }
  self.actor_optimizer.finish(clip_value=0.1)
  let features = b.concat(inputs, axis=1).reshape([n * horizon, -1])
  let y = b.concat(targets, axis=1).reshape([n * horizon, 1])
  let width = n * horizon / 4
  let losses = []
  for _ in 0..<5 {
    for j in 0..<4 {
      let idx = permutation.narrow(0, j * width, width)
      let loss = self.model.critic
        .forward(features.index_select(idx))
        .sub(y.index_select(idx))
        .square()
        .mean()
      self.critic_optimizer.update(loss)
      losses.push(loss.stop_gradient())
    }
  }
  (ret, b.stack(losses).mean().values()[0])
}

///|
/// The six tensors share storage with mjlab; a corpus-sized concatenation would
/// duplicate the reference library in unified memory.
pub fn GenMotions::from_fields(
  b : @tensor.Backend,
  fields : Array[@tensor.Tensor],
) -> GenMotions raise {
  let widths = [3, 4, 3, 3, 29, 29]
  guard fields.length() == 6 && fields[0].shape() is [n, 3] && n > 0 else {
    fail("invalid mjlab motion fields")
  }
  for i, t in fields {
    guard t.shape() == [n, widths[i]] &&
      t.cuda_device() == fields[0].cuda_device() else {
      fail("incompatible motion field")
    }
  }
  {
    fields,
    offsets: b.from_values(
      [1, 10],
      Array::makei(10, i => (5 * i).to_double()),
      cuda_device=fields[0].cuda_device(),
      requires_grad=false,
      dtype=Int64,
    ),
  }
}

///|
fn GenMotions::rows(
  self : GenMotions,
  idx : @tensor.Tensor,
) -> @tensor.Tensor raise {
  if self.fields.length() == 1 {
    self.fields[0].index_select(idx)
  } else {
    idx.backend.concat(self.fields.map(t => t.index_select(idx)), axis=1)
  }
}
