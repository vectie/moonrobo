///|
/// Keep the return recursion, grouped reductions and reset distribution in the
/// author's dtypes. Only discrete frame, episode and bin IDs are built on CPU.
pub struct DeviceReset {
  frames : Int32
  envs : Int32
  bins : Int32
  ceiling : Double
  mut value : @tensor.Tensor
  mut count : @tensor.Tensor
  mut effort : @tensor.Tensor
  history : Array[(Array[Int32], Array[Double], @tensor.Tensor)]
}

///|
pub fn DeviceReset::new(
  like : @tensor.Tensor,
  bins : Int32,
  frames : Int32,
  envs : Int32,
  dt : Double,
) -> DeviceReset raise {
  guard bins > 0 &&
    bins <= frames &&
    envs > 0 &&
    envs <= 2147483647 / 20 &&
    dt > 0.0 &&
    like.dtype() == Float32 else {
    fail("invalid device reset layout")
  }
  let zeros = like.new_zeros([bins])
  let ceiling = 5.0 * dt / (1.0 - 0.99)
  {
    frames,
    envs,
    bins,
    ceiling,
    value: zeros.affine(1.0, bias=ceiling),
    count: zeros,
    effort: zeros.cast_float(Float64),
    history: [],
  }
}

///|
pub fn DeviceReset::record(
  self : DeviceReset,
  times : Array[Int32],
  results : Array[Double],
  physical : @tensor.Tensor,
) -> @tensor.Tensor? raise {
  guard times.length() == self.envs &&
    times.all(i => i >= 0 && i < self.frames) &&
    results.length() == 5 * self.envs &&
    physical.shape() == [self.envs, 5] else {
    fail("invalid device reset batch")
  }
  self.history.push((times, results, physical))
  if self.history.length() < 20 {
    return None
  }
  let n = self.envs
  let bin = (frame : Int32) => {
    frame.to_int64() * self.bins.to_int64() / self.frames.to_int64()
  }
  // These keys have the same ordering as torch.unique(sorted=True).
  let keys = Array::make(n * 20, 0L)
  let after = Array::make(n * 20, 0.0)
  let groups : Map[Int64, Int32] = {}
  for e in 0..<n {
    let mut episode = 0
    for i in 0..<20 {
      let (frames, row, _) = self.history[i]
      let key = (e * 20 + episode).to_int64() * self.bins.to_int64() +
        bin(frames[e])
      keys[e * 20 + i] = key
      groups[key] = groups.get(key).unwrap_or(0) + 1
      after[e * 20 + i] = bin((frames[e] + 1).min(self.frames - 1)).to_double()
      if row[e * 5 + 2] != 0.0 || row[e * 5 + 3] != 0.0 || row[e * 5 + 4] != 0.0 {
        episode += 1
      }
    }
  }
  let unique = groups.keys().collect()
  unique.sort()
  let inverse : Map[Int64, Int32] = {}
  for i, key in unique {
    inverse[key] = i
  }
  let b = self.value.backend
  let put = (data : Array[Double], dtype : @tensor.DType) => {
    b.from_values(
      [data.length()],
      data,
      cuda_device=self.value.cuda_device(),
      requires_grad=false,
      dtype~,
    )
  }
  let group_ids = put(keys.map(k => inverse[k].to_double()), Int64)
  let group_bins = put(
    unique.map(k => (k % self.bins.to_int64()).to_double()),
    Int64,
  )
  let visits = put(unique.map(k => groups[k].to_double()), Float32)
  let packed = b.stack(self.history.map(entry => entry.2), axis=1)
  self.history.clear()
  let field = (j : Int32) => packed.narrow(2, j, 1).reshape([n, 20])
  let zeros = self.value.new_zeros([1])
  let fall = field(2).greater(zeros)
  let end_ = field(3).greater(zeros)
  let done_ = field(2).add(field(3)).add(field(4)).greater(zeros)
  let next_value = fall.select_where(
    zeros,
    end_.select_where(
      self.value.mean(),
      self.value.index_select(put(after, Int64)).reshape([n, 20]),
    ),
  )
  let reward = field(0)
  let mut next = next_value.narrow(1, 19, 1)
  let returns = []
  for i in 0..<20 {
    let t = 19 - i
    next = done_.narrow(1, t, 1).select_where(next_value.narrow(1, t, 1), next)
    next = reward.narrow(1, t, 1).add(next.affine(0.99))
    returns.push(next)
  }
  returns.rev_in_place()
  let samples = b
    .concat(returns, axis=1)
    .reshape([-1])
    .group_sum(group_ids, unique.length())
    .div(visits)
  let new_count = visits.affine(0.0, bias=1.0).group_sum(group_bins, self.bins)
  let total = samples.group_sum(group_bins, self.bins)
  self.count = self.count.clamp(0.0, 256.0).add(new_count)
  self.value = new_count
    .greater(zeros)
    .select_where(
      self.value.add(total.sub(new_count.mul(self.value)).div(self.count)),
      self.value,
    )
  let focus = self.value
    .affine(-25.0)
    .div(zeros.affine(0.0, bias=self.ceiling))
    .softmax0()
  self.effort = self.effort.add(focus.cast_float(Float64).square())
  let keep = self.effort.div(self.effort.sum()).cast_float(Float32)
  Some(
    focus.affine(0.4, bias=0.5 / self.bins.to_double()).add(keep.affine(0.1)),
  )
}
