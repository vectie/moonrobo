///|
/// Physics transitions include the actual applied action, never teacher targets.
pub(all) struct Transition {
  time_s : Double
  state : Array[Double]
  observation : Array[Double]
  applied_action : Array[Double]
  next_state : Array[Double]
  goal : Array[Double]
  terminated : Bool
  truncated : Bool
} derive(Debug)

///|
pub(all) struct Episode {
  id : String
  split : String
  context : Array[Double]
  steps : Array[Transition]
} derive(Debug)

///|
/// All sliding windows for online replay. No window crosses a reset or timestamp gap.
pub fn episode_windows(
  episodes : Array[Episode],
  horizon : Int32,
  dt : Double,
  stride~ : Int32 = 1,
  reject_reset~ : Bool = false,
) -> Array[Window] {
  guard horizon > 0 && dt > 0 && stride > 0 else {
    abort("invalid replay window geometry")
  }
  let identities : Map[String, Bool] = {}
  let windows = []
  for episode in episodes {
    guard episode.split == "train" && !identities.contains(episode.id) else {
      abort("held-out or duplicate actual-action episode")
    }
    identities[episode.id] = true
    let steps = episode.steps
    if reject_reset {
      for i in 0..<(steps.length() - 1) {
        guard !steps[i].terminated && !steps[i].truncated else {
          abort("actual-action episode crosses reset")
        }
      }
    }
    let final = steps.length() - horizon
    if final < 0 {
      continue
    }
    let ids = []
    for i = 0; i <= final; i = i + stride {
      ids.push(i)
    }
    if ids[ids.length() - 1] != final {
      ids.push(final)
    }
    for start in ids {
      let mut valid = true
      for j in start..<(start + horizon - 1) {
        if (steps[j + 1].time_s - steps[j].time_s - dt).abs() > dt * 0.000001 ||
          steps[j].terminated ||
          steps[j].truncated {
          valid = false
        }
      }
      if !valid {
        continue
      }
      let state = Array::makei(horizon, j => steps[start + j].state)
      let action = Array::makei(horizon, j => steps[start + j].applied_action)
      let target = Array::makei(horizon, j => steps[start + j].next_state)
      guard state.all(row => row.all(@numeric.finite)) &&
        action.all(row => row.all(@numeric.finite)) &&
        target.all(row => row.all(@numeric.finite)) &&
        episode.context.all(@numeric.finite) else {
        abort("nonfinite replay data")
      }
      windows.push({
        state,
        action,
        target,
        context: episode.context,
        start_time_s: steps[start].time_s,
      })
    }
  }
  windows
}

///|
pub struct OnlineDynamics {
  model : Dynamics
  original : Array[Window]
  recent : Array[Window]
  optimizer : @numeric.Adam
  rng : @numeric.Rng
  capacity : Int32
  batch_size : Int32
  updates_per_round : Int32
  mut rounds : Int32
  mut optimizer_steps : Int32
}

///|
pub fn OnlineDynamics::new(
  model : Dynamics,
  original : Array[Window],
  capacity : Int32,
  batch_size : Int32,
  updates_per_round : Int32,
  learning_rate : Double,
  seed : UInt32,
) -> OnlineDynamics {
  guard original.length() > 0 &&
    capacity > 0 &&
    batch_size > 1 &&
    updates_per_round > 0 else {
    abort("invalid online replay configuration")
  }
  {
    model,
    original,
    recent: [],
    optimizer: @numeric.Adam::new(
      model.network.parameters.length(),
      learning_rate,
    ),
    rng: @numeric.Rng::new(seed),
    capacity,
    batch_size,
    updates_per_round,
    rounds: 0,
    optimizer_steps: 0,
  }
}

///|
pub struct OnlineUpdate {
  round : Int32
  optimizer_steps : Int32
  recent_windows : Int32
  training_loss : Double
} derive(Debug)

///|
pub fn OnlineDynamics::update(
  self : OnlineDynamics,
  episodes : Array[Episode],
  dt : Double,
) -> OnlineUpdate {
  let fresh = episode_windows(episodes, self.original[0].action.length(), dt)
  guard fresh.length() > 0 else { abort("no complete online windows") }
  self.recent.append(fresh)
  while self.recent.length() > self.capacity {
    ignore(self.recent.remove(0))
  }
  let mut loss = 0.0
  for _ in 0..<self.updates_per_round {
    let minibatch = Array::makei(self.batch_size, i => {
      if i < self.batch_size / 2 {
        self.original[self.rng.index(self.original.length())]
      } else {
        self.recent[self.rng.index(self.recent.length())]
      }
    })
    loss = self.model.update(self.optimizer, minibatch)
    self.optimizer_steps += 1
  }
  self.rounds += 1
  {
    round: self.rounds,
    optimizer_steps: self.optimizer_steps,
    recent_windows: self.recent.length(),
    training_loss: loss,
  }
}

///|
/// Python round() uses ties-to-even for the requested late-window count.
pub fn sampling_pools(
  times : Array[Double],
  batch_size : Int32,
  late_fraction : Double,
) -> (Array[Int32], Array[Int32], Int32) {
  guard late_fraction >= 0 && late_fraction <= 1 && batch_size > 0 else {
    abort("invalid late sampling fraction")
  }
  let early = []
  let late = []
  for i in 0..<times.length() {
    if times[i] < 2 {
      early.push(i)
    } else {
      late.push(i)
    }
  }
  let raw = batch_size.to_double() * late_fraction
  let base = raw.to_int()
  let remainder = raw - base.to_double()
  let count = if remainder > 0.5 || (remainder == 0.5 && base % 2 == 1) {
    base + 1
  } else {
    base
  }
  guard late_fraction == 0 ||
    (late.length() > 0 && (count == batch_size || early.length() > 0)) else {
    abort("late sampling needs requested pools")
  }
  (early, late, count)
}
