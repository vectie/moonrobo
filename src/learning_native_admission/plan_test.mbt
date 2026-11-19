///|
fn fixture() -> @learning_native_admission.Inputs {
  {
    profile: @capacity.Paper4096,
    checkpoint_format: "stream-v2",
    environments: 4096,
    replay_steps: 1000,
    learner: {
      ..@aligned.LearnerConfig::default(),
      wm_hidden: [2048, 2048, 2048],
      policy_hidden: [2048, 1024, 512, 256],
      critic_hidden: [256, 128],
      wm_batch: 2048,
      policy_batch: 4096,
      hist: 10,
      goal_frames: 10,
      horizon: 32,
      wm_window: 8,
      critic_epochs: 5,
      critic_minibatches: 4,
      observation_noise: true,
    },
    observation_mode: @aligned.Smc,
    world_microbatch: 16,
    actor_microbatch: 16,
    sampler_bins: 1000000,
    motion_manifest_bytes: 1048576L,
    catalog_json_bytes: 67108864L,
    state_json_bytes: 4194304L,
    environment_payload_bytes: 4096L * 33L * 8L,
    apic_manifest_bytes: 0L,
    apic_payload_bytes: 0L,
    apic_shared_union_bytes: 0L,
    restore_live_rows: 0,
    restore_saved_rows: 1000,
    restore_optimizer_archive_bytes: 0L,
    distributed: false,
  }
}

///|
test "serial save workspace is opt-in and leaves restore and storage limits unchanged" {
  let input = fixture()
  let old = @learning_native_admission.plan_paper_stream(input)
  assert_eq(
    Json(old),
    Json(
      @learning_native_admission.plan_paper_stream(
        input,
        serial_optimizer_save_workspace=false,
      ),
    ),
  )
  assert_true(!old.counts.contains("serial_optimizer_save_workspace"))
  let serial = @learning_native_admission.plan_paper_stream(
    input,
    serial_optimizer_save_workspace=true,
  )
  assert_eq(serial.counts["largest_optimizer_parameter_values"], 9116477L)
  assert_eq(serial.counts["model_parameter_values"], 18206596L)
  assert_eq(serial.counts["single_optimizer_archive_bound_bytes"], 536870912L)
  assert_eq(serial.counts["save_optimizer_archive_bound_bytes"], 1610612736L)
  assert_eq(
    serial.counts["restore_optimizer_archive_budget_bytes"],
    old.counts["restore_optimizer_archive_budget_bytes"],
  )
  assert_eq(
    serial.phases[3].components["libtorch_archive_6x_plus_1g"],
    4294967296L,
  )
  assert_eq(
    old.phases[3].components["libtorch_archive_6x_plus_1g"],
    10737418240L,
  )
  assert_eq(serial.phases[3].components["archive_file_cache"], 1610612736L)
  for i in 0..<old.phases.length() {
    if i != 3 {
      assert_eq(Json(serial.phases[i]), Json(old.phases[i]))
    }
  }
  assert_eq(
    Json(serial.device_phase_working_bytes),
    Json(old.device_phase_working_bytes),
  )
  assert_eq(serial.checkpoint_generation_bytes, old.checkpoint_generation_bytes)
  assert_eq(serial.minimum_output_free_bytes, old.minimum_output_free_bytes)
  assert_eq(
    serial.full_replacement_restore_peak_bytes,
    old.full_replacement_restore_peak_bytes,
  )
}

///|
test "serial save admits fixed N256 B512 evidence without changing guards or batches" {
  let f = fixture()
  let input = {
    ..f,
    environments: 256,
    learner: { ..f.learner, policy_batch: 512, },
    world_microbatch: 0,
    actor_microbatch: 0,
    sampler_bins: @learning_native_admission.unknown_sampler_bins_upper(),
    motion_manifest_bytes: 38601L,
    environment_payload_bytes: 0L,
    apic_manifest_bytes: 106611L,
    apic_payload_bytes: 230465552L,
    apic_shared_union_bytes: 47905609L,
    restore_saved_rows: 0,
  }
  let old = @learning_native_admission.plan_paper_stream(
    input,
    include_restore=false,
  )
  let serial = @learning_native_admission.plan_paper_stream(
    input,
    include_restore=false,
    serial_optimizer_save_workspace=true,
  )
  assert_eq(old.peak_bytes, 65241943952L)
  assert_eq(serial.peak_bytes, 58799493008L)
  assert_eq(serial.peak_phase, "save_optimizer_archives")
  assert_eq(serial.counts["actor_active_microbatch"], 512L)
  assert_eq(serial.counts["world_active_microbatch"], 2048L)
  assert_eq(
    Json(serial.device_phase_working_bytes),
    Json(old.device_phase_working_bytes),
  )
  let host = 107176316928L
  let cuda = 81920348160L
  assert_true(
    !@learning_native_admission.assess(
      old,
      host,
      cuda,
      memory_admission_percent=80,
    ).accepted,
  )
  for
    plan in [
      serial,
      serial.with_execution_reserve({
        "execution_candidate_fixture": 4294967296L,
      }),
    ] {
    let decision = @learning_native_admission.assess(
      plan,
      host,
      cuda,
      memory_admission_percent=80,
    )
    assert_true(decision.accepted)
    assert_eq(decision.admission_percent, 80)
    assert_eq(decision.minimum_free_reserve_bytes, 17179869184L)
    assert_eq(decision.budget_bytes, 64740478976L)
    let needed = decision.required_remaining_bytes
    assert_true(
      @learning_native_admission.assess(
        plan,
        needed,
        needed,
        memory_admission_percent=80,
      ).accepted,
    )
    assert_true(
      !@learning_native_admission.assess(
        plan,
        needed - 1L,
        needed,
        memory_admission_percent=80,
      ).accepted,
    )
    assert_true(
      !@learning_native_admission.assess(
        plan,
        needed,
        needed - 1L,
        memory_admission_percent=80,
      ).accepted,
    )
  }
}

///|
test "paper-size planning has exact slab and full logical input counts without allocation" {
  let plan = @learning_native_admission.plan_paper_stream(fixture())
  assert_eq(plan.counts["replay_records"], 4096000L)
  assert_eq(plan.counts["replay_f64_values"], 958464000L)
  assert_eq(plan.counts["replay_primitive_payload_bytes"], 7708672000L)
  assert_eq(plan.counts["policy_logical_tensor_values"], 126500864L)
  assert_eq(plan.counts["policy_reference_frames"], 135168L)
  assert_eq(plan.counts["actor_sampled_transition_count_upper"], 45056L)
  assert_eq(plan.counts["actor_decoded_transition_count_per_block"], 2816L)
  assert_eq(plan.counts["actor_selected_start_index_bytes"], 16384L)
  assert_eq(plan.counts["world_sampled_transition_count_per_block"], 2048L)
  assert_eq(plan.counts["critic_minibatch_rows"], 32768L)
  assert_eq(plan.counts["world_active_microbatch"], 16L)
  assert_eq(plan.counts["actor_active_microbatch"], 16L)
  assert_eq(plan.phases.length(), 7)
  assert_true(plan.peak_bytes < 80L * 1073741824L)
  assert_true(plan.peak_bytes > 24L * 1073741824L)
  for phase in plan.phases {
    assert_true(
      phase.components["physics_scene_working_floor"] >= 24L * 1073741824L,
    )
    assert_eq(phase.components["apic_manifest_decode_16x"], 1073741824L)
    assert_true(phase.components["device_working_cache_envelope"] > 0L)
  }
}

///|
test "full batch is planned honestly and never silently replaced with microbatch" {
  let input = fixture()
  let micro = @learning_native_admission.plan_paper_stream(input)
  let full = @learning_native_admission.plan_paper_stream({
    ..input,
    world_microbatch: 0,
    actor_microbatch: 0,
  })
  assert_eq(full.counts["world_active_microbatch"], 2048L)
  assert_eq(full.counts["actor_active_microbatch"], 4096L)
  assert_eq(
    full.counts["policy_full_device_payload_bytes"],
    micro.counts["policy_full_device_payload_bytes"],
  )
  assert_eq(
    full.counts["critic_minibatch_rows"],
    micro.counts["critic_minibatch_rows"],
  )
  assert_true(full.peak_bytes > micro.peak_bytes)
  assert_true(
    !@learning_native_admission.assess(
      full,
      128L * 1073741824L,
      128L * 1073741824L,
    ).accepted,
  )
}

///|
test "fresh resume and live replacement retain different replay lifetimes" {
  let fresh = @learning_native_admission.plan_paper_stream(fixture())
  let live = @learning_native_admission.plan_paper_stream({
    ..fixture(),
    restore_live_rows: 1000,
  })
  let fresh_stage = fresh.phases[6]
  let live_stage = live.phases[6]
  assert_eq(fresh_stage.components["old_replay_slabs"], 4096L)
  assert_eq(
    live_stage.components["old_replay_slabs"],
    fresh.counts["replay_capacity_with_slab_allowance_bytes"],
  )
  assert_eq(
    live_stage.components["isolated_replay_slabs"],
    fresh_stage.components["isolated_replay_slabs"],
  )
  assert_eq(
    live.full_replacement_restore_peak_bytes,
    fresh.full_replacement_restore_peak_bytes,
  )
  assert_true(live.peak_bytes >= fresh.peak_bytes)
  assert_true(!fresh.phases[5].components.contains("isolated_replay_slabs"))
  assert_true(
    !fresh.phases[6].components.contains("libtorch_archive_6x_plus_1g"),
  )
}

///|
test "admission uses exact 65 percent, limiting memory and positive observations" {
  let plan = @learning_native_admission.plan_paper_stream(fixture())
  let needed = plan.required_remaining_bytes
  let yes = @learning_native_admission.assess(plan, needed, needed)
  assert_true(yes.accepted)
  yes.require_accepted()
  let no = @learning_native_admission.assess(plan, needed - 1L, needed + 1L)
  assert_true(!no.accepted)
  assert_eq(no.limiting_remaining_bytes, needed - 1L)
  assert_eq(
    no.budget_bytes,
    (needed - 1L) / 100L * 65L + (needed - 1L) % 100L * 65L / 100L,
  )
  let zero = try {
    ignore(@learning_native_admission.assess(plan, 0L, needed))
    false
  } catch {
    _ => true
  }
  assert_true(zero)
  let refused = try {
    no.require_accepted()
    false
  } catch {
    _ => true
  }
  assert_true(refused)
}

///|
test "publication headroom excludes resident replay and disk preserves old generations" {
  let plan = @learning_native_admission.plan_paper_stream(fixture())
  let extra = plan.counts["host_checkpoint_stream_publication_headroom"]
  assert_true(extra > plan.checkpoint_generation_bytes)
  assert_true(extra < plan.peak_bytes)
  assert_eq(
    plan.minimum_output_free_bytes,
    plan.checkpoint_generation_bytes + 1073741824L,
  )
  plan.require_output_free(plan.minimum_output_free_bytes)
  let failed = try {
    plan.require_output_free(plan.minimum_output_free_bytes - 1L)
    false
  } catch {
    _ => true
  }
  assert_true(failed)
}

///|
test "legacy and invalid sizes cannot enter paper stream admission" {
  let base = fixture()
  for
    input in [
      { ..base, profile: @capacity.Initial, },
      { ..base, checkpoint_format: "v1", },
      { ..base, environments: 4097, },
      { ..base, actor_microbatch: 4097, },
      { ..base, restore_live_rows: 1001, },
      { ..base, apic_manifest_bytes: 67108865L, },
      { ..base, motion_manifest_bytes: 268435457L, },
      { ..base, environment_payload_bytes: 10737418240L, },
    ] {
    let failed = try {
      ignore(@learning_native_admission.plan_paper_stream(input))
      false
    } catch {
      _ => true
    }
    assert_true(failed)
  }
  assert_eq(@learning_native_admission.unknown_sampler_bins_upper(), 43149672)
}

///|
test "unknown preflight metadata is bounded and actual metadata only reduces its own terms" {
  let unknown = @learning_native_admission.plan_paper_stream({
    ..fixture(),
    sampler_bins: @learning_native_admission.unknown_sampler_bins_upper(),
  })
  let actual = @learning_native_admission.plan_paper_stream({
    ..fixture(),
    apic_manifest_bytes: 1048576L,
    apic_payload_bytes: 41943040L,
    apic_shared_union_bytes: 20971520L,
    restore_optimizer_archive_bytes: 218560088L,
  })
  assert_true(unknown.peak_bytes > actual.peak_bytes)
  assert_eq(
    unknown.phases[0].components["physics_scene_working_floor"],
    actual.phases[0].components["physics_scene_working_floor"],
  )
  assert_eq(
    unknown.counts["save_optimizer_archive_bound_bytes"],
    actual.counts["save_optimizer_archive_bound_bytes"],
  )
  assert_true(unknown.counts["stream_capacity_payload_bytes"] <= 10737418240L)
}

///|
test "documented phase examples remain stable" {
  let base = fixture()
  for
    (input, expected_peak, expected_remaining) in [
      (base, 64647803456L, 99458159164L),
      (
        { ..base, world_microbatch: 0, actor_microbatch: 0, },
        196803834432L,
        302775129896L,
      ),
      (
        {
          ..base,
          sampler_bins: @learning_native_admission.unknown_sampler_bins_upper(),
        },
        69031369344L,
        106202106684L,
      ),
      ({ ..base, distributed: true, }, 65721545280L, 101110069662L),
    ] {
    let plan = @learning_native_admission.plan_paper_stream(input)
    assert_true(plan.phases.all(p => p.envelope_bytes <= plan.peak_bytes))
    assert_eq(plan.peak_bytes, expected_peak)
    assert_eq(plan.required_remaining_bytes, expected_remaining)
    assert_eq(plan.peak_phase, "restore_optimizer_archives")
  }
}

///|
test "fresh training omits only restore phases and preserves save budgets" {
  let input = { ..fixture(), restore_saved_rows: 0, }
  let historical = @learning_native_admission.plan_paper_stream(input)
  let resume = @learning_native_admission.plan_paper_stream(
    input,
    include_restore=true,
  )
  let fresh = @learning_native_admission.plan_paper_stream(
    input,
    include_restore=false,
  )
  assert_eq(Json(historical), Json(resume))
  assert_true(resume.restore_phases_included)
  assert_true(!fresh.restore_phases_included)
  assert_eq(resume.phases.length(), 7)
  assert_eq(fresh.phases.length(), 5)
  for i in 0..<fresh.phases.length() {
    assert_eq(Json(fresh.phases[i]), Json(resume.phases[i]))
    assert_eq(
      fresh.phases[i].components["physics_scene_working_floor"],
      24L * 1073741824L,
    )
  }
  assert_eq(fresh.phases[3].name, "save_optimizer_archives")
  assert_eq(fresh.phases[4].name, "save_stream_sidecars_and_publish")
  assert_eq(fresh.minimum_output_free_bytes, resume.minimum_output_free_bytes)
  assert_eq(
    fresh.checkpoint_generation_bytes,
    resume.checkpoint_generation_bytes,
  )
  assert_eq(
    fresh.counts["host_checkpoint_stream_publication_headroom"],
    resume.counts["host_checkpoint_stream_publication_headroom"],
  )
  // Empty replay is still a resume: optimizer archives are separate state.
  assert_eq(resume.phases[5].name, "restore_optimizer_archives")
  assert_true(resume.phases[5].components["libtorch_archive_6x_plus_1g"] > 0L)
  assert_eq(resume.phases[6].name, "restore_staged_runtime_and_environment")
}

///|
test "fresh admission cannot silently discard requested restore state" {
  let empty = { ..fixture(), restore_saved_rows: 0, }
  for
    input in [
      { ..empty, restore_live_rows: 1, },
      { ..empty, restore_saved_rows: 1, },
      { ..empty, restore_optimizer_archive_bytes: 1L, },
    ] {
    try
      @learning_native_admission.plan_paper_stream(input, include_restore=false)
    catch {
      _ => ()
    } noraise {
      _ => fail("fresh mode accepted state requiring restore")
    }
  }
}

///|
test "N256 measured metadata retains fresh save peak and exact admission boundary" {
  // Byte counts from the pinned, SDK/native-replayed N256 self-collision bundle
  // 40e166ab973ba7ae11c2587a9e26d990f52b77d10ef230caee303e06203ae2e8.
  // These are capacity calculations, not measured CPU/GPU peak claims.
  let input = {
    ..fixture(),
    environments: 256,
    observation_mode: @aligned.Paper,
    world_microbatch: 256,
    actor_microbatch: 256,
    sampler_bins: 8842,
    motion_manifest_bytes: 38601L,
    environment_payload_bytes: 256L * 33L * 8L,
    apic_manifest_bytes: 107393L,
    apic_payload_bytes: 258682953L,
    apic_shared_union_bytes: 54331573L,
  }
  let resume = @learning_native_admission.plan_paper_stream(input)
  assert_eq(resume.peak_phase, "restore_optimizer_archives")
  assert_eq(resume.peak_bytes, 56990221408L)
  assert_eq(resume.required_remaining_bytes, 87677263705L)
  let fresh_input = { ..input, restore_saved_rows: 0, }
  let fresh = @learning_native_admission.plan_paper_stream(
    fresh_input,
    include_restore=false,
  )
  assert_eq(fresh.peak_phase, "save_optimizer_archives")
  assert_eq(fresh.peak_bytes, 55775702936L)
  assert_eq(fresh.phases[2].envelope_bytes, 43852366040L)
  assert_eq(fresh.required_remaining_bytes, 85808773748L)
  for plan in [fresh, resume] {
    let needed = plan.required_remaining_bytes
    assert_true(
      @learning_native_admission.assess(plan, needed, needed).accepted,
    )
    assert_true(
      !@learning_native_admission.assess(plan, needed - 1L, needed).accepted,
    )
    assert_true(
      !@learning_native_admission.assess(plan, needed, needed - 1L).accepted,
    )
  }
  let unknown_sampler = @learning_native_admission.plan_paper_stream(
    {
      ..fresh_input,
      sampler_bins: @learning_native_admission.unknown_sampler_bins_upper(),
    },
    include_restore=false,
  )
  assert_eq(unknown_sampler.required_remaining_bytes, 91383896394L)
}

///|
test "opt-in paper admission preserves both percentage and 16 GiB headroom" {
  let reserve = 16L * 1073741824L
  let base = fixture()
  let reserve_limited = @learning_native_admission.plan_paper_stream(base)
  let percentage_limited = @learning_native_admission.plan_paper_stream({
    ..base,
    world_microbatch: 0,
    actor_microbatch: 0,
  })
  for
    (plan, expected_required) in [
      (reserve_limited, 81827672640L),
      (percentage_limited, 246004793040L),
    ] {
    let old = @learning_native_admission.assess(
      plan, expected_required, expected_required,
    )
    assert_eq(old.admission_percent, 65)
    assert_eq(old.minimum_free_reserve_bytes, 0L)
    assert_eq(old.required_remaining_bytes, plan.required_remaining_bytes)
    assert_true(!old.accepted)
    let decision = @learning_native_admission.assess(
      plan,
      expected_required,
      expected_required,
      memory_admission_percent=80,
    )
    assert_true(decision.accepted)
    decision.require_accepted()
    assert_eq(decision.admission_percent, 80)
    assert_eq(decision.minimum_free_reserve_bytes, reserve)
    assert_eq(decision.required_remaining_bytes, expected_required)
    assert_eq(
      decision.baseline_65_percent_required_remaining_bytes,
      plan.required_remaining_bytes,
    )
    assert_true(decision.budget_bytes <= expected_required - reserve)
    assert_true(
      decision.budget_bytes <=
      expected_required / 100L * 80L + expected_required % 100L * 80L / 100L,
    )
    for
      (host, cuda) in [
        (expected_required - 1L, expected_required),
        (expected_required, expected_required - 1L),
      ] {
      let no = @learning_native_admission.assess(
        plan,
        host,
        cuda,
        memory_admission_percent=80,
      )
      assert_true(!no.accepted)
      try no.require_accepted() catch {
        _ => ()
      } noraise {
        _ => fail("explicit admission ignored percentage or reserve boundary")
      }
    }
  }
  let exhausted = @learning_native_admission.assess(
    reserve_limited,
    reserve - 1L,
    reserve - 1L,
    memory_admission_percent=80,
  )
  assert_eq(exhausted.budget_bytes, 0L)
  assert_true(!exhausted.accepted)
  let maximum = @learning_native_admission.assess(
    reserve_limited,
    9223372036854775807L,
    9223372036854775807L,
    memory_admission_percent=80,
  )
  assert_eq(maximum.budget_bytes, 7378697629483820645L)
  for percent in [64, 81, -1, 2147483647] {
    try
      @learning_native_admission.assess(
        reserve_limited,
        reserve,
        reserve,
        memory_admission_percent=percent,
      )
    catch {
      _ => ()
    } noraise {
      _ => fail("out-of-range explicit admission accepted")
    }
  }
}

///|
test "actor decoded compatibility budget follows bounded starts without shrinking logical data" {
  let base = fixture()
  for batch in [1, 255, 256, 257, 4096] {
    let learner = { ..base.learner, policy_batch: batch, }
    let plan = @learning_native_admission.plan_paper_stream({
      ..base,
      learner,
      actor_microbatch: 0,
    })
    let block = batch.min(256).to_int64()
    assert_eq(
      plan.counts["actor_decoded_transition_count_per_block"],
      block * 11L,
    )
    assert_eq(
      plan.counts["actor_sampled_transition_count_upper"],
      batch.to_int64() * 11L,
    )
    assert_eq(
      plan.counts["actor_selected_start_index_bytes"],
      batch.to_int64() * 4L,
    )
    assert_eq(plan.counts["policy_reference_frames"], batch.to_int64() * 33L)
    assert_eq(plan.counts["critic_minibatch_rows"], batch.to_int64() * 32L / 4L)
  }
  let plan = @learning_native_admission.plan_paper_stream(base)
  // Keep every other existing term, including the conservative replay-candidate
  // scratch and the unchanged per-Transition 128 KiB allowance.
  let shape = @runtime.policy_batch_shape_usage(
    base.learner,
    base.learner.policy_batch,
    base.observation_mode,
    limits=@runtime.BatchLimits::paper_scale(),
  )
  assert_eq(
    plan.phases[2].components["sampled_start_objects_and_block_upload"],
    2816L * 131072L +
    16384L +
    shape.assembled_values_per_block * 32L +
    shape.reference_state_values_per_block * 32L +
    shape.critic_permutation_values * 40L +
    shape.noise_values_per_block * 32L +
    plan.counts["replay_records"] * 4L,
  )
}
