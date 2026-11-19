///|
fn validate_input(i : Inputs) -> Unit raise {
  guard i.profile == @capacity.Paper4096 && i.checkpoint_format == "stream-v2" else {
    fail(
      "phase admission is only for explicit paper-4096 plus stream-v2; retain the legacy planner otherwise",
    )
  }
  let c = i.learner
  guard c.hist > 0 &&
    c.hist <= 10 &&
    c.goal_frames > 0 &&
    c.goal_frames <= 10 &&
    c.horizon > 0 &&
    c.horizon <= 32 &&
    c.wm_window > 0 &&
    c.wm_window <= 8 &&
    i.replay_steps >= c.wm_window &&
    c.wm_batches > 0 &&
    c.critic_epochs > 0 &&
    c.critic_minibatches > 0 &&
    !c.wm_hidden.is_empty() &&
    c.wm_hidden.length() <= 3 &&
    c.wm_hidden.all(x => x > 0 && x <= 2048) &&
    !c.policy_hidden.is_empty() &&
    c.policy_hidden.length() <= 4 &&
    c.policy_hidden.all(x => x > 0 && x <= 2048) &&
    !c.critic_hidden.is_empty() &&
    c.critic_hidden.length() <= 4 &&
    c.critic_hidden.all(x => x > 0 && x <= 1024) &&
    i.sampler_bins > 0 &&
    i.environment_payload_bytes >= 0L &&
    i.motion_manifest_bytes > 0L &&
    i.motion_manifest_bytes <= 268435456L &&
    i.state_json_bytes > 0L &&
    i.state_json_bytes <= i.profile.limits().max_state_bytes &&
    i.restore_live_rows >= 0 &&
    i.restore_live_rows <= i.replay_steps &&
    i.restore_saved_rows >= 0 &&
    i.restore_saved_rows <= i.replay_steps else {
    fail(
      "invalid native paper phase-admission configuration or metadata bounds",
    )
  }
  i.profile.validate_catalog_bytes(i.catalog_json_bytes)
}

///|
/// Plan the implemented primitive-slab/block-upload execution, without changing
/// batch sizes, the critic schedule, training math or the default profile. The
/// returned plan must still be assessed against fresh host/cgroup AND CUDA free
/// readings; it does not initialize a tensor/device or allocate capacity data.
/// `serial_optimizer_save_workspace=true` accounts for sequential per-optimizer
/// save workspaces. It preserves file limits/cache and every restore envelope;
/// false retains the original complete plan for direct comparison.
pub fn plan_paper_stream(
  i : Inputs,
  include_restore~ : Bool = true,
  serial_optimizer_save_workspace~ : Bool = false,
  verified_compiled_allocator_cap? : Int64,
) -> Plan raise {
  validate_input(i)
  guard include_restore ||
    (
      i.restore_live_rows == 0 &&
      i.restore_saved_rows == 0 &&
      i.restore_optimizer_archive_bytes == 0L
    ) else {
    fail("fresh training admission cannot omit requested restore state")
  }
  let c = i.learner
  let limits = i.profile.limits()
  let replay = i.profile.validate_dimensions(
    environments=i.environments,
    world_batch=c.wm_batch,
    policy_batch=c.policy_batch,
    replay_steps=i.replay_steps,
  )
  let batch_limits : @runtime.BatchLimits = {
    max_reference_frames: limits.max_reference_frames,
    max_tensor_values: limits.max_tensor_values,
  }
  let world = @runtime.world_batch_shape_usage(
    c.wm_batch,
    c.wm_window,
    limits=batch_limits,
  )
  let policy = @runtime.policy_batch_shape_usage(
    c,
    c.policy_batch,
    i.observation_mode,
    limits=batch_limits,
  )
  let active_world = active_batch(c.wm_batch, i.world_microbatch).to_int64()
  let active_actor = active_batch(c.policy_batch, i.actor_microbatch).to_int64()
  let n = i.environments.to_int64()
  let bp = c.policy_batch.to_int64()
  let h = c.horizon.to_int64()
  let hist = c.hist.to_int64()
  let dim = i.observation_mode.dim().to_int64()
  let goal = mul(c.goal_frames.to_int64(), 73L)
  let critic_width = add(184L, goal)
  let world_params = mlp(133L, c.wm_hidden, 70L, true)
  // Encoder and decoder share one policy optimizer and one policy.pt archive.
  let policy_params = add(
    mlp(goal, c.policy_hidden, 32L, false),
    mlp(add(32L, mul(dim, hist)), c.policy_hidden, 29L, false),
  )
  let critic_params = mlp(critic_width, c.critic_hidden, 1L, false)
  let params = sum([world_params, policy_params, critic_params])
  let largest_optimizer_params = world_params
    .max(policy_params)
    .max(critic_params)
  let history = mul(mul(n, hist), mul(dim, 8L))
  let sampler = mul(i.sampler_bins.to_int64(), 20L)
  let sampler_temporary = mul(i.sampler_bins.to_int64(), 32L)
  let full_replay = slab_bytes(i.replay_steps, i.environments, i.replay_steps)
  let old_replay = slab_bytes(
    i.restore_live_rows,
    i.environments,
    i.replay_steps,
  )
  let staged_replay = slab_bytes(
    i.restore_saved_rows,
    i.environments,
    i.replay_steps,
  )
  let manifest = known_or_max(
    i.apic_manifest_bytes,
    limits.max_apic_manifest_bytes,
  )
  let payload = known_or_max(
    i.apic_payload_bytes,
    limits.max_apic_payload_total_bytes,
  )
  let union = known_or_max(
    i.apic_shared_union_bytes,
    limits.max_apic_numeric_union_bytes,
  )
  // Preserve 24 GiB even for a small artifact. Larger declared artifacts must
  // cover their numeric union, loading copies and file cache as well.
  let physics = (24L * GiB).max(sum([mul(payload, 3L), union, GiB]))
  let environment = i.environment_payload_bytes.max(
    add(mul(n, 133L * 8L), mul(n, 32L)),
  )

  // Device payloads remain full logical batch even when BPTT is chunked. Keep
  // existing per-sample graph envelopes and additionally scale with configured
  // network widths (including the two policy networks).
  let world_hidden = c.wm_hidden.fold(init=0L, (a, x) => a + x.to_int64())
  let actor_hidden = c.policy_hidden.fold(init=0L, (a, x) => a + x.to_int64())
  let critic_hidden = c.critic_hidden.fold(init=0L, (a, x) => a + x.to_int64())
  let world_graph_per_step = 131072L.max(mul(add(203L, world_hidden), 32L))
  let actor_graph_per_step = 262144L.max(
    mul(
      sum([
        world_hidden,
        mul(actor_hidden, 2L),
        critic_hidden,
        mul(dim, hist),
        goal,
        256L,
      ]),
      32L,
    ),
  )
  let world_graph = mul(
    mul(active_world, c.wm_window.to_int64()),
    world_graph_per_step,
  )
  let actor_graph = mul(mul(active_actor, h), actor_graph_per_step)
  let critic_rows = mul(add(h, 1L), bp)
  let critic_samples = mul(h, bp)
  let critic_input = mul(mul(critic_rows, critic_width), 4L)
  let critic_minibatch_rows = ceil_div(
    critic_samples,
    c.critic_minibatches.to_int64().min(critic_samples),
  )
  // Frozen bootstrap has no parameter graph; normalizer/normalization still
  // materialize whole logical input. The trainable minibatch retains its own
  // normalized input and layer activations. Epoch count changes orders/work,
  // not simultaneously live optimizer graphs.
  let critic_bootstrap = add(
    mul(critic_input, 3L),
    mul(mul(critic_rows, critic_hidden), 16L),
  )
  let critic_graph = mul(
    critic_minibatch_rows,
    mul(sum([mul(critic_width, 4L), mul(critic_hidden, 8L), 16L]), 4L),
  )
  let critic_misc = mul(add(critic_rows, critic_samples), 64L)
  let collection_values = mul(n, sum([205L, mul(dim, add(hist, 1L)), goal]))
  let collection_graph = mul(
    n,
    mul(sum([mul(dim, hist), goal, mul(actor_hidden, 2L), 256L]), 32L),
  )
  let device_work : Map[String, Int64] = {
    "collection": add(mul(collection_values, 4L), collection_graph),
    "world_fit": sum([
      world.device_f32_payload_bytes,
      mul(world.largest_device_concat_values, 4L),
      world_graph,
    ]),
    "actor": sum([
      policy.device_f32_payload_bytes,
      mul(policy.largest_device_concat_values, 4L),
      actor_graph,
      mul(critic_input, 2L),
      critic_misc,
    ]),
    "critic": sum([
      policy.device_f32_payload_bytes,
      critic_input,
      critic_bootstrap.max(critic_graph),
      critic_misc,
    ]),
  }
  let mut device_peak = 0L
  for _, bytes in device_work {
    device_peak = device_peak.max(bytes)
  }
  // The CUDA caching allocator is intentionally NOT emptied between phases.
  // Retain twice the largest known device working envelope plus 256 MiB in all
  // later phases instead of pretending released graphs return memory to CUDA.
  let cached_workspace = add(mul(device_peak, 2L), GiB / 4L)
  // Only the CUDA caching allocator is bounded. Never substitute a sample
  // peak for a hard bound. Retain every host/physics/archive/optimizer
  // reserve and separate driver, BLAS and executable-module headroom.
  let cached_workspace = match verified_compiled_allocator_cap {
    None => cached_workspace
    Some(cap) => {
      guard cap == 20L * GiB &&
        !i.distributed &&
        i.world_microbatch == 0 &&
        i.actor_microbatch == 0 &&
        c.wm_batch == 2048 &&
        c.policy_batch == 4096 &&
        c.horizon == 32 &&
        c.wm_window == 8 else {
        fail("invalid fixed BF16 allocator contract")
      }
      cap + 8L * GiB
    }
  }
  let common : Map[String, Int64] = {
    "reference_catalog_and_construction_retained": (4L * GiB).max(
      mul(i.motion_manifest_bytes, 16L),
    ),
    "physics_scene_working_floor": physics,
    "apic_manifest_decode_16x": mul(manifest, 16L),
    "parameters_gradients_adam_and_allocator": add(mul(params, 16L), GiB / 2L),
    "history_and_live_environment": add(history, mul(n, 1048576L)),
    "sampler_live_numeric": sampler,
    "reset_bin_objects_and_directories_allowance": mul(
      i.sampler_bins.to_int64(),
      64L,
    ),
    "device_working_cache_envelope": cached_workspace,
    "distributed_communicator_staging": if i.distributed {
      GiB
    } else {
      0L
    },
  }
  let world_host = sum([
    mul(world.sampled_transition_values / 234L, 131072L),
    mul(world.assembled_values_per_block, 32L),
    mul(world.sampled_mask_values, 8L),
  ])
  // sample_policy_batch retains compact logical start indices, then decodes
  // at most one reference block of ReplayStart/history compatibility objects.
  // The public policy_batch_from_starts caller-owned objects are not this path.
  let actor_decoded_transitions = mul(
    policy.sample_block_size.to_int64(),
    add(hist, 1L),
  )
  let actor_selected_indices = mul(bp, 4L)
  let actor_host = sum([
    mul(actor_decoded_transitions, 131072L),
    actor_selected_indices,
    mul(policy.assembled_values_per_block, 32L),
    mul(policy.reference_state_values_per_block, 32L),
    mul(policy.critic_permutation_values, 40L),
    mul(policy.noise_values_per_block, 32L),
    mul(replay.records, 4L),
  ])
  let collection_host = sum([
    mul(n, 131072L),
    mul(collection_values, 32L),
    sampler_temporary,
  ])
  let train_collection = phase("train_collection", common, {
    "replay_capacity_slabs": full_replay,
    "collection_objects_and_upload": collection_host,
  })
  let train_world = phase("train_world", common, {
    "replay_capacity_slabs": full_replay,
    "sampled_window_objects_and_upload": world_host,
  })
  let train_actor = phase("train_actor_and_critic", common, {
    "replay_capacity_slabs": full_replay,
    "sampled_start_objects_and_block_upload": actor_host,
    "sampler_probability_temporary": sampler_temporary,
  })

  let history_sidecar = add(history, mul(n, 4L))
  let sidecar_total = i.profile.validate_stream_totals(
    [
      replay.float64_bytes,
      replay.indices_bytes,
      replay.flags_bytes,
      history_sidecar,
      sampler,
      environment,
      i.catalog_json_bytes,
    ],
    state_bytes=i.state_json_bytes,
  )
  // Keep the independently enforced three 512 MiB optimizer-archive limits.
  // A prior small archive is evidence, not a bound on a future serialization.
  let save_archives = 3L * GiB / 2L
  guard i.restore_optimizer_archive_bytes >= 0L &&
    i.restore_optimizer_archive_bytes <= save_archives else {
    fail(
      "restored optimizer archives exceed the existing per-archive total bound",
    )
  }
  let restore_archives = if i.restore_optimizer_archive_bytes == 0L {
    save_archives
  } else {
    i.restore_optimizer_archive_bytes
  }
  let generation = sum([sidecar_total, save_archives, 65536L])
  let metadata_work = mul(add(i.catalog_json_bytes, i.state_json_bytes), 16L)
  let archive_work = add(mul(save_archives.max(mul(params, 16L)), 6L), GiB)
  // save_optimizers calls three synchronous saves. Each C++ OutputArchive and
  // nested optimizer archive dies when that call returns; only one optimizer
  // serialization workspace is live. Retain the same 6x + 1 GiB allowance and
  // all three files' cache below. This is a conservative lifetime estimate,
  // not a promise that the host allocator immediately returns freed RSS.
  // Restore estimates deliberately keep the historical combined envelope.
  let save_archive_work = if serial_optimizer_save_workspace {
    add(mul((GiB / 2L).max(mul(largest_optimizer_params, 16L)), 6L), GiB)
  } else {
    archive_work
  }
  let restore_archive_work = add(
    mul(restore_archives.max(mul(params, 16L)), 6L),
    GiB,
  )
  let save_archive_phase = phase("save_optimizer_archives", common, {
    "replay_capacity_slabs": full_replay,
    "libtorch_archive_6x_plus_1g": save_archive_work,
    "archive_file_cache": save_archives,
  })
  let save_stream_phase = phase("save_stream_sidecars_and_publish", common, {
    "replay_capacity_slabs": full_replay,
    "catalog_and_state_json_16x": metadata_work,
    "stream_codec_64k_buffers_and_headers": 1048576L,
    "generation_file_cache": generation,
  })
  // Whole-generation SHA verification precedes restore and can leave clean
  // file cache behind. Count it conservatively even though it is reclaimable.
  // Optimizers load BEFORE isolated replay staging: those two decode workloads
  // do not coexist. Previously loaded tensors/cache remain in common.
  let restored_records = mul(i.restore_saved_rows.to_int64(), n)
  let restore_disk = sum([
    mul(restored_records, 1882L),
    history_sidecar,
    sampler,
    environment,
    i.catalog_json_bytes,
    i.state_json_bytes,
    restore_archives,
    65536L,
  ])
  let restore_archive_phase = phase("restore_optimizer_archives", common, {
    "old_replay_slabs": old_replay,
    "verified_generation_file_cache": restore_disk,
    "libtorch_archive_6x_plus_1g": restore_archive_work,
    "catalog_and_state_json_16x": metadata_work,
  })
  let staged_extra : Map[String, Int64] = {
    "old_replay_slabs": old_replay,
    "isolated_replay_slabs": staged_replay,
    "isolated_history_sampler_environment": sum([
      history_sidecar, sampler, sampler_temporary, environment,
    ]),
    "verified_generation_file_cache": restore_disk,
    "catalog_and_state_json_16x": metadata_work,
    "stream_codec_and_one_transition_validation": 1048576L + 131072L,
  }
  let restore_stage_phase = phase(
    "restore_staged_runtime_and_environment", common, staged_extra,
  )
  let replacement = staged_extra.copy()
  replacement["old_replay_slabs"] = full_replay
  replacement["isolated_replay_slabs"] = full_replay
  replacement["verified_generation_file_cache"] = generation
  let full_replacement = phase(
    "diagnostic_restore_over_full_live_replay", common, replacement,
  )
  let full_archive_restore = phase(
    "diagnostic_restore_archives_over_full_live_replay",
    common,
    {
      "old_replay_slabs": full_replay,
      "verified_generation_file_cache": generation,
      "libtorch_archive_6x_plus_1g": archive_work,
      "catalog_and_state_json_16x": metadata_work,
    },
  )
  let phases = [
    train_collection, train_world, train_actor, save_archive_phase, save_stream_phase,
  ]
  if include_restore {
    phases.append([restore_archive_phase, restore_stage_phase])
  }
  let mut peak_bytes = 0L
  let mut peak_phase = ""
  for p in phases {
    if p.envelope_bytes > peak_bytes {
      peak_bytes = p.envelope_bytes
      peak_phase = p.name
    }
  }
  let result : Plan = {
    format: "moonrobo.native-paper-phase-memory-plan.v1",
    capacity_profile: i.profile.name(),
    checkpoint_format: i.checkpoint_format,
    restore_phases_included: include_restore,
    accounting_scope: "per-rank combined host/device envelope; full replay capacity; no summation of disjoint optimizer-archive and replay-decode phases",
    phases,
    peak_bytes,
    peak_phase,
    required_remaining_bytes: ceil_div(mul(peak_bytes, 100L), 65L),
    full_replacement_restore_peak_bytes: full_replacement.envelope_bytes.max(
      full_archive_restore.envelope_bytes,
    ),
    full_replacement_restore_scope: "diagnostic only unless restore_live_rows is full; ordinary fresh-process resume uses zero live rows",
    counts: {
      "replay_records": replay.records,
      "replay_f64_values": replay.values,
      "replay_primitive_payload_bytes": replay.payload_bytes,
      "replay_capacity_with_slab_allowance_bytes": full_replay,
      "world_active_microbatch": active_world,
      "actor_active_microbatch": active_actor,
      "world_logical_tensor_values": world.logical_tensor_values,
      "policy_logical_tensor_values": policy.logical_tensor_values,
      "policy_full_device_payload_bytes": policy.device_f32_payload_bytes,
      "policy_reference_frames": policy.reference_frames,
      "actor_sampled_transition_count_upper": policy.sampled_transition_values /
      234L,
      "actor_decoded_transition_count_per_block": actor_decoded_transitions,
      "actor_selected_start_index_bytes": actor_selected_indices,
      "world_sampled_transition_count_per_block": world.sampled_transition_values /
      234L,
      "model_parameter_values": params,
      "motion_manifest_source_bytes": i.motion_manifest_bytes,
      "critic_detached_input_bytes": critic_input,
      "critic_minibatch_rows": critic_minibatch_rows,
      "stream_capacity_payload_bytes": sidecar_total,
      "apic_manifest_budget_bytes": manifest,
      "apic_payload_budget_bytes": payload,
      "apic_shared_union_budget_bytes": union,
      "save_optimizer_archive_bound_bytes": save_archives,
      "restore_optimizer_archive_budget_bytes": restore_archives,
      "host_checkpoint_stream_publication_headroom": add(
        save_archive_work, save_archives,
      ).max(sum([metadata_work, 1048576L, generation])),
    },
    device_phase_working_bytes: device_work,
    checkpoint_generation_bytes: generation,
    minimum_output_free_bytes: add(generation, GiB),
    assumptions: [
      "explicit paper-4096 and stream-v2 only; legacy admission is unchanged",
      "Isaac/APIC CUDA execution; 24 GiB physics floor and 4 GiB reference reserve retained; required_remaining_bytes is the 65% baseline, actual admission policy is in Decision",
      "microbatch zero means the original full batch; no automatic microbatch selection or mathematical change",
      "runtime shape accounting includes full policy references, goals, noise and critic permutations despite chunked host uploads",
      "actor/world graphs die between chunks; detached critic data and full-batch normalizer/bootstrap do not",
      if verified_compiled_allocator_cap is Some(_) {
        "Frozen single-GPU compiled profile: verified 20 GiB process-wide native allocator ceiling plus 8 GiB for non-allocator driver/modules/workspaces. Independent physics floor, host estimates, optimizer/archive reserves and runtime guards remain in force."
      } else {
        "device cache allowance is twice the largest structural working estimate plus 256 MiB; no empty_cache or peak-counter reset"
      },
      "128 KiB compatibility-object allowance applies only to decoded samples, not every primitive replay record",
      "3 * 512 MiB save archive bound remains; serialization and allocator multipliers are conservative estimates, not measured maxima",
      "staged runtime restore preserves old replay until commit; CLI learner restore remains fail-stop into a fresh learner, not a live-optimizer rollback guarantee",
      "file cache is included conservatively; statvfs/free-memory rechecks and cgroup/no-swap/time watchdogs remain mandatory",
      "N128 telemetry calibrates one observed small run only; it does not validate N4096 physics, peak memory, speed or convergence",
    ],
  }
  if serial_optimizer_save_workspace {
    result.counts["serial_optimizer_save_workspace"] = 1L
    result.counts["largest_optimizer_parameter_values"] = largest_optimizer_params
    result.counts["single_optimizer_archive_bound_bytes"] = GiB / 2L
    result.counts["legacy_save_optimizer_workspace_bytes"] = archive_work
    result.counts["serial_save_optimizer_workspace_bytes"] = save_archive_work
    result.assumptions.push(
      "Opt-in sequential optimizer save workspace: max single world/policy/critic archive; policy includes encoder plus decoder; unchanged 512 MiB per-file limits, full three-file cache, 6x + 1 GiB multiplier and restore envelopes. Host allocator retention remains possible; no certified RSS bound.",
    )
  }
  result
}
