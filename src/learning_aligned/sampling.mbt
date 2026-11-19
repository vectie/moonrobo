///|
pub(all) struct ResetBin {
  start : Int32
  clip_end : Int32
} derive(Debug)

///|
pub struct ReturnBinSampler {
  gamma : Double
  g_max : Double
  bins : Array[ResetBin]
  returns : Array[Double]
  average : Array[Double]
  completed : Array[Int32]
}

///|
pub fn ReturnBinSampler::new(
  bins : Array[ResetBin],
  gamma~ : Double = 0.99,
  max_step_reward~ : Double = 0.1,
) -> ReturnBinSampler raise {
  guard !bins.is_empty() && gamma >= 0.0 && gamma < 1.0 && max_step_reward > 0.0 else {
    fail("invalid return sampler configuration")
  }
  {
    gamma,
    g_max: max_step_reward / (1.0 - gamma),
    bins: bins.copy(),
    returns: Array::make(bins.length(), 0.0),
    average: Array::make(bins.length(), 1.0 / bins.length().to_double()),
    completed: Array::make(bins.length(), 0),
  }
}

///|
pub fn ReturnBinSampler::probabilities(
  self : ReturnBinSampler,
  update_average~ : Bool = false,
) -> Array[Double] {
  let logits = self.returns.map(x => -25.0 * x / self.g_max)
  let max_logit = logits.fold(init=logits[0], (a, b) => a.max(b))
  let soft = logits.map(x => (x - max_logit).exp())
  let total = soft.fold(init=0.0, (a, b) => a + b)
  for i in 0..<soft.length() {
    soft[i] /= total
    if update_average {
      self.average[i] = 0.999 * self.average[i] + 0.001 * soft[i]
    }
  }
  let historical = self.average.fold(init=0.0, (a, b) => a + b)
  Array::makei(soft.length(), i => {
    0.5 / soft.length().to_double() +
    0.4 * soft[i] +
    0.1 * self.average[i] / historical
  })
}

///|
pub fn ReturnBinSampler::sample(
  self : ReturnBinSampler,
  n : Int32,
  uniform : () -> Double,
  min_remaining_steps~ : Int32 = 1,
  draw_batch? : (Array[Double], Int32) -> (Array[Int32], Array[Double]),
) -> Array[(Int32, Int32)] raise {
  guard n >= 0 && min_remaining_steps >= 1 else {
    fail("invalid reset batch or horizon")
  }
  if n == 0 {
    return []
  }
  let weights = self.probabilities(update_average=true)
  let ends = self.bins.map(b => {
    (b.start + 50).min(b.clip_end - min_remaining_steps + 1)
  })
  for i, b in self.bins {
    if ends[i] <= b.start {
      weights[i] = 0.0
    }
  }
  let total = weights.fold(init=0.0, (a, b) => a + b)
  guard total > 0.0 else { fail("no reset bin has enough remaining steps") }
  let fixed = match draw_batch {
    Some(draw) => {
      let (bins, offsets) = draw(weights.copy(), n)
      guard bins.length() == n &&
        offsets.length() == n &&
        bins.all(i => i >= 0 && i < weights.length() && weights[i] > 0.0) &&
        offsets.all(x => finite(x) && x >= 0.0 && x < 1.0) else {
        fail("invalid external multinomial/offset draw batch")
      }
      Some((bins, offsets))
    }
    None => None
  }
  Array::makei(n, sample => {
    let bin = match fixed {
      Some((bins, _)) => bins[sample]
      None => {
        let draw = uniform() * total
        let mut sum = 0.0
        let mut selected = weights.length() - 1
        for i, w in weights {
          sum += w
          if draw < sum {
            selected = i
            break
          }
        }
        selected
      }
    }
    let start = self.bins[bin].start
    let uniform_offset = match fixed {
      Some((_, offsets)) => offsets[sample]
      None => uniform()
    }
    let offset = (uniform_offset * (ends[bin] - start).to_double()).to_int()
    (start + offset, bin)
  })
}

///|
pub(all) struct CompletedEpisode {
  bin : Int32
  discounted_return : Double
  // All optional bootstrap fields are supplied together as a tuple.
  bootstrap : (Int32, Double, Bool)?
} derive(Debug)

///|
pub fn ReturnBinSampler::update(
  self : ReturnBinSampler,
  episodes : Array[CompletedEpisode],
) -> Unit raise {
  let sums = Array::make(self.bins.length(), 0.0)
  let counts = Array::make(self.bins.length(), 0)
  for ep in episodes {
    guard ep.bin >= 0 &&
      ep.bin < self.bins.length() &&
      finite(ep.discounted_return) else {
      fail("invalid completed-episode bin or return")
    }
    let mut value = ep.discounted_return
    if ep.bootstrap is Some((length, total, terminated)) {
      guard length > 0 && finite(total) else {
        fail("invalid completed episode length or return")
      }
      if !terminated {
        value += @math.pow(self.gamma, length.to_double()) *
          (total / length.to_double()) /
          (1.0 - self.gamma)
      }
    }
    sums[ep.bin] += value
    counts[ep.bin] += 1
  }
  for i, c in counts {
    if c > 0 {
      self.returns[i] = 0.8 * self.returns[i] + 0.2 * sums[i] / c.to_double()
    }
    self.completed[i] += c
  }
}

///|
fn finite(x : Double) -> Bool {
  !x.is_nan() && !x.is_inf()
}

///|
pub fn ReturnBinSampler::snapshot(
  self : ReturnBinSampler,
) -> (Array[Double], Array[Double], Array[Int32]) {
  (self.returns.copy(), self.average.copy(), self.completed.copy())
}

///|
pub fn ReturnBinSampler::restore(
  self : ReturnBinSampler,
  returns : Array[Double],
  average : Array[Double],
  completed : Array[Int32],
) -> Unit raise {
  let n = self.bins.length()
  guard returns.length() == n &&
    average.length() == n &&
    completed.length() == n else {
    fail("sampler checkpoint bin count differs")
  }
  for i in 0..<n {
    self.returns[i] = returns[i]
    self.average[i] = average[i]
    self.completed[i] = completed[i]
  }
}
