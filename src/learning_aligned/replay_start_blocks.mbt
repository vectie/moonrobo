///|
// Selection is a separate call frame so the candidate directory is released
// before the first compatibility Transition is decoded. The retained result
// is exactly one primitive Int32 age/env index per logical sample.
fn ReplayBuffer::select_start_indices(
  self : ReplayBuffer,
  batch : Int32,
  random_index : (Int32) -> Int32,
  clip_end : ((Int32) -> Int32)?,
  horizon : Int32,
) -> FixedArray[Int32] raise {
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
  FixedArray::makei(batch, _ => candidates[random_index(count)])
}

///|
fn ReplayBuffer::decode_start_block(
  self : ReplayBuffer,
  indices : FixedArray[Int32],
  begin : Int32,
  count : Int32,
  hist : Int32,
) -> Array[ReplayStart] {
  Array::makei(count, i => {
    let chosen = indices[begin + i]
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
      history: Array::makei(hist, j => history[hist - 1 - j]),
    }
  })
}

///|
/// Fix every sample index before calling `consume`, then decode at most 256
/// starts at a time. Candidate ordering, one draw per sample, terminal/history
/// padding and Float64 field copying match `sample_starts` exactly.
///
/// `consume` is synchronous and must not mutate this replay or retain the
/// starts/history objects after returning. Under that contract at most
/// `min(batch, 256) * (hist + 1)` compatibility Transitions are live. The full
/// selected-index FixedArray remains until all blocks finish (4*batch payload
/// bytes); the candidate directory is released before decoding begins.
///
/// ```mbt check
/// test "actor block API empty replay fails before consuming" {
///   let replay = ReplayBuffer::new(1, 1)
///   let mut consumed = false
///   try
///     replay.with_sampled_start_blocks(257, 10, _ => 0, _ => consumed = true)
///   catch {
///     _ => assert_false(consumed)
///   } noraise {
///     _ => fail("empty replay must be rejected")
///   }
/// }
/// ```
pub fn ReplayBuffer::with_sampled_start_blocks(
  self : ReplayBuffer,
  batch : Int32,
  hist : Int32,
  random_index : (Int32) -> Int32,
  consume : (Array[ReplayStart]) -> Unit raise,
  clip_end? : (Int32) -> Int32,
  horizon~ : Int32 = 0,
) -> Unit raise {
  guard self.size() > 0 && batch > 0 && hist > 0 else {
    fail("nonempty replay and positive batch/history required")
  }
  let indices = self.select_start_indices(
    batch, random_index, clip_end, horizon,
  )
  for begin = 0; begin < batch; {
    let count = (batch - begin).min(256)
    // No decoded array is captured by the next iteration or by this method.
    consume(self.decode_start_block(indices, begin, count, hist))
    continue begin + count
  }
}
