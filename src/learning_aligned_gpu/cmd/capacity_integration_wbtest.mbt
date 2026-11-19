///|
fn paper_capacity_config() -> Json {
  {
    "capacity_profile": "paper-4096",
    "num_envs": 4096,
    "wm_batch": 2048,
    "pi_batch": 4096,
    "buffer_steps": 1000,
  }
}

///|
test "paper capacity is explicit and requires streaming before allocation" {
  let config = paper_capacity_config()
  assert_true((Ok(settings(config, [])) catch { e => Err(e) }) is Err(_))
  assert_true(
    (Ok(settings(config, ["--checkpoint-format", "v1"])) catch { e => Err(e) })
    is Err(_),
  )
  let s = settings(config, ["--checkpoint-format", "stream-v2"])
  assert_eq(s.capacity_profile, @capacity.Paper4096)
  assert_eq(s.environments, 4096)
  assert_eq(s.learner.wm_batch, 2048)
  assert_eq(s.learner.policy_batch, 4096)
  assert_eq(s.replay_steps, 1000)
  assert_eq(s.limits.max_reference_frames, 135168)
  assert_eq(s.limits.max_tensor_values, 127016960L)
  assert_eq(s.batch_execution.actor_microbatch, 0)
  assert_true(
    (Ok(settings({ "num_envs": 129 }, [])) catch { e => Err(e) }) is Err(_),
  )
  for value in [Json::null(), Json(true), Json("paper"), Json(4096)] {
    assert_true(
      (Ok(
        settings({ "capacity_profile": value }, [
          "--checkpoint-format", "stream-v2",
        ]),
      ) catch {
        e => Err(e)
      })
      is Err(_),
    )
  }
}

///|
test "paper physical artifact cannot silently select a larger capacity" {
  let config = paper_capacity_config()
  let s = settings(config, ["--checkpoint-format", "stream-v2"])
  let metadata : Json = {
    "num_envs": 4096,
    "self_collisions": true,
    "control_dt_s": 0.02,
    "physics_dt_s": 0.005,
    "num_substeps": 4,
    "files": [{ "path": "step.wrp" }],
    "shared_regions": [{ "bytes": 805306368 }],
  }
  assert_true(
    (Ok(validate_physics_metadata(metadata, s, config)) catch { e => Err(e) })
    is Err(_),
  )
  guard metadata is Object(fields) else { fail("object fixture expected") }
  fields["capacity_profile"] = "paper-4096"
  assert_eq(validate_physics_metadata(metadata, s, config).1, 805306368L)
  fields["capacity_profile"] = Json::null()
  assert_true(
    (Ok(validate_physics_metadata(metadata, s, config)) catch { e => Err(e) })
    is Err(_),
  )
}

///|
test "paper memory admission retains full batches and refuses unknown or low free memory" {
  let s = settings(paper_capacity_config(), ["--checkpoint-format", "stream-v2"])
  assert_true(
    (Ok(estimate_memory(s, 1073741824L, Some(1073741824L))) catch {
      e => Err(e)
    })
    is Err(_),
  )
  assert_true(
    (Ok(estimate_memory(s, 1099511627776L, None)) catch { e => Err(e) })
    is Err(_),
  )
  let plan = estimate_memory(
    s,
    1099511627776L,
    Some(1099511627776L),
    sampler_bins=100,
  )
  guard plan.phase_plan is Some(phases) else {
    fail("paper phase plan missing")
  }
  assert_eq(phases.counts["actor_active_microbatch"], 4096L)
  assert_eq(phases.counts["world_active_microbatch"], 2048L)
  assert_eq(phases.counts["replay_primitive_payload_bytes"], 7708672000L)
  assert_eq(plan.budget_bytes, 1099511627776L * 65L / 100L)
  assert_true(
    plan.components["host_checkpoint_stream_publication_headroom"] >=
    1073741824L,
  )
  assert_eq(
    plan.components["minimum_output_free_bytes"],
    phases.minimum_output_free_bytes,
  )
}

///|
test "paper evaluation budgets physical replicas while initial reserves remain unchanged" {
  let initial = settings({}, [])
  assert_eq(evaluation_reserve(initial, None, 1L), 28L * 1073741824L)
  let s = settings(paper_capacity_config(), ["--checkpoint-format", "stream-v2"])
  assert_true(
    (Ok(evaluation_reserve(s, None, 1L)) catch { e => Err(e) }) is Err(_),
  )
  let physical : PhysicsPreflight = {
    manifest_sha256: "unused-for-pure-capacity-test",
    bundle_bytes: 1073741824L,
    shared_region_bytes: 805306368L,
    largest_file_bytes: 268435456L,
    manifest_bytes: 2097152L,
    manifest_identity: Json::null(),
  }
  let unknown = evaluation_reserve(s, Some(physical), 90208329L)
  let measured = evaluation_reserve(
    s,
    Some(physical),
    90208329L,
    sampler_bins=1000000,
  )
  assert_true(unknown > measured)
  assert_true(measured > 32L * 1073741824L)
  assert_true(
    (Ok(evaluation_reserve(s, Some(physical), 268435457L)) catch {
      e => Err(e)
    })
    is Err(_),
  )
}
