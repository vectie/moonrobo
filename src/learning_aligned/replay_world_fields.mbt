///|
/// Owned field-major buffers for one sampled world batch. This does not expose
/// replay slabs and preserves the decoded sampler's row order and RNG draws.
pub(all) struct WorldReplayFields {
  s : FixedArray[Double]
  s1 : FixedArray[Double]
  actions : FixedArray[Double]
  xi : FixedArray[Double]
  mask : FixedArray[Double]
}

///|
fn copy_replay_world_field(
  source : FixedArray[Double],
  offset : Int32,
  target : FixedArray[Double],
  target_offset : Int32,
  width : Int32,
) -> Unit raise {
  for i in 0..<width {
    let value = source[offset + i]
    guard !value.is_nan() && !value.is_inf() else {
      fail("GPU batch contains nonfinite values")
    }
    target[target_offset + i] = value
  }
}

///|
/// Copy only world-model fields directly from primitive replay slabs. Sampling
/// remains start,env for each window. Draw a whole decode-sized block before
/// checking its values, matching the legacy sampler's failure/RNG boundary.
/// The explicit value cap is validated before allocations or RNG consumption.
pub fn ReplayBuffer::sample_world_fields(
  self : ReplayBuffer,
  batch : Int32,
  width : Int32,
  random_index : (Int32) -> Int32,
  max_values~ : Int64,
) -> WorldReplayFields raise {
  guard !self.moved &&
    batch > 0 &&
    self.can_sample_windows(width) &&
    max_values > 0L &&
    batch.to_int64() * width.to_int64() <= max_values.min(2147483647L) / 205L else {
    fail("world field sampling dimensions exceed admitted bounds")
  }
  let rows = batch * width
  let fields : WorldReplayFields = {
    s: FixedArray::make(rows * 71, 0.0),
    s1: FixedArray::make(rows * 71, 0.0),
    actions: FixedArray::make(rows * 29, 0.0),
    xi: FixedArray::make(rows * 33, 0.0),
    mask: FixedArray::make(rows, 0.0),
  }
  for begin = 0; begin < batch; {
    let count = (batch - begin).min(256)
    let selected = FixedArray::make(count * 2, 0)
    for i in 0..<count {
      let start = random_index(self.size() - width + 1)
      let env = random_index(self.num_envs)
      guard start >= 0 &&
        start <= self.size() - width &&
        env >= 0 &&
        env < self.num_envs else {
        fail("invalid replay random index")
      }
      selected[2 * i] = start
      selected[2 * i + 1] = env
    }
    for i in 0..<count {
      let start = selected[2 * i]
      let env = selected[2 * i + 1]
      let mut valid = true
      let mut previous = 0
      for j in 0..<width {
        let record = self.record(start + j, env)
        let source = self.slabs[record / replay_slab_records].values
        let offset = record % replay_slab_records * 234
        let row = (begin + i) * width + j
        copy_replay_world_field(source, offset, fields.s, row * 71, 71)
        copy_replay_world_field(source, offset + 71, fields.s1, row * 71, 71)
        copy_replay_world_field(
          source,
          offset + 142,
          fields.actions,
          row * 29,
          29,
        )
        copy_replay_world_field(source, offset + 200, fields.xi, row * 33, 33)
        if j > 0 {
          valid = valid && self.continuous(previous, record)
        }
        fields.mask[row] = if valid { 1.0 } else { 0.0 }
        previous = record
      }
    }
    continue begin + count
  }
  fields
}
