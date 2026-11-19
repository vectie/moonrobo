///|
/// Rank-specific host RNG seeds. The caller uses this for physics; runtime uses
/// it internally for collection/replay/noise. Pass the same base seed to ranks.
pub fn rank_seed(
  base : UInt32,
  collective : @tensor.Collective?,
) -> UInt32 raise {
  match collective {
    None => base
    Some(group) => {
      guard group.rank >= 0 && base <= 4294967295U - group.rank.to_uint() else {
        fail("distributed rank seed would overflow UInt32")
      }
      let seed = base + group.rank.to_uint()
      guard seed != 0x9E3779B9U else {
        fail("distributed seed maps to the reserved zero xorshift state")
      }
      seed
    }
  }
}

///|
/// Abort on any local failure so peers stop at the communicator's configured
/// deadline instead of entering further optimizer updates independently.
pub fn Learner::abort_distributed(self : Learner) -> Unit {
  if self.collective is Some(group) {
    group.close() catch {
      _ => ()
    }
  }
}

///|
pub fn Learner::assert_same_signature(
  self : Learner,
  label : String,
  signature : String,
) -> Unit raise {
  if self.collective is Some(group) {
    errdefer self.abort_distributed()
    let hash = @crypto.SHA256::new()
    hash.update(@utf8.encode(label + "\n" + signature))
    let bytes = hash.finalize()
    let values = Array::makei(bytes.length(), i => bytes[i].to_int().to_int64())
    let lo = group.control(values, op=Min)
    let hi = group.control(values, op=Max)
    guard lo == hi else { fail("distributed ranks disagree: " + label) }
  }
}

///|
/// Run a local staging operation on every rank, then agree on readiness before
/// any rank enters learner collectives. No rank silently skips an update.
pub fn[A] Learner::prepare_collective(
  self : Learner,
  label : String,
  prepare : () -> A raise,
) -> A raise {
  guard self.collective is Some(group) else { return prepare() }
  errdefer self.abort_distributed()
  let result : Result[A, String] = Ok(prepare()) catch {
    error => Err("\{error}")
  }
  let ok = match result {
    Ok(_) => 1L
    Err(_) => 0L
  }
  let ready = group.control([ok], op=Min)
  if ready != [1L] {
    match result {
      Err(message) =>
        fail("distributed stage failed locally: " + label + ": " + message)
      Ok(_) => fail("distributed peer failed before stage: " + label)
    }
  }
  match result {
    Ok(value) => value
    Err(message) => fail(message)
  }
}

///|
pub fn Learner::any_rank(self : Learner, value : Bool) -> Bool raise {
  match self.collective {
    None => value
    Some(group) => group.control([if value { 1L } else { 0L }], op=Max) == [1L]
  }
}

///|
/// Fresh learners only: optimizer states are empty. Distributed checkpoint load
/// is rejected until rank-manifest + optimizer-consistency restore is supported.
pub fn Learner::synchronize_initial_state(self : Learner) -> Unit raise {
  guard self.collective is Some(group) else { return }
  errdefer self.abort_distributed()
  self.assert_same_signature(
    "learner dimensions",
    self.config.to_json().stringify() + ":" + self.mode_name(),
  )
  for
    parameters in [
      self.world.net.parameters(),
      self.policy.parameters(),
      self.critic.net.parameters(),
    ] {
    for parameter in parameters {
      group.broadcast(parameter)
    }
  }
  for norm in self.normalizers() {
    group.broadcast(norm.mean)
    group.broadcast(norm.variance)
    let count = self.backend.from_values(
      [1],
      [norm.count],
      cuda_device=self.cuda_device,
      requires_grad=false,
      dtype=Float64,
    )
    group.broadcast(count)
    norm.count = count.values()[0]
  }
}

///|
/// Apply pooled sufficient statistics with the same population-variance update
/// as the preserved aligned Python implementation.
fn RunningNorm::merge_raw_moments(
  self : RunningNorm,
  sum : @tensor.Tensor,
  squares : @tensor.Tensor,
  n : Double,
) -> Unit raise {
  guard @numeric.finite(n) &&
    n >= 0.0 &&
    sum.shape() == [self.dim] &&
    squares.shape() == [self.dim] else {
    fail("invalid distributed running-normalizer moments")
  }
  if n == 0.0 {
    return
  }
  let mean = sum.affine(1.0 / n)
  let variance = squares.affine(1.0 / n).sub(mean.square()).relu()
  let total = self.count + n
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
/// Difficulty estimates synchronize between iterations. Completion counters and
/// RNG remain rank-local. Only a bounded chunk is uploaded at a time.
pub fn Learner::synchronize_sampler(
  self : Learner,
  sampler : @aligned.ReturnBinSampler,
) -> Unit raise {
  guard self.collective is Some(group) else { return }
  errdefer self.abort_distributed()
  self.assert_same_signature(
    "reset sampler dimensions",
    "\{sampler.returns.length()}:\{sampler.average.length()}",
  )
  guard sampler.returns.length() == sampler.average.length() else {
    fail("invalid sampler arrays")
  }
  for values in [sampler.returns, sampler.average] {
    for start = 0; start < values.length(); {
      let count = (values.length() - start).min(65536)
      let local = self.backend.from_values(
        [count],
        values[start:start + count].to_owned(),
        cuda_device=self.cuda_device,
        requires_grad=false,
        dtype=Float64,
      )
      let average = group
        .all_reduce(local)
        .affine(1.0 / group.world_size.to_double())
        .values()
      guard average.all(@numeric.finite) else {
        fail("nonfinite distributed sampler estimates")
      }
      for i, value in average {
        values[start + i] = value
      }
      continue start + count
    }
  }
}

///|
pub fn Learner::average_metrics(
  self : Learner,
  values : Array[Double],
) -> Array[Double] raise {
  match self.collective {
    None => values
    Some(group) => {
      let tensor = self.backend.from_values(
        [values.length()],
        values,
        cuda_device=self.cuda_device,
        requires_grad=false,
        dtype=Float64,
      )
      group
      .all_reduce(tensor)
      .affine(1.0 / group.world_size.to_double())
      .values()
    }
  }
}
