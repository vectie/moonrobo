///|
fn memory_available(text : String) -> Int64 raise {
  @linuxmem.memory_available(text)
}

///|
async fn constrain_cgroup(available : Int64, root : String, v2 : Bool) -> Int64 {
  @linuxmem.constrain_cgroup(available, root, v2)
}

///|
async fn host_available() -> Int64 {
  @linuxmem.host_available()
}

///|
fn mlp_parameters(
  input : Int32,
  hidden : Array[Int32],
  output : Int32,
  norm : Bool,
) -> Int64 {
  let dims = [input]
  dims.append(hidden)
  dims.push(output)
  let mut count = 0L
  for i in 0..<(dims.length() - 1) {
    count += (dims[i].to_int64() + 1L) * dims[i + 1].to_int64()
  }
  if norm {
    for width in hidden {
      count += 2L * width.to_int64()
    }
  }
  count
}

///|
struct MemoryPlan {
  host_free_bytes : Int64
  cuda_free_bytes : Int64?
  budget_bytes : Int64
  peak_bytes : Int64
  components : Map[String, Int64]
  phase_plan : @admission.Plan?
  admission_decision : @admission.Decision?
} derive(ToJson)

///|
fn estimate_memory(
  s : Settings,
  host : Int64,
  cuda : Int64?,
  physical? : PhysicsPreflight,
  include_restore~ : Bool = true,
  sampler_bins? : Int32,
  motion_manifest_bytes~ : Int64 = 268435456L,
) -> MemoryPlan raise {
  if s.capacity_profile == @capacity.Paper4096 {
    let sampler_bins = motion_sampler_bins_for_plan(
      s.motion_sampler_bin_cap,
      sampler_bins,
    )
    guard cuda is Some(device_free) else {
      fail("paper-4096 admission requires measured CUDA availability")
    }
    let phases = @admission.plan_paper_stream(
      {
        profile: s.capacity_profile,
        checkpoint_format: "stream-v2",
        environments: s.environments,
        replay_steps: s.replay_steps,
        learner: s.learner,
        observation_mode: s.mode,
        world_microbatch: s.batch_execution.world_microbatch,
        actor_microbatch: s.batch_execution.actor_microbatch,
        sampler_bins,
        catalog_json_bytes: s.capacity_profile.limits().max_catalog_bytes,
        motion_manifest_bytes,
        state_json_bytes: s.capacity_profile.limits().max_state_bytes,
        environment_payload_bytes: 0L,
        apic_manifest_bytes: physical.map(x => x.manifest_bytes).unwrap_or(0L),
        apic_payload_bytes: physical.map(x => x.bundle_bytes).unwrap_or(0L),
        apic_shared_union_bytes: physical
        .map(x => x.shared_region_bytes)
        .unwrap_or(0L),
        restore_live_rows: 0,
        restore_saved_rows: if include_restore {
          s.replay_steps
        } else {
          0
        },
        restore_optimizer_archive_bytes: 0L,
        distributed: s.distributed is Some(_),
      },
      include_restore~,
      serial_optimizer_save_workspace=s.serial_optimizer_save_workspace,
      verified_compiled_allocator_cap?=s.verified_allocator_cap,
    )
    let phases = if s.operator_diagnostic_only {
      phases.for_operator_diagnostic()
    } else {
      phases
    }
    let phases = phases.with_execution_reserve(optimization_memory_extra(s))
    let decision = @admission.assess(
      phases,
      host,
      device_free,
      memory_admission_percent?=s.memory_admission_percent,
    )
    guard decision.accepted else {
      fail(
        "native paper memory planning budget exceeded: " +
        Json(phases).stringify() +
        "; decision=" +
        Json(decision).stringify(),
      )
    }
    let components = phases.counts.copy()
    components["minimum_output_free_bytes"] = phases.minimum_output_free_bytes
    // Compatibility report keys keep the independently enforced reserves clear.
    components["physics_scene_reserve"] = 24L * 1073741824L
    components["distributed_communicator_staging"] = if s.distributed is Some(_) {
      1073741824L
    } else {
      0L
    }
    return {
      host_free_bytes: host,
      cuda_free_bytes: cuda,
      budget_bytes: decision.budget_bytes,
      peak_bytes: phases.peak_bytes,
      components,
      phase_plan: Some(phases),
      admission_decision: Some(decision),
    }
  }
  let gib = 1073741824L
  let c = s.learner
  let params = mlp_parameters(133, c.wm_hidden, 70, true) +
    mlp_parameters(c.goal_frames * 73, c.policy_hidden, 32, false) +
    mlp_parameters(32 + s.mode.dim() * c.hist, c.policy_hidden, 29, false) +
    mlp_parameters(184 + c.goal_frames * 73, c.critic_hidden, 1, false)
  let components : Map[String, Int64] = {
    "bounded_reference_catalog_and_construction": 4L * gib,
    // Host replay is Double arrays and checkpoint JSON is boxed/string encoded.
    // Do not reuse Python's packed Float32 replay-byte estimate here.
    "host_replay_and_json_checkpoint_envelope": s.environments.to_int64() *
    s.replay_steps.to_int64() *
    131072L,
    "parameters_gradients_adam_allocator": params * 16L + gib / 2L,
    "history_and_live_environment": s.environments.to_int64() *
    c.hist.to_int64() *
    s.mode.dim().to_int64() *
    8L +
    s.environments.to_int64() * 1048576L,
    "actor_bptt_envelope": c.horizon.to_int64() *
    c.policy_batch.to_int64() *
    262144L,
    "world_bptt_envelope": c.wm_window.to_int64() *
    c.wm_batch.to_int64() *
    131072L,
    "physics_scene_reserve": if s.backend == "isaac" {
      24L * gib
    } else {
      2L * gib
    },
    "distributed_communicator_staging": if s.distributed is Some(_) {
      gib
    } else {
      0L
    },
  }
  let mut peak = 0L
  for name, value in optimization_memory_extra(s) {
    components[name] = value
  }
  for _, value in components {
    peak += value
  }
  let free = match cuda {
    Some(bytes) => host.min(bytes)
    None => host
  }
  guard free > 0L else { fail("memory availability unknown or exhausted") }
  let plan : MemoryPlan = {
    host_free_bytes: host,
    cuda_free_bytes: cuda,
    budget_bytes: free * 65L / 100L,
    peak_bytes: peak,
    components,
    phase_plan: None,
    admission_decision: None,
  }
  guard peak <= plan.budget_bytes else {
    fail("native memory planning budget exceeded: " + Json(plan).stringify())
  }
  plan
}

///|
async fn preflight(
  backend : @tensor.Backend,
  s : Settings,
  manifest : String,
  physical? : PhysicsPreflight,
  include_restore~ : Bool = true,
  sampler_bins? : Int32,
) -> MemoryPlan {
  // Inspect the size before the motion loader parses any catalog or opens shards.
  let file = @fs.open(manifest, mode=ReadOnly)
  defer file.close()
  let manifest_bytes = file.size()
  guard manifest_bytes > 0L && manifest_bytes <= 268435456L else {
    fail("motion catalog must be at most 256 MiB for initial native profile")
  }
  let host = host_available()
  let cuda = if s.device < 0 {
    None
  } else {
    guard s.device < backend.cuda_device_count() else {
      fail("requested CUDA device unavailable")
    }
    Some(backend.cuda_free_bytes(s.device))
  }
  estimate_memory(
    s,
    host,
    cuda,
    physical?,
    include_restore~,
    sampler_bins?,
    motion_manifest_bytes=manifest_bytes,
  )
}

///|
async fn validate_catalog_bound(path : String) -> Unit {
  // This bounded parse is released before the loader's parse. Enforce the
  // metadata envelope before building reset bins or native cache descriptors.
  match bounded_json(path, 268435456L) {
    { "clips": Array(clips), .. } => {
      guard !clips.is_empty() && clips.length() <= 200000 else {
        fail("catalog exceeds initial native 200000-clip metadata envelope")
      }
    }
    _ => fail("motion manifest lacks a clips array")
  }
}

///|
/// Evaluation retains the full physical replica batch even though the actor
/// processes one reference at a time. Paper capacity must budget those worlds
/// and the sampler; the historical small-profile reserve stays unchanged.
fn evaluation_reserve(
  s : Settings,
  physical : PhysicsPreflight?,
  motion_manifest_bytes : Int64,
  sampler_bins~ : Int32 = 43149672,
) -> Int64 raise {
  let gib = 1073741824L
  if s.capacity_profile == @capacity.Initial {
    return if s.backend == "isaac" { 28L * gib } else { 6L * gib }
  }
  guard physical is Some(p) &&
    s.backend == "isaac" &&
    s.device >= 0 &&
    motion_manifest_bytes > 0L &&
    motion_manifest_bytes <= 268435456L &&
    sampler_bins > 0 &&
    sampler_bins <= @admission.unknown_sampler_bins_upper() else {
    fail("paper evaluation requires bounded manifest and physical metadata")
  }
  let limits = s.capacity_profile.limits()
  guard p.bundle_bytes > 0L &&
    p.bundle_bytes <= limits.max_apic_payload_total_bytes &&
    p.shared_region_bytes > 0L &&
    p.shared_region_bytes <= limits.max_apic_numeric_union_bytes &&
    p.manifest_bytes > 0L &&
    p.manifest_bytes <= limits.max_apic_manifest_bytes else {
    fail("paper evaluation physical metadata exceeds capacity bounds")
  }
  let n = s.environments.to_int64()
  let c = s.learner
  let hist = c.hist.to_int64()
  let dim = s.mode.dim().to_int64()
  let goal = c.goal_frames.to_int64()
  // All factors are fixed-profile bounded; these products are below Int64.
  (24L * gib).max(3L * p.bundle_bytes + p.shared_region_bytes + gib) +
  (4L * gib).max(16L * motion_manifest_bytes) +
  16L * p.manifest_bytes +
  n * 1048576L +
  n * hist * dim * 8L +
  sampler_bins.to_int64() * 116L +
  n * (205L + (hist + 1L) * dim + 73L * goal) * 32L +
  n.min(256L) * (hist + c.horizon.to_int64() + goal + 1L) * 76L * 32L
}
