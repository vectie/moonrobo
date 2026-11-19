///|
fn operator_fixture() -> @learning_native_admission.Inputs {
  {
    ..fixture(),
    environments: 256,
    world_microbatch: 0,
    actor_microbatch: 512,
    sampler_bins: 9000,
    motion_manifest_bytes: 38601L,
    environment_payload_bytes: 0L,
    apic_manifest_bytes: 106611L,
    apic_payload_bytes: 230465552L,
    apic_shared_union_bytes: 47905609L,
    restore_saved_rows: 0,
  }
}

///|
fn operator_rejects(run : () -> @learning_native_admission.Plan raise) -> Bool {
  try {
    ignore(run())
    false
  } catch {
    _ => true
  }
}

///|
test "operator diagnostic retains all three training phases without mutating source" {
  let source = @learning_native_admission.plan_paper_stream(
    operator_fixture(),
    include_restore=false,
    serial_optimizer_save_workspace=true,
  )
  let original = Json(source)
  let projected = source.for_operator_diagnostic()
  assert_eq(projected.phases.length(), 3)
  for i in 0..<3 {
    assert_eq(Json(projected.phases[i]), Json(source.phases[i]))
  }
  assert_eq(Json(source), original)
  assert_eq(projected.peak_phase, "train_actor_and_critic")
  assert_eq(projected.peak_bytes, source.phases[2].envelope_bytes)
  assert_eq(
    projected.device_phase_working_bytes,
    source.device_phase_working_bytes,
  )
  assert_eq(
    projected.minimum_output_free_bytes,
    source.minimum_output_free_bytes,
  )
  assert_eq(
    projected.checkpoint_generation_bytes,
    source.checkpoint_generation_bytes,
  )
  assert_eq(projected.counts["operator_diagnostic_only"], 1L)
  // Mutable diagnostic maps must not alias the retained source plan.
  projected.phases[0].components["fixture_only"] = 1L
  projected.device_phase_working_bytes["fixture_only"] = 1L
  projected.counts["fixture_only"] = 1L
  projected.assumptions.push("fixture only")
  assert_eq(Json(source), original)
}

///|
test "operator diagnostic refuses restore repeated projection and reserve before projection" {
  let source = @learning_native_admission.plan_paper_stream(
    operator_fixture(),
    include_restore=false,
  )
  assert_true(
    operator_rejects(() => {
      source.for_operator_diagnostic().for_operator_diagnostic()
    }),
  )
  let restore = @learning_native_admission.plan_paper_stream(operator_fixture())
  assert_true(operator_rejects(() => restore.for_operator_diagnostic()))
  let reserved = source.with_execution_reserve({ "execution_probe": 1L })
  assert_true(operator_rejects(() => reserved.for_operator_diagnostic()))
  let distributed = @learning_native_admission.plan_paper_stream(
    { ..operator_fixture(), distributed: true, },
    include_restore=false,
  )
  assert_true(operator_rejects(() => distributed.for_operator_diagnostic()))
}

///|
test "operator diagnostic six reserve and four GiB retain exact admission guards" {
  let source = @learning_native_admission.plan_paper_stream(
    operator_fixture(),
    include_restore=false,
    serial_optimizer_save_workspace=true,
  )
  let projected = source.for_operator_diagnostic()
  let reserved = projected.with_execution_reserve({
    "execution_six_fixture": 3778758656L,
    "execution_operator_diagnostics": 4294967296L,
  })
  assert_eq(reserved.peak_bytes, 60455485328L)
  for i, p in projected.phases {
    assert_eq(reserved.phases[i].envelope_bytes, p.envelope_bytes + 8073725952L)
    for name, value in p.components {
      assert_eq(reserved.phases[i].components[name], value)
    }
  }
  let required = 77635354512L
  let accepted = @learning_native_admission.assess(
    reserved,
    required,
    required,
    memory_admission_percent=80,
  )
  assert_true(accepted.accepted)
  assert_eq(accepted.required_remaining_bytes, required)
  assert_eq(accepted.minimum_free_reserve_bytes, 17179869184L)
  assert_eq(accepted.admission_percent, 80)
  assert_true(
    !@learning_native_admission.assess(
      reserved,
      required - 1L,
      required,
      memory_admission_percent=80,
    ).accepted,
  )
  assert_true(
    !@learning_native_admission.assess(
      reserved,
      required,
      required - 1L,
      memory_admission_percent=80,
    ).accepted,
  )
  assert_true(
    operator_rejects(() => {
      reserved.with_execution_reserve({
        "execution_operator_diagnostics": 4294967296L,
      })
    }),
  )
}
