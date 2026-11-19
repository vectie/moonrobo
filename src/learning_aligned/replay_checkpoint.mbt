///|
pub(all) struct ReplayCheckpointV2 {
  format : String
  capacity : Int32
  num_envs : Int32
  rows : Int32
  values : @checkpoint_stream.BlobDescriptor
  indices : @checkpoint_stream.BlobDescriptor
  flags : @checkpoint_stream.BlobDescriptor
} derive(ToJson, FromJson)

///|
pub fn ReplayCheckpointV2::blobs(
  self : ReplayCheckpointV2,
) -> Array[@checkpoint_stream.BlobDescriptor] {
  [self.values, self.indices, self.flags]
}

///|
pub fn ReplayCheckpointV2::validate(
  self : ReplayCheckpointV2,
  capacity : Int32,
  num_envs : Int32,
) -> Unit raise {
  guard self.format == "moonrobo.replay-stream.v2" &&
    self.capacity == capacity &&
    self.num_envs == num_envs &&
    capacity > 0 &&
    num_envs > 0 &&
    self.rows >= 0 &&
    self.rows <= capacity &&
    self.rows.to_int64() * num_envs.to_int64() <= 2147483647L / 234L else {
    fail("invalid replay stream dimensions")
  }
  checkpoint_blob(self.values, "replay.values.f64le", "f64le", [
    self.rows,
    num_envs,
    234,
  ])
  checkpoint_blob(self.indices, "replay.indices.i32le", "i32le", [
    self.rows,
    num_envs,
    2,
  ])
  checkpoint_blob(self.flags, "replay.flags.u8", "u8", [self.rows, num_envs, 2])
}

///|
fn ReplayBuffer::chronological_record(
  self : ReplayBuffer,
  record : Int32,
) -> Int32 {
  self.record(record / self.num_envs, record % self.num_envs)
}

///|
/// Training is paused by the caller. Read existing rows in chronological order
/// without snapshotting or cloning the complete replay. Float64 bits are kept.
pub async fn ReplayBuffer::write_checkpoint_v2(
  self : ReplayBuffer,
  directory : String,
) -> ReplayCheckpointV2 {
  guard !self.moved else { fail("prepared replay was consumed") }
  let rows = self.size()
  let values = @checkpoint_stream.write_f64le(
    directory,
    "replay.values.f64le",
    [rows, self.num_envs, 234],
    (offset, count) => {
      Array::makei(count, i => {
        let flat = offset.to_int() + i
        let record = flat / 234
        self.value(self.chronological_record(record), flat % 234)
      })
    },
  )
  let indices = @checkpoint_stream.write_i32le(
    directory,
    "replay.indices.i32le",
    [rows, self.num_envs, 2],
    (offset, count) => {
      Array::makei(count, i => {
        let flat = offset.to_int() + i
        let record = flat / 2
        self.index(self.chronological_record(record), flat % 2)
      })
    },
  )
  let flags = @checkpoint_stream.write_u8(
    directory,
    "replay.flags.u8",
    [rows, self.num_envs, 2],
    (offset, count) => {
      Array::makei(count, i => {
        let flat = offset.to_int() + i
        let record = flat / 2
        self.flag(self.chronological_record(record), flat % 2)
      })
    },
  )
  {
    format: "moonrobo.replay-stream.v2",
    capacity: self.capacity,
    num_envs: self.num_envs,
    rows,
    values,
    indices,
    flags,
  }
}

///|
/// Decode into an isolated replay. The original buffer is untouched on any
/// metadata, hash, finite-value, episode or reference validation failure.
pub async fn ReplayBuffer::prepare_checkpoint_v2(
  self : ReplayBuffer,
  directory : String,
  saved : ReplayCheckpointV2,
  validate : (Transition) -> Unit raise,
) -> ReplayBuffer {
  guard !self.moved else { fail("prepared replay was consumed") }
  saved.validate(self.capacity, self.num_envs)
  // Reject absent/corrupt payloads before reserving a full isolated replay.
  // Each reader still verifies its own second pass against in-place changes.
  for blob in saved.blobs() {
    @checkpoint_stream.verify_blob(directory, blob)
  }
  let records = saved.rows * self.num_envs
  let staged = ReplayBuffer::new(self.capacity, self.num_envs)
  staged.ensure_records(records)
  // Sidecar consumers write only these isolated primitive slabs. Each reader
  // completes its second SHA pass before any business validation or live commit.
  @checkpoint_stream.read_i32le(directory, saved.indices, (offset, values) => {
    for i, value in values {
      let flat = offset.to_int() + i
      let record = flat / 2
      staged.slabs[record / replay_slab_records].indices[record %
      replay_slab_records *
      2 +
      flat % 2] = value
    }
  })
  @checkpoint_stream.read_u8(directory, saved.flags, (offset, values) => {
    for i, value in values {
      guard value == b'\x00' || value == b'\x01' else {
        fail("invalid replay terminal flags")
      }
      let flat = offset.to_int() + i
      let record = flat / 2
      staged.slabs[record / replay_slab_records].flags[record %
      replay_slab_records *
      2 +
      flat % 2] = value
    }
  })
  @checkpoint_stream.read_f64le(directory, saved.values, (offset, values) => {
    for i, value in values {
      guard @numeric.finite(value) else { fail("nonfinite replay value") }
      let flat = offset.to_int() + i
      let record = flat / 234
      staged.slabs[record / replay_slab_records].values[record %
      replay_slab_records *
      234 +
      flat % 234] = value
    }
  })
  for record in 0..<records {
    // At most one compatibility Transition is materialized for the callback.
    validate(staged.transition(record))
  }
  staged.rows = saved.rows
  staged.ptr = saved.rows % self.capacity
  staged
}

///|
/// Move verified slabs once. The consumed staging buffer cannot mutate or
/// republish the installed live storage; no second numeric replay is copied.
pub fn ReplayBuffer::commit_checkpoint_v2(
  self : ReplayBuffer,
  staged : ReplayBuffer,
) -> Unit raise {
  guard !physical_equal(self, staged) &&
    !self.moved &&
    !staged.moved &&
    self.capacity == staged.capacity &&
    self.num_envs == staged.num_envs else {
    fail("incompatible prepared replay")
  }
  self.slabs = staged.slabs
  self.rows = staged.rows
  self.ptr = staged.ptr
  staged.slabs = []
  staged.rows = 0
  staged.ptr = 0
  staged.moved = true
}
