///|
pub fn finite_returns(reward : Array[Double], gamma : Double) -> Array[Double] {
  let result = Array::make(reward.length(), 0.0)
  let mut tail = 0.0
  for i = reward.length() - 1; i >= 0; i = i - 1 {
    tail = reward[i] + gamma * tail
    result[i] = tail
  }
  result
}

///|
/// Finite GAE: a done boundary suppresses both value bootstrap and carry.
/// Like the Python learner this scales by population std without centering.
pub fn ppo_advantages(
  reward : Array[Double],
  done : Array[Bool],
  values : Array[Double],
  gamma : Double,
  gae_lambda : Double,
) -> Array[Double] {
  let n = reward.length()
  guard n > 0 && done.length() == n && values.length() == n else {
    abort("GAE shape")
  }
  let advantage = Array::make(n, 0.0)
  let mut carry = 0.0
  for i = n - 1; i >= 0; i = i - 1 {
    let following = if i + 1 < n { values[i + 1] } else { 0.0 }
    let alive = if done[i] { 0.0 } else { 1.0 }
    let delta = reward[i] + gamma * alive * following - values[i]
    carry = delta + gamma * gae_lambda * alive * carry
    advantage[i] = carry
  }
  let mean = advantage.fold(init=0.0, (a, b) => a + b) / n.to_double()
  let variance = advantage.fold(init=0.0, (sum, x) => {
      sum + (x - mean) * (x - mean)
    }) /
    n.to_double()
  let scale = variance.sqrt().max(1.0e-6)
  advantage.map(x => x / scale)
}

///|
pub fn gaussian_log_probability(
  sample : Array[Double],
  mean : Array[Double],
  std : Double,
) -> Double {
  guard sample.length() == mean.length() && std > 0.0 else {
    abort("normal distribution shape")
  }
  let constant = @math.ln(std) + 0.5 * @math.ln(2.0 * 3.141592653589793)
  sample.foldi(init=0.0, (i, sum, x) => {
    sum - constant - 0.5 * (x - mean[i]) * (x - mean[i]) / (std * std)
  })
}

///|
pub fn ppo_surrogate_loss(
  new_log : Array[Double],
  old_log : Array[Double],
  advantage : Array[Double],
  steps : Array[Int32],
  origins : Array[Int32],
  gamma : Double,
  clip : Double,
) -> Double {
  let n = new_log.length()
  guard n > 0 &&
    old_log.length() == n &&
    advantage.length() == n &&
    steps.length() == n &&
    origins.length() == n else {
    abort("PPO shape")
  }
  let weights = Array::makei(n, i => {
    @math.pow(gamma, (steps[i] - origins[i]).to_double())
  })
  let normalization = (weights.fold(init=0.0, (a, b) => a + b) / n.to_double()).max(
    1.0e-8,
  )
  new_log.foldi(init=0.0, (i, total, logp) => {
    let ratio = @math.exp(logp - old_log[i])
    total -
    weights[i] /
    normalization *
    (ratio * advantage[i]).min(
      clamp(ratio, 1.0 - clip, 1.0 + clip) * advantage[i],
    )
  }) /
  n.to_double()
}

///|
pub fn gaussian_mean_kl(
  current : Array[Array[Double]],
  old : Array[Array[Double]],
  std : Double,
) -> Double {
  guard !current.is_empty() && current.length() == old.length() && std > 0.0 else {
    abort("KL shape")
  }
  current.foldi(init=0.0, (i, sum, row) => {
    sum +
    row.foldi(init=0.0, (j, total, x) => {
      total + 0.5 * (x - old[i][j]) * (x - old[i][j]) / (std * std)
    })
  }) /
  current.length().to_double()
}

///|
pub fn actor_origin_candidates(
  episode_lengths : Array[Int32],
  trajectory_states~ : Bool = false,
) -> Array[Int32] {
  let result : Array[Int32] = []
  let mut start = 0
  for length in episode_lengths {
    guard length > 0 else { abort("nonempty episodes required") }
    if trajectory_states {
      for i in 0..<length {
        result.push(start + i)
      }
    } else {
      result.push(start)
    }
    start += length
  }
  result
}

///|
pub(all) struct ModelWindow {
  state : Array[Array[Double]]
  action : Array[Array[Double]]
  target : Array[Array[Double]]
  context : Array[Double]
} derive(Debug, ToJson, FromJson)

///|
pub(all) struct LearningEpisode {
  state : Array[Array[Double]]
  action : Array[Array[Double]]
  next_state : Array[Array[Double]]
  context : Array[Double]
} derive(Debug)

///|
pub struct ReferenceModelReplay {
  capacity : Int32
  horizon : Int32
  anchor_after : Int32?
  mut append_count : Int32
  mut parts : Array[ModelWindow]
  mut initial : Array[ModelWindow]
  mut recent : Array[ModelWindow]
  mut anchor_windows : Int32
} derive(ToJson, FromJson)

///|
pub fn ReferenceModelReplay::new(
  capacity : Int32,
  horizon : Int32,
  anchor_after? : Int32,
) -> ReferenceModelReplay {
  guard capacity > 0 && horizon > 0 else {
    abort("positive replay shape required")
  }
  {
    capacity,
    horizon,
    anchor_after,
    append_count: 0,
    parts: [],
    initial: [],
    recent: [],
    anchor_windows: 0,
  }
}

///|
pub fn ReferenceModelReplay::append(
  self : ReferenceModelReplay,
  episodes : Array[LearningEpisode],
) -> Unit {
  let fresh : Array[ModelWindow] = []
  for episode in episodes {
    let n = episode.state.length()
    guard episode.action.length() == n && episode.next_state.length() == n else {
      abort("episode shape")
    }
    if n >= self.horizon {
      for i in 0..<(n - self.horizon + 1) {
        fresh.push({
          state: episode.state[i:i + self.horizon].to_owned(),
          action: episode.action[i:i + self.horizon].to_owned(),
          target: episode.next_state[i:i + self.horizon].to_owned(),
          context: episode.context.copy(),
        })
      }
    }
  }
  guard !fresh.is_empty() else {
    abort("no complete model windows in collected physics")
  }
  self.append_count += 1
  if self.anchor_after is Some(_) {
    if self.initial.is_empty() {
      guard fresh.length() < self.capacity else {
        abort("initial anchor leaves no recent-window capacity")
      }
      self.initial = fresh.copy()
    } else {
      self.recent.append(fresh)
      self.recent = self.recent[(self.recent.length() - self.capacity).max(0):].to_owned()
    }
  }
  self.parts.append(fresh)
  self.parts = self.parts[(self.parts.length() - self.capacity).max(0):].to_owned()
  if self.anchor_after is Some(after) && self.append_count > after {
    self.anchor_windows = self.initial.length()
    let recent_capacity = self.capacity - self.anchor_windows
    self.parts = self.initial.copy()
    self.parts.append(
      self.recent[(self.recent.length() - recent_capacity).max(0):].to_owned(),
    )
  }
}

///|
pub fn ReferenceModelReplay::windows(
  self : ReferenceModelReplay,
) -> Array[ModelWindow] {
  self.parts.copy()
}

///|
pub fn ReferenceModelReplay::anchor_count(self : ReferenceModelReplay) -> Int32 {
  self.anchor_windows
}
