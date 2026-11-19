///|
fn operator_diagnostic_source_fixture() -> Plan raise {
  plan_paper_stream(
    {
      profile: @capacity.Paper4096,
      checkpoint_format: "stream-v2",
      environments: 256,
      replay_steps: 1000,
      learner: @aligned.LearnerConfig::default(),
      observation_mode: @aligned.Smc,
      world_microbatch: 0,
      actor_microbatch: 0,
      sampler_bins: 9000,
      motion_manifest_bytes: 38601L,
      catalog_json_bytes: 67108864L,
      state_json_bytes: 4194304L,
      environment_payload_bytes: 0L,
      apic_manifest_bytes: 106611L,
      apic_payload_bytes: 230465552L,
      apic_shared_union_bytes: 47905609L,
      restore_live_rows: 0,
      restore_saved_rows: 0,
      restore_optimizer_archive_bytes: 0L,
      distributed: false,
    },
    include_restore=false,
  )
}

///|
fn operator_diagnostic_rejects(run : () -> Plan raise) -> Bool {
  try {
    ignore(run())
    false
  } catch {
    _ => true
  }
}

///|
test "operator diagnostic rejects malformed phase lists and altered envelopes" {
  let source = operator_diagnostic_source_fixture()
  let missing : Plan = { ..source, phases: source.phases[:4].to_owned(), }
  let duplicate : Plan = {
    ..source,
    phases: [
      source.phases[0],
      source.phases[0],
      source.phases[2],
      source.phases[3],
      source.phases[4],
    ],
  }
  let reordered : Plan = {
    ..source,
    phases: [
      source.phases[1],
      source.phases[0],
      source.phases[2],
      source.phases[3],
      source.phases[4],
    ],
  }
  let altered_phases = source.phases.copy()
  altered_phases[2] = {
    ..source.phases[2],
    envelope_bytes: source.phases[2].envelope_bytes - 1L,
  }
  let altered : Plan = { ..source, phases: altered_phases, }
  let wrong_peak : Plan = { ..source, peak_bytes: source.peak_bytes - 1L, }
  let wrong_schema : Plan = { ..source, format: "untrusted", }
  for
    candidate in [
      missing, duplicate, reordered, altered, wrong_peak, wrong_schema,
    ] {
    assert_true(
      operator_diagnostic_rejects(() => candidate.for_operator_diagnostic()),
    )
  }
  let components = source.phases[0].components.copy()
  components["physics_scene_working_floor"] = -1L
  let invalid_phases = source.phases.copy()
  invalid_phases[0] = { ..source.phases[0], components, }
  let invalid : Plan = { ..source, phases: invalid_phases, }
  assert_true(
    operator_diagnostic_rejects(() => invalid.for_operator_diagnostic()),
  )
}
