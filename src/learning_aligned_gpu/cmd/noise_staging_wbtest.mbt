///|
test "noise staging and actor snapshots are explicit bounded additions" {
  assert_true(noise_staging_request({}) is None)
  assert_eq(
    noise_staging_request({ "noise_staging_batch": true }),
    Some(16777216L),
  )
  for
    config in (
      [
        { "noise_staging_batch": "true" },
        { "noise_staging_max_mib": 0 },
        { "noise_staging_max_mib": 257 },
        { "noise_staging_max_mib": 1.5 },
        { "noise_staging_max_mib": "16" },
        { "actor_norm_snapshot": 1 },
      ] : Array[Json]) {
    try settings(config, []) catch {
      _ => ()
    } noraise {
      _ => fail("accepted invalid optional execution setting")
    }
  }
  let config : Json = {
    "capacity_profile": "paper-4096",
    "pi_batch": 4096,
    "pi_microbatch": 512,
    "observation_mode": "smc",
    "noise_staging_batch": true,
    "noise_staging_max_mib": 16,
    "actor_norm_snapshot": true,
  }
  let candidate = settings(config, ["--checkpoint-format", "stream-v2"])
  let extra = optimization_memory_extra(candidate)
  assert_eq(extra["execution_noise_logical_staging"], 13244416L)
  assert_eq(extra["execution_actor_norm_snapshot"], 65536L)
  assert_eq(extra.length(), 2)
  let baseline = {
    ..candidate,
    noise_staging_max_bytes: None,
    optimizations: { ..candidate.optimizations, actor_norm_snapshot: false, },
  }
  let a = estimate_memory(baseline, 1099511627776L, Some(1099511627776L))
  let b = estimate_memory(candidate, 1099511627776L, Some(1099511627776L))
  guard a.phase_plan is Some(a) && b.phase_plan is Some(b) else {
    fail("paper phase plan required")
  }
  for i in 0..<a.phases.length() {
    assert_eq(
      b.phases[i].envelope_bytes - a.phases[i].envelope_bytes,
      13309952L,
    )
  }
  guard config is Object(fields) else { fail("test config") }
  fields["noise_staging_max_mib"] = Json(1)
  try settings(config, ["--checkpoint-format", "stream-v2"]) catch {
    _ => ()
  } noraise {
    _ => fail("staging cap admitted insufficient extra reserve")
  }
}

///|
test "inference projection drops training-only sampler and actor execution options" {
  let projected = evaluation_runtime_config({
    "max_motion_sampler_bins": 9000,
    "noise_staging_batch": true,
    "noise_staging_max_mib": 16,
    "actor_norm_snapshot": true,
  })
  guard projected is Object(fields) else { fail("projected config") }
  for
    key in [
      "max_motion_sampler_bins", "noise_staging_batch", "noise_staging_max_mib",
      "actor_norm_snapshot",
    ] {
    assert_false(fields.contains(key))
  }
}
