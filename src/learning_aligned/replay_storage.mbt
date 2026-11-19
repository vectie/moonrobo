///|
/// Primitive native arrays keep Float64 payloads unboxed. A slab is at most
/// 1024 records (1,927,168 payload bytes), independent of the environment count.
priv struct ReplaySlab {
  values : FixedArray[Double]
  indices : FixedArray[Int32]
  flags : FixedArray[Byte]
}

///|
let replay_slab_records : Int32 = 1024

///|
pub struct ReplayBuffer {
  capacity : Int32
  num_envs : Int32
  priv mut slabs : Array[ReplaySlab]
  priv mut rows : Int32
  priv mut ptr : Int32
  priv mut moved : Bool
}

///|
pub(all) struct ReplayStorageUsage {
  format : String
  logical_records : Int64
  allocated_records : Int64
  capacity_records : Int64
  logical_payload_bytes : Int64
  allocated_payload_bytes : Int64
  capacity_payload_bytes : Int64
  slab_count : Int32
  slab_records : Int32
} derive(Debug, ToJson)

///|
/// Payload accounting excludes array/record headers, the slab pointer directory,
/// transient sampled batches and allocator overhead; it is not process RSS.
/// ```mbt check
/// test {
///   let replay = ReplayBuffer::new(1000, 4096)
///   let usage = replay.storage_usage()
///   assert_eq(usage.allocated_payload_bytes, 0L)
///   assert_eq(usage.capacity_payload_bytes, 7708672000L)
/// }
/// ```
pub fn ReplayBuffer::storage_usage(self : ReplayBuffer) -> ReplayStorageUsage {
  let logical = self.rows.to_int64() * self.num_envs.to_int64()
  let allocated = self.slabs.fold(init=0L, (n, slab) => {
    n + (slab.values.length() / 234).to_int64()
  })
  let capacity = self.capacity.to_int64() * self.num_envs.to_int64()
  {
    format: "moonrobo.replay-f64-slab-storage.v1",
    logical_records: logical,
    allocated_records: allocated,
    capacity_records: capacity,
    logical_payload_bytes: logical * 1882L,
    allocated_payload_bytes: allocated * 1882L,
    capacity_payload_bytes: capacity * 1882L,
    slab_count: self.slabs.length(),
    slab_records: replay_slab_records,
  }
}

///|
pub fn ReplayBuffer::new(
  capacity : Int32,
  num_envs : Int32,
) -> ReplayBuffer raise {
  guard capacity > 0 &&
    num_envs > 0 &&
    capacity.to_int64() * num_envs.to_int64() <= 2147483647L / 234L else {
    fail(
      "replay dimensions must be positive and fit checked Int32 value indices",
    )
  }
  { capacity, num_envs, slabs: [], rows: 0, ptr: 0, moved: false, }
}

///|
pub fn ReplayBuffer::size(self : ReplayBuffer) -> Int32 {
  self.rows
}

///|
fn ReplayBuffer::ensure_records(self : ReplayBuffer, records : Int32) -> Unit {
  let total = self.capacity * self.num_envs
  let needed = (records + replay_slab_records - 1) / replay_slab_records
  while self.slabs.length() < needed {
    let count = (total - self.slabs.length() * replay_slab_records).min(
      replay_slab_records,
    )
    self.slabs.push({
      values: FixedArray::make(count * 234, 0.0),
      indices: FixedArray::make(count * 2, 0),
      flags: FixedArray::make(count * 2, b'\x00'),
    })
  }
}

///|
fn ReplayBuffer::record(self : ReplayBuffer, age : Int32, env : Int32) -> Int32 {
  (self.ptr - self.rows + age + self.capacity) % self.capacity * self.num_envs +
  env
}

///|
fn ReplayBuffer::value(
  self : ReplayBuffer,
  record : Int32,
  field : Int32,
) -> Double {
  self.slabs[record / replay_slab_records].values[record %
  replay_slab_records *
  234 +
  field]
}

///|
fn ReplayBuffer::index(
  self : ReplayBuffer,
  record : Int32,
  field : Int32,
) -> Int32 {
  self.slabs[record / replay_slab_records].indices[record %
  replay_slab_records *
  2 +
  field]
}

///|
fn ReplayBuffer::flag(
  self : ReplayBuffer,
  record : Int32,
  field : Int32,
) -> Byte {
  self.slabs[record / replay_slab_records].flags[record %
  replay_slab_records *
  2 +
  field]
}

///|
fn ReplayBuffer::transition(self : ReplayBuffer, record : Int32) -> Transition {
  let slab = self.slabs[record / replay_slab_records]
  let row = record % replay_slab_records
  let start = row * 234
  {
    s: Array::makei(71, i => slab.values[start + i]),
    s1: Array::makei(71, i => slab.values[start + 71 + i]),
    a: Array::makei(29, i => slab.values[start + 142 + i]),
    a_prev: Array::makei(29, i => slab.values[start + 171 + i]),
    xi: Array::makei(33, i => slab.values[start + 200 + i]),
    r: slab.values[start + 233],
    frame: slab.indices[row * 2],
    ep_step: slab.indices[row * 2 + 1],
    terminated: slab.flags[row * 2] == b'\x01',
    truncated: slab.flags[row * 2 + 1] == b'\x01',
  }
}

///|
fn ReplayBuffer::put(
  self : ReplayBuffer,
  record : Int32,
  tr : Transition,
) -> Unit {
  let slab = self.slabs[record / replay_slab_records]
  let row = record % replay_slab_records
  let start = row * 234
  for i in 0..<71 {
    slab.values[start + i] = tr.s[i]
    slab.values[start + 71 + i] = tr.s1[i]
  }
  for i in 0..<29 {
    slab.values[start + 142 + i] = tr.a[i]
    slab.values[start + 171 + i] = tr.a_prev[i]
  }
  for i in 0..<33 {
    slab.values[start + 200 + i] = tr.xi[i]
  }
  slab.values[start + 233] = tr.r
  slab.indices[row * 2] = tr.frame
  slab.indices[row * 2 + 1] = tr.ep_step
  slab.flags[row * 2] = if tr.terminated { b'\x01' } else { b'\x00' }
  slab.flags[row * 2 + 1] = if tr.truncated { b'\x01' } else { b'\x00' }
}

///|
fn replay_dimensions(tr : Transition) -> Unit raise {
  guard tr.s.length() == 71 &&
    tr.s1.length() == 71 &&
    tr.a.length() == 29 &&
    tr.a_prev.length() == 29 &&
    tr.xi.length() == 33 else {
    fail("invalid replay field dimensions")
  }
}

///|
pub fn ReplayBuffer::add(
  self : ReplayBuffer,
  row : Array[Transition],
) -> Unit raise {
  guard !self.moved && row.length() == self.num_envs else {
    fail("transition environment count differs or prepared replay was consumed")
  }
  // Validate the entire physical row before overwriting any environment slot.
  for tr in row {
    replay_dimensions(tr)
  }
  self.ensure_records((self.ptr + 1) * self.num_envs)
  for env, tr in row {
    self.put(self.ptr * self.num_envs + env, tr)
  }
  self.rows = (self.rows + 1).min(self.capacity)
  self.ptr = (self.ptr + 1) % self.capacity
}

///|
fn ReplayBuffer::continuous(self : ReplayBuffer, a : Int32, b : Int32) -> Bool {
  self.flag(a, 0) == b'\x00' &&
  self.flag(a, 1) == b'\x00' &&
  self.index(b, 1) == self.index(a, 1) + 1 &&
  self.index(b, 0) == self.index(a, 0) + 1
}

///|
/// Legacy v1 compatibility only. Live collection, sampling and v2 serialization
/// never construct this complete object graph.
pub fn ReplayBuffer::snapshot(self : ReplayBuffer) -> Array[Array[Transition]] {
  Array::makei(self.rows, age => {
    Array::makei(self.num_envs, env => self.transition(self.record(age, env)))
  })
}

///|
/// The legacy decoded array belongs to the caller. Validate then stage into
/// private primitive slabs, retaining only the last capacity rows as before.
pub fn ReplayBuffer::restore(
  self : ReplayBuffer,
  chronological : Array[Array[Transition]],
) -> Unit raise {
  guard !self.moved else { fail("prepared replay was consumed") }
  for row in chronological {
    guard row.length() == self.num_envs else {
      fail("incompatible replay checkpoint")
    }
  }
  let staged = ReplayBuffer::new(self.capacity, self.num_envs)
  for
    i in (chronological.length() - self.capacity).max(0)..<chronological.length() {
    staged.add(chronological[i])
  }
  self.commit_checkpoint_v2(staged)
}
