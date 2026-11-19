///|
struct ResetStep {
  frame : Array[Int32]
  result : Array[Double] // per-env reward, done, fall, clip end, time-out
}

///|
pub struct GenReset {
  value : Array[Double]
  count : Array[Int32]
  effort : Array[Double]
  history : Array[ResetStep]
  frames : Int32
  envs : Int32
  vmax : Double
}

///|
pub fn GenReset::new(
  bins : Int32,
  frames : Int32,
  envs : Int32,
  dt : Double,
) -> GenReset raise {
  guard bins > 0 && bins <= frames && envs > 0 && dt > 0 else {
    fail("invalid reset sampler layout")
  }
  let vmax = 5.0 * dt / (1.0 - 0.99)
  {
    value: Array::make(bins, vmax),
    count: Array::make(bins, 0),
    effort: Array::make(bins, 0.0),
    history: [],
    frames,
    envs,
    vmax,
  }
}

///|
fn GenReset::bin(self : GenReset, t : Int32) -> Int32 {
  (t.to_int64() * self.value.length().to_int64() / self.frames.to_int64()).to_int()
}

///|
/// One sample per (environment, episode, bin), regardless of dwell time.
/// The return after a fall is zero. Clip completion bootstraps from mean V.
pub fn GenReset::record(
  self : GenReset,
  frames : Array[Int32],
  results : Array[Double],
) -> Array[Double]? raise {
  guard frames.length() == self.envs &&
    results.length() == self.envs * 5 &&
    frames.all(t => t >= 0 && t < self.frames) &&
    results.all(@numeric.finite) else {
    fail("invalid physical return records")
  }
  self.history.push({ frame: frames, result: results, })
  if self.history.length() < 20 {
    return None
  }
  let n = self.value.length()
  let mean = self.value.fold(init=0.0, (a, v) => a + v) / n.to_double()
  let bins : Map[Int32, (Double, Int32)] = {}
  for e in 0..<self.envs {
    let visits : Map[Int32, (Double, Int32)] = {}
    let flush = () => {
      for k, (sum, count) in visits {
        let (old, items) = bins.get(k).unwrap_or((0.0, 0))
        bins[k] = (old + sum / count.to_double(), items + 1)
      }
      visits.clear()
    }
    let mut next = 0.0
    for i in 0..<20 {
      let t = 19 - i
      let row = self.history[t]
      let time = row.frame[e]
      let j = e * 5
      let ended = row.result[j + 2] != 0.0 ||
        row.result[j + 3] != 0.0 ||
        row.result[j + 4] != 0.0
      if ended {
        flush()
      }
      if ended || t == 19 {
        next = if row.result[j + 2] != 0.0 {
          0.0
        } else if row.result[j + 3] != 0.0 {
          mean
        } else {
          self.value[self.bin((time + 1).min(self.frames - 1))]
        }
      }
      next = row.result[j] + 0.99 * next
      let k = self.bin(time)
      let (sum, count) = visits.get(k).unwrap_or((0.0, 0))
      visits[k] = (sum + next, count + 1)
    }
    flush()
  }
  self.history.clear()
  for k, (total, m) in bins {
    let count = self.count[k].min(256) + m
    self.value[k] += (total - m.to_double() * self.value[k]) / count.to_double()
    self.count[k] = count
  }
  let min_value = self.value.fold(init=self.value[0], (a, x) => a.min(x))
  let probabilities = self.value.map(x => {
    @math.exp(-25.0 * (x - min_value) / self.vmax)
  })
  let sum = probabilities.fold(init=0.0, (a, x) => a + x)
  let mut effort_sum = 0.0
  for i in 0..<n {
    let focus = probabilities[i] / sum
    probabilities[i] = focus
    self.effort[i] += focus * focus
    effort_sum += self.effort[i]
  }
  for i in 0..<n {
    probabilities[i] = 0.5 / n.to_double() +
      0.4 * probabilities[i] +
      0.1 * self.effort[i] / effort_sum
  }
  Some(probabilities)
}
