///|
fn runtime_setup_signature(
  learner : @gpu.Learner,
  motion : @aligned.MotionLibrary,
  capacity : Int32,
  num_envs : Int32,
  seed : UInt32,
) -> String raise {
  guard motion.names.length() == motion.source_sha256.length() else {
    fail("motion catalog hash dimensions differ")
  }
  let hash = @crypto.SHA256::new()
  let setup : Json = {
    "config": Json(learner.config),
    "mode": mode_name(learner.mode),
    "capacity": capacity,
    "num_envs": num_envs,
    "seed": Json(seed),
    "source_fps": motion.source_fps,
    "frames": motion.states.length(),
    "bins": motion.bins.length(),
    "clips": motion.names.length(),
  }
  hash.update(@utf8.encode(setup.stringify()))
  for i, name in motion.names {
    hash.update(
      @utf8.encode(
        "\{name.length()}:" + name + ":" + motion.source_sha256[i] + "\n",
      ),
    )
  }
  @crypto.bytes_to_hex_string(hash.finalize())
}

///|
fn TrainingRunner::run_signature(
  self : TrainingRunner,
  options : @aligned.TrainingOptions,
) -> String {
  let data : Json = {
    "iteration": self.iteration,
    "step_accumulator": self.step_accumulator,
    "iterations": options.iterations,
    "warmup_steps": options.warmup_steps,
    "world_only_iterations": options.world_only_iterations,
    "utd": options.update_to_data,
    "lr_decay": options.learning_rate_decay_iterations,
    "action_noise": options.action_noise,
  }
  data.stringify()
}

///|
fn TrainingRunner::aggregate_metrics(
  self : TrainingRunner,
  local : IterationMetrics,
) -> IterationMetrics raise {
  if self.learner.collective is None {
    return local
  }
  let values = [local.world.wm_loss, local.world.wm_error_last]
  if local.policy is Some(p) {
    values.append([
      p.policy_loss,
      p.critic_loss,
      p.imagined_reward,
      p.imagined_survival,
    ])
  }
  let mean = self.learner.average_metrics(values)
  {
    ..local,
    world: { ..local.world, wm_loss: mean[0], wm_error_last: mean[1], },
    policy: local.policy.map(p => {
      ..p,
      policy_loss: mean[2],
      critic_loss: mean[3],
      imagined_reward: mean[4],
      imagined_survival: mean[5],
    }),
  }
}

///|
/// Same meaning as the preserved Python global counters: sum work over ranks;
/// synchronized optimizer update counts per rank remain in self.counters.
pub fn TrainingRunner::global_counters(
  self : TrainingRunner,
) -> TrainingCounters raise {
  let c = self.counters
  match self.learner.collective {
    None => { ..c, }
    Some(group) => {
      let values = group.control([
        c.physical_transitions,
        c.imagined_transitions,
        c.actor_updates,
        c.model_updates,
        c.critic_updates,
        c.model_fit_transition_slots,
      ])
      {
        physical_transitions: values[0],
        imagined_transitions: values[1],
        actor_updates: values[2],
        model_updates: values[3],
        critic_updates: values[4],
        model_fit_transition_slots: values[5],
      }
    }
  }
}

///|
pub(all) struct DistributedRankSnapshot {
  rank : Int32
  world_size : Int32
  collection_seed : UInt32
  exact_distributed_resume_supported : Bool
} derive(ToJson, FromJson)

///|
fn TrainingRunner::distributed_snapshot(
  self : TrainingRunner,
) -> DistributedRankSnapshot? {
  self.learner.collective.map(group => {
    rank: group.rank,
    world_size: group.world_size,
    collection_seed: self.collection_seed,
    exact_distributed_resume_supported: false,
  })
}

///|
pub(all) struct RankCheckpointPart {
  rank : Int32
  relative_pointer : String
  pointer_sha256 : String
} derive(ToJson, FromJson)

///|
pub(all) struct DistributedCheckpointManifest {
  format : String
  world_size : Int32
  iteration : Int32
  step_accumulator : Double
  run_identity_sha256 : String
  ranks : Array[RankCheckpointPart]
  resume_supported : Bool
} derive(ToJson, FromJson)

///|
fn valid_sha256(value : String) -> Bool {
  value.length() == 64 &&
  value.iter().all(c => (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f'))
}

///|
fn valid_generation(value : String, iteration : Int32) -> Bool {
  value.length() <= 128 &&
  value.has_prefix("generation-\{iteration}-") &&
  value[11:].iter().all(c => (c >= '0' && c <= '9') || c == '-')
}

///|
/// Call on every rank only after publishing its rank-N generation atomically.
/// Each immutable receipt names that rank's learner + optimizer + replay + RNG + physical
/// checkpoint. This receipt documents one consistent generation across ranks;
/// it does not enable unsupported distributed resume.
pub fn TrainingRunner::distributed_checkpoint_manifest(
  self : TrainingRunner,
  local_pointer_sha256 : String,
  run_identity_sha256 : String,
  local_generation : String,
) -> DistributedCheckpointManifest raise {
  guard self.learner.collective is Some(group) else {
    fail("distributed checkpoint manifest requires a communicator")
  }
  errdefer self.learner.abort_distributed()
  guard group.world_size >= 2 &&
    group.world_size <= 16 &&
    valid_sha256(local_pointer_sha256) &&
    valid_sha256(run_identity_sha256) &&
    valid_generation(local_generation, self.iteration) else {
    fail("invalid distributed checkpoint rank count, generation or SHA256")
  }
  self.learner.assert_same_signature("checkpoint identity", run_identity_sha256)
  let progress : Json = {
    "iteration": self.iteration,
    "step_accumulator": self.step_accumulator,
  }
  self.learner.assert_same_signature(
    "checkpoint progress",
    progress.stringify(),
  )
  let bytes = @utf8.encode(local_pointer_sha256)
  let generation = @utf8.encode(local_generation)
  let stride = 193
  let signatures = Array::makei(group.world_size * stride, i => {
    let slot = i % stride
    if i / stride != group.rank {
      0L
    } else if slot == 0 {
      generation.length().to_int64()
    } else if slot <= 64 {
      bytes[slot - 1].to_int().to_int64()
    } else if slot - 65 < generation.length() {
      generation[slot - 65].to_int().to_int64()
    } else {
      0L
    }
  })
  let gathered = group.control(signatures)
  let ranks : Array[RankCheckpointPart] = []
  for rank in 0..<group.world_size {
    let from = rank * stride
    let row = gathered[from + 1:from + 65]
    guard row.all(v => v >= 0L && v <= 127L) else {
      fail("invalid gathered checkpoint signature")
    }
    let pointer_sha256 = @utf8.decode(
      Bytes::makei(64, i => row[i].to_int().to_byte()),
    )
    let length = gathered[from]
    guard length > 0L && length <= 128L else {
      fail("invalid gathered generation length")
    }
    let chars = gathered[from + 65:from + 65 + length.to_int()]
    guard chars.all(v => v >= 0L && v <= 127L) else {
      fail("invalid gathered generation name")
    }
    let generation = @utf8.decode(
      Bytes::makei(chars.length(), i => chars[i].to_int().to_byte()),
    )
    guard valid_sha256(pointer_sha256) &&
      valid_generation(generation, self.iteration) else {
      fail("incomplete rank checkpoint manifest")
    }
    ranks.push({
      rank,
      relative_pointer: "rank-\{rank}/" + generation + "/receipt.json",
      pointer_sha256,
    })
  }
  {
    format: "moonrobo.native-tensor-distributed-checkpoint.v1",
    world_size: group.world_size,
    iteration: self.iteration,
    step_accumulator: self.step_accumulator,
    run_identity_sha256,
    ranks,
    resume_supported: false,
  }
}
