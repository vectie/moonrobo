///|
pub(all) struct RuntimeSnapshotV2 {
  format : String
  config : @aligned.LearnerConfig
  observation_mode : String
  source_fps : Double
  catalog_count : Int32
  catalog_digest : String
  catalog : @checkpoint_stream.BlobDescriptor
  capacity : Int32
  num_envs : Int32
  iteration : Int32
  step_accumulator : Double
  counters : TrainingCounters
  rng : UInt32
  history_lengths : @checkpoint_stream.BlobDescriptor
  history_values : @checkpoint_stream.BlobDescriptor
  replay : @aligned.ReplayCheckpointV2
  distributed : DistributedRankSnapshot?
} derive(ToJson, FromJson)

///|
pub fn RuntimeSnapshotV2::blobs(
  self : RuntimeSnapshotV2,
) -> Array[@checkpoint_stream.BlobDescriptor] {
  let result = [self.catalog, self.history_lengths, self.history_values]
  result.append(self.replay.blobs())
  result
}

///|
/// The only JSON sidecar is bounded catalog metadata, never numeric trajectories.
/// Its original byte SHA is catalog_digest; no second canonical hash is used.
fn catalog_bytes(motion : @aligned.MotionLibrary) -> Bytes raise {
  guard !motion.names.is_empty() &&
    motion.names.length() <= 200000 &&
    motion.names.length() == motion.source_sha256.length() else {
    fail("invalid checkpoint catalog")
  }
  let mut bound = 256L
  for i, name in motion.names {
    bound += @utf8.encode(Json(name).stringify()).length().to_int64() +
      @utf8.encode(Json(motion.source_sha256[i]).stringify())
      .length()
      .to_int64() +
      2L
    guard bound <= 67108864L else {
      fail("checkpoint catalog exceeds 64 MiB bound")
    }
  }
  let catalog : Json = {
    "format": "moonrobo.native-runtime-catalog.v2",
    "motion_names": Json(motion.names),
    "motion_sha256": Json(motion.source_sha256),
    "source_fps": Json(motion.source_fps),
  }
  let bytes = @utf8.encode(catalog.stringify() + "\n")
  guard bytes.length() <= 67108864 else {
    fail("checkpoint catalog exceeds bound")
  }
  bytes
}

///|
pub async fn TrainingRunner::write_snapshot_v2(
  self : TrainingRunner,
  directory : String,
) -> RuntimeSnapshotV2 {
  let bytes = catalog_bytes(self.motion)
  let catalog = @checkpoint_stream.write_u8(
    directory,
    "catalog.json",
    [bytes.length()],
    (offset, count) => Array::makei(count, i => bytes[offset.to_int() + i]),
  )
  let hist = self.learner.config.hist
  let dim = self.learner.mode.dim()
  for h in self.histories {
    guard h.is_empty() ||
      (
        h.length() == hist &&
        h.all(row => row.length() == dim && row.all(@numeric.finite))
      ) else {
      fail("invalid live observation history")
    }
  }
  let history_lengths = @checkpoint_stream.write_i32le(
    directory,
    "history.lengths.i32le",
    [self.num_envs],
    (offset, count) => {
      Array::makei(count, i => self.histories[offset.to_int() + i].length())
    },
  )
  let history_values = @checkpoint_stream.write_f64le(
    directory,
    "history.values.f64le",
    [self.num_envs, hist, dim],
    (offset, count) => {
      Array::makei(count, i => {
        let flat = offset.to_int() + i
        let h = self.histories[flat / (hist * dim)]
        if h.is_empty() {
          0.0
        } else {
          h[flat / dim % hist][flat % dim]
        }
      })
    },
  )
  let replay = self.replay.write_checkpoint_v2(directory)
  {
    format: "moonrobo-aligned-gpu-runtime-v2",
    config: self.learner.config,
    observation_mode: mode_name(self.learner.mode),
    source_fps: self.motion.source_fps,
    catalog_count: self.motion.names.length(),
    catalog_digest: catalog.sha256,
    catalog,
    capacity: self.capacity,
    num_envs: self.num_envs,
    iteration: self.iteration,
    step_accumulator: self.step_accumulator,
    counters: { ..self.counters, },
    rng: self.rng.state(),
    history_lengths,
    history_values,
    replay,
    distributed: self.distributed_snapshot(),
  }
}

///|
fn TrainingRunner::validate_snapshot_v2(
  self : TrainingRunner,
  saved : RuntimeSnapshotV2,
) -> Unit raise {
  guard self.learner.collective is None && saved.distributed is None else {
    fail("native distributed resume remains unsupported for stream-v2")
  }
  guard saved.format == "moonrobo-aligned-gpu-runtime-v2" &&
    Json(saved.config) == Json(self.learner.config) &&
    saved.observation_mode == mode_name(self.learner.mode) &&
    saved.source_fps == self.motion.source_fps &&
    saved.catalog_count == self.motion.names.length() &&
    saved.catalog_digest == saved.catalog.sha256 &&
    saved.catalog.byte_length > 0L &&
    saved.catalog.byte_length <= 67108864L &&
    saved.capacity == self.capacity &&
    saved.num_envs == self.num_envs &&
    saved.rng != 0U &&
    saved.iteration >= 0 &&
    @numeric.finite(saved.step_accumulator) &&
    saved.step_accumulator >= 0.0 &&
    saved.step_accumulator < 1.0 else {
    fail("incompatible stream-v2 runtime metadata")
  }
  let c = saved.counters
  guard c.physical_transitions >= 0L &&
    c.imagined_transitions >= 0L &&
    c.actor_updates >= 0L &&
    c.model_updates >= 0L &&
    c.critic_updates >= 0L &&
    c.model_fit_transition_slots >= 0L else {
    fail("negative stream-v2 runtime counter")
  }
  @aligned.checkpoint_blob(saved.catalog, "catalog.json", "u8", [
    saved.catalog.byte_length.to_int(),
  ])
  @aligned.checkpoint_blob(
    saved.history_lengths,
    "history.lengths.i32le",
    "i32le",
    [self.num_envs],
  )
  @aligned.checkpoint_blob(
    saved.history_values,
    "history.values.f64le",
    "f64le",
    [self.num_envs, self.learner.config.hist, self.learner.mode.dim()],
  )
  saved.replay.validate(self.capacity, self.num_envs)
}

///|
/// Fresh/paused runner only. Decode into an isolated replay and histories,
/// validate all sidecars, then install. Peak scratch includes one extra replay,
/// one extra history plus replay indices/flags and bounded codec chunks; the
/// CLI retains its original conservative admission guard. No full JSON replay.
pub struct RuntimeRestoreV2 {
  priv owner : TrainingRunner
  priv replay : @aligned.ReplayBuffer
  priv histories : Array[Array[Array[Double]]]
  priv iteration : Int32
  priv step_accumulator : Double
  priv counters : TrainingCounters
  priv rng : UInt32
  priv mut consumed : Bool
}

///|
/// Prepare before restoring the physical environment. File and business-rule
/// failures cannot modify runner state; the opaque token is tied to this runner.
pub async fn TrainingRunner::prepare_snapshot_v2(
  self : TrainingRunner,
  directory : String,
  saved : RuntimeSnapshotV2,
) -> RuntimeRestoreV2 {
  self.validate_snapshot_v2(saved)
  for blob in saved.blobs() {
    @checkpoint_stream.verify_blob(directory, blob)
  }
  let bytes = catalog_bytes(self.motion)
  let hash = @crypto.SHA256::new()
  hash.update(bytes)
  guard @crypto.bytes_to_hex_string(hash.finalize()) == saved.catalog_digest else {
    fail("stream-v2 motion catalog order/content differs")
  }
  let lengths = @aligned.checkpoint_read_i32(
    directory,
    saved.history_lengths,
    self.num_envs,
  )
  let hist = self.learner.config.hist
  let dim = self.learner.mode.dim()
  guard lengths.all(n => n == 0 || n == hist) else {
    fail("invalid history lengths")
  }
  let histories = Array::makei(self.num_envs, e => {
    Array::makei(lengths[e], _ => Array::make(dim, 0.0))
  })
  @checkpoint_stream.read_f64le(directory, saved.history_values, (
    offset,
    values,
  ) => {
    for i, value in values {
      guard @numeric.finite(value) else {
        fail("nonfinite observation history")
      }
      let flat = offset.to_int() + i
      let e = flat / (hist * dim)
      if lengths[e] == 0 {
        guard value == 0.0 else {
          fail("nonzero padding in empty observation history")
        }
      } else {
        histories[e][flat / dim % hist][flat % dim] = value
      }
    }
  })
  let replay = self.replay.prepare_checkpoint_v2(directory, saved.replay, tr => {
    validate_transition(tr, self.motion)
  })
  {
    owner: self,
    replay,
    histories,
    iteration: saved.iteration,
    step_accumulator: saved.step_accumulator,
    counters: { ..saved.counters, },
    rng: saved.rng,
    consumed: false,
  }
}

///|
/// Commit only after the matching physical restore has succeeded. A warm
/// physical restore consumes the same fully verified token but discards replay.
pub fn TrainingRunner::commit_snapshot_v2(
  self : TrainingRunner,
  staged : RuntimeRestoreV2,
  exact_physics_resume : Bool,
) -> Unit raise {
  guard physical_equal(self, staged.owner) && !staged.consumed else {
    fail("stream-v2 restore token belongs to another runner or was consumed")
  }
  // Everything above may fail; nothing above changes the live runner. Warm
  // restore still verifies/decodes the full replay before deliberately clearing.
  self.replay.commit_checkpoint_v2(
    if exact_physics_resume {
      staged.replay
    } else {
      @aligned.ReplayBuffer::new(self.capacity, self.num_envs)
    },
  )
  for i in 0..<self.num_envs {
    self.histories[i] = if exact_physics_resume {
      staged.histories[i]
    } else {
      []
    }
  }
  self.iteration = staged.iteration
  self.step_accumulator = staged.step_accumulator
  self.rng.set_state(staged.rng)
  let c = staged.counters
  self.counters.physical_transitions = c.physical_transitions
  self.counters.imagined_transitions = c.imagined_transitions
  self.counters.actor_updates = c.actor_updates
  self.counters.model_updates = c.model_updates
  self.counters.critic_updates = c.critic_updates
  self.counters.model_fit_transition_slots = c.model_fit_transition_slots
  staged.consumed = true
}

///|
/// Convenience form when the caller has already restored/validated physics.
/// For atomic generation loading use prepare, then physics, then commit.
pub async fn TrainingRunner::restore_v2(
  self : TrainingRunner,
  directory : String,
  saved : RuntimeSnapshotV2,
  exact_physics_resume : Bool,
) -> Unit {
  let staged = self.prepare_snapshot_v2(directory, saved)
  self.commit_snapshot_v2(staged, exact_physics_resume)
}
