///|
/// Pure per-rank diagnostics. These counts do not authorize a larger runtime
/// profile or replace the CLI's existing host/CUDA/cgroup admission checks.
pub(all) struct Inputs {
  capacity : Int32
  environments : Int32
  storage : @aligned.ReplayStorageUsage
  next_collection_steps : Int32
  restore_rows : Int32
  learner : @aligned.LearnerConfig
  observation_mode : String
  sampler_bins : Int32
  catalog_json_bytes : Int64
  state_json_bytes : Int64
  // Sum of physical numeric sidecars, excluding the three sampler sidecars.
  environment_payload_bytes : Int64
  // Sum of the actual three .pt sizes, if known. None is explicitly unmeasured.
  optimizer_archive_bytes : Int64?
  isaac : Bool
  distributed : Bool
} derive(ToJson)

///|
pub(all) struct SlabProjection {
  rows : Int32
  logical_records : Int64
  allocated_records : Int64
  slab_count : Int64
  logical_payload_bytes : Int64
  allocated_payload_bytes : Int64
  // Headers, directory growth and allocator allowance, NOT measured RSS.
  metadata_allowance_bytes : Int64
} derive(Debug, ToJson)

///|
pub(all) struct Phase {
  components : Map[String, Int64]
  envelope_bytes : Int64
} derive(ToJson)

///|
pub(all) struct SidecarProjection {
  replay_payload_bytes : Int64
  history_payload_bytes : Int64
  sampler_payload_bytes : Int64
  environment_payload_bytes : Int64
  catalog_json_bytes : Int64
  state_json_bytes : Int64
  total_bytes : Int64
  retained_total_limit_bytes : Int64
  fits_retained_total_limit : Bool
} derive(ToJson)

///|
pub(all) struct Plan {
  format : String
  diagnostic_only : Bool
  admission_eligible : Bool
  checkpoint_format : String
  storage_format : String
  accounting_scope : String
  inputs : Inputs
  current : SlabProjection
  after_collection : SlabProjection
  capacity : SlabProjection
  restoring : SlabProjection
  next_collection_growth_payload_bytes : Int64
  maximum_slab_payload_bytes : Int64
  exact_counts : Map[String, Int64]
  legacy_replay_json_envelope_bytes : Int64
  archive_envelope_basis_bytes : Int64
  archive_basis_source : String
  train_after_collection : Phase
  train_at_capacity : Phase
  save_at_capacity : Phase
  restore_into_current : Phase
  restore_at_capacity : Phase
  saved_sidecars : SidecarProjection
  capacity_sidecars : SidecarProjection
  uncalibrated : Array[String]
} derive(ToJson)

///|
const GiB : Int64 = 1073741824L

///|
fn add(a : Int64, b : Int64) -> Int64 raise {
  guard a >= 0L && b >= 0L && a <= 9223372036854775807L - b else {
    fail("replay memory diagnostic byte sum overflow or negative input")
  }
  a + b
}

///|
fn mul(a : Int64, b : Int64) -> Int64 raise {
  guard a >= 0L && b >= 0L && (b == 0L || a <= 9223372036854775807L / b) else {
    fail("replay memory diagnostic byte product overflow or negative input")
  }
  a * b
}

///|
fn sum(values : Array[Int64]) -> Int64 raise {
  values.fold(init=0L, add)
}

///|
fn projection(
  capacity : Int32,
  environments : Int32,
  rows : Int32,
) -> SlabProjection raise {
  guard capacity > 0 && environments > 0 && rows >= 0 && rows <= capacity else {
    fail("invalid replay memory projection dimensions")
  }
  let total = mul(capacity.to_int64(), environments.to_int64())
  // Same index ceiling as ReplayBuffer::new, independently of CLI profile caps.
  guard total <= 2147483647L / 234L else {
    fail("replay memory projection exceeds current slab indexing contract")
  }
  let records = mul(rows.to_int64(), environments.to_int64())
  let allocated = mul((records + 1023L) / 1024L, 1024L).min(total)
  let slabs = (allocated + 1023L) / 1024L
  {
    rows,
    logical_records: records,
    allocated_records: allocated,
    slab_count: slabs,
    logical_payload_bytes: mul(records, 1882L),
    allocated_payload_bytes: mul(allocated, 1882L),
    // 256/slab covers the four headers plus a growing directory allowance.
    // Retain a 4 KiB base; this allowance is explicitly uncalibrated.
    metadata_allowance_bytes: add(4096L, mul(slabs, 256L)),
  }
}

///|
fn validate_storage(
  i : Inputs,
  p : SlabProjection,
  full : SlabProjection,
) -> Unit raise {
  let s = i.storage
  guard s.format == "moonrobo.replay-f64-slab-storage.v1" &&
    s.slab_records == 1024 &&
    s.logical_records == p.logical_records &&
    s.allocated_records == p.allocated_records &&
    s.capacity_records == full.logical_records &&
    s.logical_payload_bytes == p.logical_payload_bytes &&
    s.allocated_payload_bytes == p.allocated_payload_bytes &&
    s.capacity_payload_bytes == full.logical_payload_bytes &&
    s.slab_count.to_int64() == p.slab_count else {
    fail("replay storage usage does not match the known F64 slab layout")
  }
}

///|
fn mlp(
  input : Int64,
  hidden : Array[Int32],
  output : Int64,
  norm : Bool,
) -> Int64 raise {
  guard input > 0L && output > 0L && hidden.all(x => x > 0) else {
    fail("positive model dimensions required for replay memory diagnostic")
  }
  let mut count = 0L
  let mut previous = input
  for width in hidden {
    let w = width.to_int64()
    count = add(count, mul(add(previous, 1L), w))
    if norm {
      count = add(count, mul(2L, w))
    }
    previous = w
  }
  add(count, mul(add(previous, 1L), output))
}

///|
fn phase(
  common : Map[String, Int64],
  extra : Map[String, Int64],
) -> Phase raise {
  let components = common.copy()
  for name, value in extra {
    guard !components.contains(name) else {
      fail("duplicate replay memory component")
    }
    components[name] = value
  }
  let mut total = 0L
  for _, value in components {
    total = add(total, value)
  }
  { components, envelope_bytes: total, }
}

///|
fn replay_components(p : SlabProjection) -> Map[String, Int64] {
  {
    "live_replay_primitive_payload": p.allocated_payload_bytes,
    "live_replay_metadata_allowance_uncalibrated": p.metadata_allowance_bytes,
  }
}

///|
fn sidecars(
  i : Inputs,
  rows : SlabProjection,
  history : Int64,
  sampler : Int64,
) -> SidecarProjection raise {
  let total = sum([
    rows.logical_payload_bytes,
    history,
    sampler,
    i.environment_payload_bytes,
    i.catalog_json_bytes,
    i.state_json_bytes,
  ])
  {
    replay_payload_bytes: rows.logical_payload_bytes,
    history_payload_bytes: history,
    sampler_payload_bytes: sampler,
    environment_payload_bytes: i.environment_payload_bytes,
    catalog_json_bytes: i.catalog_json_bytes,
    state_json_bytes: i.state_json_bytes,
    total_bytes: total,
    retained_total_limit_bytes: 536870912L,
    fits_retained_total_limit: total <= 536870912L,
  }
}

///|
/// Diagnose only the stream-v2 + primitive F64 slab path. The unchanged CLI
/// planner/publisher must still approve every execution, including v1 saves.
/// All arithmetic is checked before a plan is returned; no tensors, files,
/// histories or full-capacity replay are allocated by this function.
pub fn diagnose_stream_v2(i : Inputs) -> Plan raise {
  let c = i.learner
  guard i.environments > 0 &&
    i.next_collection_steps >= 0 &&
    i.storage.logical_records >= 0L &&
    i.storage.logical_records % i.environments.to_int64() == 0L &&
    i.storage.logical_records / i.environments.to_int64() <=
    i.capacity.to_int64() &&
    c.hist > 0 &&
    c.horizon > 0 &&
    c.goal_frames > 0 &&
    c.wm_window > 0 &&
    c.wm_batch > 0 &&
    c.policy_batch > 0 &&
    c.critic_epochs > 0 &&
    i.sampler_bins > 0 &&
    i.catalog_json_bytes > 0L &&
    i.catalog_json_bytes <= 67108864L &&
    i.state_json_bytes > 0L &&
    i.state_json_bytes <= 4194304L &&
    i.environment_payload_bytes >= 0L else {
    fail("invalid compact replay diagnostic input or metadata bound")
  }
  let current_rows = (i.storage.logical_records / i.environments.to_int64()).to_int()
  let current = projection(i.capacity, i.environments, current_rows)
  let capacity = projection(i.capacity, i.environments, i.capacity)
  validate_storage(i, current, capacity)
  let after_rows = add(
      current_rows.to_int64(),
      i.next_collection_steps.to_int64(),
    )
    .min(i.capacity.to_int64())
    .to_int()
  let after_collection = projection(i.capacity, i.environments, after_rows)
  let restoring = projection(i.capacity, i.environments, i.restore_rows)
  let n = i.environments.to_int64()
  let h = c.horizon.to_int64()
  let hist = c.hist.to_int64()
  let mode : @aligned.ObservationMode = match i.observation_mode {
    "paper" => @aligned.Paper
    "smc" => @aligned.Smc
    "observable" => @aligned.Observable
    _ => fail("unsupported observation mode in replay memory diagnostic")
  }
  let dim = mode.dim().to_int64()
  let goal = mul(c.goal_frames.to_int64(), 73L)
  let bw = c.wm_batch.to_int64()
  let bp = c.policy_batch.to_int64()
  let ww = c.wm_window.to_int64()
  let params = sum([
    mlp(133L, c.wm_hidden, 70L, true),
    mlp(goal, c.policy_hidden, 32L, false),
    mlp(add(32L, mul(dim, hist)), c.policy_hidden, 29L, false),
    mlp(add(184L, goal), c.critic_hidden, 1L, false),
  ])
  let history_bytes = mul(mul(n, hist), mul(dim, 8L))
  let sampler_bytes = mul(i.sampler_bins.to_int64(), 20L)
  let world_records = mul(bw, ww)
  // Padded history can share objects; H+1 counts the worst distinct transition
  // objects retained by starts + histories, never a whole replay snapshot.
  let actor_records = mul(bp, add(hist, 1L))
  let sample_records = world_records.max(actor_records).max(n)
  let world_values = mul(world_records, 205L)
  let policy_float_values = mul(
    bp,
    sum([
      133L,
      mul(hist, dim),
      mul(add(h, 1L), add(71L, goal)),
      if c.observation_noise {
        mul(h, dim)
      } else {
        0L
      },
    ]),
  )
  let order_values = mul(mul(bp, h), c.critic_epochs.to_int64())
  let collection_values = mul(n, sum([205L, mul(dim, add(hist, 1L)), goal]))
  // Array[Double] -> FixedArray[Double] -> LibTorch CPU F64 -> converted CPU
  // dtype -> CUDA tensor coexist during upload: 32 B/F32 or 40 B/I64 value.
  // Add a full F32 output for concat; blocks are 256 starts but final tensors
  // still span B. Counting every input simultaneously is conservative.
  let upload_payload = sum([
    mul(world_values, 32L),
    mul(policy_float_values, 36L),
    mul(order_values, 40L),
    mul(collection_values, 32L),
  ])
  let archive_basis = match i.optimizer_archive_bytes {
    Some(bytes) => {
      guard bytes > 0L else { fail("measured archive bytes must be positive") }
      bytes.max(mul(params, 16L))
    }
    None => mul(params, 16L)
  }
  // Preserve the established audit 6x + 1 GiB allowance. LibTorch serialization
  // is opaque; neither this nor header allowances are certified upper bounds.
  let archive_work = add(mul(archive_basis, 6L), GiB)
  let common : Map[String, Int64] = {
    "bounded_reference_catalog_and_construction_retained": 4L * GiB,
    "parameters_gradients_adam_allocator_retained": add(
      mul(params, 16L),
      GiB / 2L,
    ),
    "history_and_live_environment_retained": add(
      history_bytes,
      mul(n, 1048576L),
    ),
    "sampler_live_primitive_payload": sampler_bytes,
    "actor_bptt_envelope_retained": mul(mul(h, bp), 262144L),
    "world_bptt_envelope_retained": mul(world_records, 131072L),
    "physics_scene_reserve_retained": if i.isaac {
      24L * GiB
    } else {
      2L * GiB
    },
    "distributed_communicator_staging_retained": if i.distributed {
      GiB
    } else {
      0L
    },
  }
  let train_extra = replay_components(after_collection)
  train_extra["actor_candidate_indices"] = mul(
    after_collection.logical_records,
    4L,
  )
  // Deliberately retain the old per-transition envelope for compatibility
  // batches until the dynamic arrays/headers are measured independently.
  train_extra["sampled_transition_objects_legacy_allowance"] = mul(
    sample_records, 131072L,
  )
  train_extra["upload_and_concat_payload_envelope"] = upload_payload
  train_extra["sampler_probability_update_temporary_payload"] = mul(
    i.sampler_bins.to_int64(),
    32L,
  )
  let full_train = train_extra.copy()
  full_train["live_replay_primitive_payload"] = capacity.allocated_payload_bytes
  full_train["live_replay_metadata_allowance_uncalibrated"] = capacity.metadata_allowance_bytes
  full_train["actor_candidate_indices"] = mul(capacity.logical_records, 4L)
  let saving = replay_components(capacity)
  saving["catalog_and_state_json_legacy_16x_allowance"] = mul(
    add(i.catalog_json_bytes, i.state_json_bytes),
    16L,
  )
  // Two 64 KiB payload buffers plus headers/hash/FFI allowance. Not total IO.
  saving["stream_codec_64k_working_allowance"] = 1048576L
  saving["libtorch_archive_legacy_6x_plus_1g_allowance"] = archive_work
  let restore = replay_components(current)
  restore["isolated_replay_primitive_payload"] = restoring.allocated_payload_bytes
  restore["isolated_replay_metadata_allowance_uncalibrated"] = restoring.metadata_allowance_bytes
  // Old histories/sampler remain in common until the prepared token is committed.
  restore["isolated_histories_payload_and_lengths"] = add(
    history_bytes,
    mul(n, 4L),
  )
  restore["isolated_sampler_payload_and_validation_vectors"] = add(
    sampler_bytes,
    mul(i.sampler_bins.to_int64(), 32L),
  )
  restore["isolated_environment_numeric_payload"] = i.environment_payload_bytes
  restore["one_transition_validation_legacy_allowance"] = 131072L
  for key, value in saving {
    if !key.has_prefix("live_replay_") {
      restore[key] = value
    }
  }
  let full_restore = restore.copy()
  full_restore["live_replay_primitive_payload"] = capacity.allocated_payload_bytes
  full_restore["live_replay_metadata_allowance_uncalibrated"] = capacity.metadata_allowance_bytes
  full_restore["isolated_replay_primitive_payload"] = capacity.allocated_payload_bytes
  full_restore["isolated_replay_metadata_allowance_uncalibrated"] = capacity.metadata_allowance_bytes
  {
    format: "moonrobo.compact-replay-memory-plan.v2",
    diagnostic_only: true,
    admission_eligible: false,
    checkpoint_format: "stream-v2",
    storage_format: i.storage.format,
    accounting_scope: "per-rank combined host/device accounting; not RSS, CUDA peak or available-memory admission",
    inputs: i,
    current,
    after_collection,
    capacity,
    restoring,
    next_collection_growth_payload_bytes: after_collection.allocated_payload_bytes -
    current.allocated_payload_bytes,
    maximum_slab_payload_bytes: mul(capacity.logical_records.min(1024L), 1882L),
    exact_counts: {
      "model_parameter_values": params,
      "history_payload_bytes": history_bytes,
      "sampler_live_payload_bytes": sampler_bytes,
      "capacity_actor_candidate_i32_payload_bytes": mul(
        capacity.logical_records,
        4L,
      ),
      "world_sample_transition_count": world_records,
      "actor_sample_transition_count_upper": actor_records,
      "world_tensor_values": world_values,
      "policy_float_tensor_values": policy_float_values,
      "critic_order_i64_tensor_values": order_values,
      "collection_float_tensor_values": collection_values,
    },
    legacy_replay_json_envelope_bytes: mul(capacity.logical_records, 131072L),
    archive_envelope_basis_bytes: archive_basis,
    archive_basis_source: if i.optimizer_archive_bytes is Some(_) {
      "max(measured three archive bytes, 16 bytes per parameter)"
    } else {
      "unmeasured: 16 bytes per parameter floor; not an archive-size bound"
    },
    train_after_collection: phase(common, train_extra),
    train_at_capacity: phase(common, full_train),
    save_at_capacity: phase(common, saving),
    restore_into_current: phase(common, restore),
    restore_at_capacity: phase(common, full_restore),
    saved_sidecars: sidecars(
      i,
      restoring,
      add(history_bytes, mul(n, 4L)),
      sampler_bytes,
    ),
    capacity_sidecars: sidecars(
      i,
      capacity,
      add(history_bytes, mul(n, 4L)),
      sampler_bytes,
    ),
    uncalibrated: [
      "slab/Array headers, directory growth, allocator fragmentation and retained arenas",
      "dynamic sampled/history/sampler objects beyond their primitive payload", "LibTorch archive decode/serialization, cached allocator and autograd lifetime",
      "reference file page cache, checkpoint writeback cache and native SDK working set",
      "observed host/cgroup/CUDA peaks must calibrate the separate process phases",
    ],
  }
}
