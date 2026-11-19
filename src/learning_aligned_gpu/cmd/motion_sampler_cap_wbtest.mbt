///|
test "explicit sampler data cap is strict optional paper mmap capacity" {
  assert_eq(motion_sampler_cap({}, @capacity.Initial, "eager"), None)
  assert_eq(motion_sampler_cap({}, @capacity.Paper4096, "mmap"), None)
  assert_eq(
    motion_sampler_cap(
      { "max_motion_sampler_bins": 9000 },
      @capacity.Paper4096,
      "mmap",
    ),
    Some(9000),
  )
  assert_eq(motion_sampler_bins_for_plan(None, None), 43149672)
  assert_eq(motion_sampler_bins_for_plan(Some(9000), None), 9000)
  assert_eq(motion_sampler_bins_for_plan(Some(9000), Some(8842)), 8842)
  assert_eq(motion_sampler_bins_for_plan(Some(9000), Some(9000)), 9000)
  for
    invalid in [
      Json(0),
      Json(-1),
      Json(43149673),
      Json(1.5),
      Json("9000"),
      Json(true),
      Json::null(),
    ] {
    try
      motion_sampler_cap(
        { "max_motion_sampler_bins": invalid },
        @capacity.Paper4096,
        "mmap",
      )
    catch {
      _ => ()
    } noraise {
      _ => fail("invalid explicit sampler cap accepted")
    }
  }
  for
    (profile, storage) in [
      (@capacity.Initial, "mmap"),
      (@capacity.Paper4096, "eager"),
    ] {
    try
      motion_sampler_cap({ "max_motion_sampler_bins": 9000 }, profile, storage)
    catch {
      _ => ()
    } noraise {
      _ => fail("unsupported sampler cap route accepted")
    }
  }
  for count in [0, 9001, 43149672] {
    try motion_sampler_bins_for_plan(Some(9000), Some(count)) catch {
      _ => ()
    } noraise {
      _ => fail("invalid actual bin count clipped instead of refused")
    }
  }
}

///|
test "9000-bin admission preserves guards and charges its enforced data capacity" {
  let config : Json = {
    "capacity_profile": "paper-4096",
    "memory_admission_percent": 80,
    "num_envs": 256,
    "buffer_steps": 1000,
    "wm_batch": 2048,
    "pi_batch": 4096,
    "pi_microbatch": 512,
    "wm_hidden": [2048, 2048, 2048],
    "pi_hidden": [2048, 1024, 512, 256],
    "critic_hidden": [256, 128],
    "observation_mode": "smc",
    "serial_optimizer_save_workspace": true,
  }
  let args = [
    "aligned-gpu", "preflight", "--checkpoint-format", "stream-v2", "--cuda-memory-telemetry",
  ]
  let original = settings(config, args)
  guard config is Object(fields) else { fail("config") }
  fields["max_motion_sampler_bins"] = 9000
  let capped = settings(config, args)
  let physical : PhysicsPreflight = {
    manifest_sha256: "5125dd55906ec0e5ffc9669007f60266137ee866c3b528574f6a11e6fa325c9b",
    bundle_bytes: 230465552L,
    shared_region_bytes: 47905609L,
    largest_file_bytes: 1L,
    manifest_bytes: 106611L,
    manifest_identity: Json::null(),
  }
  let host = 107374182400L
  let cuda = Some(100000000000L)
  let old = estimate_memory(
    original,
    host,
    cuda,
    physical~,
    include_restore=false,
    motion_manifest_bytes=38601L,
  )
  let planned = estimate_memory(
    capped,
    host,
    cuda,
    physical~,
    include_restore=false,
    motion_manifest_bytes=38601L,
  )
  let actual = estimate_memory(
    capped,
    host,
    cuda,
    physical~,
    include_restore=false,
    motion_manifest_bytes=38601L,
    sampler_bins=8842,
  )
  assert_eq(old.peak_bytes, 61485916048L)
  assert_eq(planned.peak_bytes, 57862099600L)
  assert_eq(actual.peak_bytes, 57862086328L)
  assert_eq(planned.peak_bytes - actual.peak_bytes, 13272L)
  assert_eq(planned.admission_decision.unwrap().admission_percent, 80)
  assert_eq(
    planned.admission_decision.unwrap().minimum_free_reserve_bytes,
    17179869184L,
  )
  assert_eq(planned.budget_bytes, old.budget_bytes)
  assert_eq(
    planned.phase_plan.unwrap().counts["save_optimizer_archive_bound_bytes"],
    1610612736L,
  )
  try
    estimate_memory(
      capped,
      host,
      cuda,
      physical~,
      include_restore=false,
      motion_manifest_bytes=38601L,
      sampler_bins=9001,
    )
  catch {
    _ => ()
  } noraise {
    _ => fail("actual catalog exceeded admitted cap without refusal")
  }
}
