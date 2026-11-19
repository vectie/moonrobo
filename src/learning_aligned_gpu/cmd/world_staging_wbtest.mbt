///|
fn[A] staging_test_result(run : () -> A raise) -> Result[A, Error] {
  Ok(run()) catch {
    error => Err(error)
  }
}

///|
test "world logical staging is strict opt-in and adds full bounded reserve" {
  assert_true(world_staging_request({}) is None)
  assert_eq(
    world_staging_request({ "world_staging_batch": true }),
    Some(134217728L),
  )
  for
    config in (
      [
        { "world_staging_batch": "true" },
        { "world_staging_batch": 1 },
        { "world_staging_max_mib": 0 },
        { "world_staging_max_mib": 4097 },
        { "world_staging_max_mib": 1.5 },
        { "world_staging_max_mib": "128" },
      ] : Array[Json]) {
    assert_true(
      staging_test_result(() => world_staging_request(config)) is Err(_),
    )
  }
  let baseline = settings({}, [])
  let candidate = settings({ "world_staging_batch": true }, [])
  let extra = optimization_memory_extra(candidate)
  assert_true(optimization_memory_extra(baseline).is_empty())
  assert_eq(extra.length(), 1)
  assert_eq(extra["execution_world_logical_staging"], 6782976L)
  let old = estimate_memory(baseline, 1099511627776L, Some(1099511627776L))
  let revised = estimate_memory(candidate, 1099511627776L, Some(1099511627776L))
  assert_eq(
    revised.peak_bytes - old.peak_bytes,
    extra["execution_world_logical_staging"],
  )
  assert_true(
    staging_test_result(() => {
      settings({ "world_staging_batch": true, "world_staging_max_mib": 1 }, [])
    })
    is Err(_),
  )
  let config : Json = {
    "capacity_profile": "paper-4096",
    "wm_batch": 2048,
    "world_staging_batch": true,
    "world_staging_max_mib": 128,
  }
  let paper = settings(config, ["--checkpoint-format", "stream-v2"])
  assert_eq(
    optimization_memory_extra(paper)["execution_world_logical_staging"],
    107544576L,
  )
  let paper_base = { ..paper, world_staging_max_bytes: None, }
  let before = estimate_memory(paper_base, 1099511627776L, Some(1099511627776L))
  let after = estimate_memory(paper, 1099511627776L, Some(1099511627776L))
  guard before.phase_plan is Some(a) && after.phase_plan is Some(b) else {
    fail("missing paper phase plan")
  }
  for i in 0..<a.phases.length() {
    assert_eq(
      b.phases[i].envelope_bytes - a.phases[i].envelope_bytes,
      107544576L,
    )
  }
}
