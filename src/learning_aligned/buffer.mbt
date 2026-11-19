///|
pub(all) struct Transition {
  s : Array[Double]
  s1 : Array[Double]
  a : Array[Double]
  a_prev : Array[Double]
  xi : Array[Double]
  r : Double
  frame : Int32
  ep_step : Int32
  terminated : Bool
  truncated : Bool
} derive(Debug, ToJson, FromJson)

///|
pub fn Transition::done(self : Transition) -> Bool {
  self.terminated || self.truncated
}

///|
pub fn ReplayBuffer::can_sample_windows(self : ReplayBuffer, k : Int32) -> Bool {
  k > 0 && self.size() >= k
}

///|
pub(all) struct ReplayWindow {
  transitions : Array[Transition]
  mask : Array[Double]
} derive(Debug)

///|
fn contiguous(a : Transition, b : Transition) -> Bool {
  !a.done() && b.ep_step == a.ep_step + 1 && b.frame == a.frame + 1
}

///|
// Random draws are injected so callers can persist their own native RNG state.
pub fn ReplayBuffer::sample_windows(
  self : ReplayBuffer,
  batch : Int32,
  k : Int32,
  random_index : (Int32) -> Int32,
) -> Array[ReplayWindow] raise {
  guard self.can_sample_windows(k) && batch > 0 else {
    fail("insufficient replay or invalid batch")
  }
  Array::makei(batch, _ => {
    let start = random_index(self.size() - k + 1)
    let env = random_index(self.num_envs)
    let transitions = Array::makei(k, j => {
      self.transition(self.record(start + j, env))
    })
    let mask = Array::make(k, 1.0)
    for j in 1..<k {
      mask[j] = if contiguous(transitions[j - 1], transitions[j]) {
        mask[j - 1]
      } else {
        0.0
      }
    }
    { transitions, mask, }
  })
}

///|
pub(all) struct ReplayStart {
  start : Transition
  history : Array[Transition]
} derive(Debug)

///|
pub(all) struct ActorReadiness {
  initial_candidates : Int32
  candidates : Int32
  replay_rows : Int32
  horizon : Int32
  max_remaining_steps : Int32
  extra_collection_steps : Int32
  extra_physical_transitions : Int64
  collection_step_budget : Int32
} derive(Debug, ToJson)

///|
/// Count only starts with H future transitions inside the same reference clip.
/// This is the condition in smc sample_valid_starts; history padding is separate.
pub fn ReplayBuffer::actor_start_count(
  self : ReplayBuffer,
  clip_end : (Int32) -> Int32,
  horizon : Int32,
) -> (Int32, Int32) raise {
  guard horizon > 0 else { fail("actor horizon must be positive") }
  let mut candidates = 0
  let mut longest = 0
  for age in 0..<self.size() {
    for env in 0..<self.num_envs {
      let frame = self.index(self.record(age, env), 0)
      let end = clip_end(frame)
      guard frame >= 0 && end >= frame else {
        fail("actor replay frame lies outside its reference clip")
      }
      let remaining = end - frame
      longest = longest.max(remaining)
      if remaining >= horizon {
        candidates += 1
      }
    }
  }
  (candidates, longest)
}

///|
/// Refill only when an actor update has no valid starts. The fixed budget is
/// max(replay capacity, H) vector steps, in chunks no larger than the model
/// window. All ranks must supply the same any_need reduction and chunk size.
/// Existing reset probabilities, clip membership and valid-start rule remain
/// unchanged. Added collection reduces the effective update/data ratio.
pub fn ReplayBuffer::ensure_actor_ready(
  self : ReplayBuffer,
  clip_end : (Int32) -> Int32,
  horizon : Int32,
  chunk_steps : Int32,
  collect : (Int32) -> Unit raise,
  any_need~ : (Bool) -> Bool raise = x => x,
  after_collect~ : () -> Unit raise = () => (),
  context~ : String = "",
) -> ActorReadiness raise {
  guard chunk_steps > 0 && chunk_steps <= self.capacity else {
    fail("actor refill chunk must be positive and fit replay capacity")
  }
  let (initial, _) = self.actor_start_count(clip_end, horizon)
  let budget = self.capacity.max(horizon)
  let mut added = 0
  for ;; {
    let (candidates, longest) = self.actor_start_count(clip_end, horizon)
    let report : ActorReadiness = {
      initial_candidates: initial,
      candidates,
      replay_rows: self.size(),
      horizon,
      max_remaining_steps: longest,
      extra_collection_steps: added,
      extra_physical_transitions: added.to_int64() * self.num_envs.to_int64(),
      collection_step_budget: budget,
    }
    // The collective decision precedes budget failure on every rank, including
    // a locally-ready rank whose peer still cannot supply an actor start.
    if !any_need(candidates == 0) {
      return report
    }
    guard added < budget else {
      fail(
        "actor readiness exhausted finite collection budget; a local or peer replay has no complete imagination horizon: " +
        report.to_json().stringify() +
        "; " +
        context,
      )
    }
    let steps = chunk_steps.min(budget - added)
    collect(steps)
    added += steps
    after_collect()
    continue
  }
}

///|
pub fn ReplayBuffer::sample_starts(
  self : ReplayBuffer,
  batch : Int32,
  hist : Int32,
  random_index : (Int32) -> Int32,
  clip_end? : (Int32) -> Int32,
  horizon~ : Int32 = 0,
) -> Array[ReplayStart] raise {
  guard self.size() > 0 && batch > 0 && hist > 0 else {
    fail("nonempty replay and positive batch/history required")
  }
  // One primitive Int32 per possible start, no per-candidate tuple/object.
  // The old age-major/env-minor order and every random_index call are retained.
  let candidates = FixedArray::make(self.size() * self.num_envs, 0)
  let mut count = 0
  for age in 0..<self.size() {
    for env in 0..<self.num_envs {
      let frame = self.index(self.record(age, env), 0)
      let valid = match clip_end {
        None => true
        Some(end) => horizon <= end(frame) - frame
      }
      if valid {
        candidates[count] = age * self.num_envs + env
        count += 1
      }
    }
  }
  guard count > 0 else { fail("no complete imagination horizon") }
  Array::makei(batch, _ => {
    let chosen = candidates[random_index(count)]
    let age = chosen / self.num_envs
    let env = chosen % self.num_envs
    let history = [self.transition(self.record(age, env))]
    let mut cursor = age
    let mut active = true
    for _ in 1..<hist {
      let prior = (cursor - 1).max(0)
      active = active &&
        cursor > 0 &&
        self.continuous(self.record(prior, env), self.record(cursor, env))
      if active {
        cursor = prior
      }
      history.push(self.transition(self.record(cursor, env)))
    }
    {
      start: self.transition(self.record(age, env)),
      history: Array::makei(hist, i => history[hist - 1 - i]),
    }
  })
}
