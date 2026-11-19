///|
async test "APIC runtime gate retains 24 GiB reserve and requires over 16 GiB admission" {
  let config = bounded_json(
    "examples/learning/g1-native-tensor-apic-runtime-gate.json", 1048576L,
  )
  let s = settings(config, [])
  assert_eq(s.environments, 2)
  assert_eq(s.learner.horizon, 32)
  assert_eq(s.learner.wm_window, 8)
  assert_eq(s.learner.wm_batches, 1)
  assert_eq(s.learner.critic_epochs * s.learner.critic_minibatches, 4)
  let gib = 1073741824L
  let plan = estimate_memory(s, 48L * gib, Some(100L * gib))
  assert_eq(plan.components["physics_scene_reserve"], 24L * gib)
  assert_eq(plan.peak_bytes, 30930712096L)
  try estimate_memory(s, 16L * gib, Some(100L * gib)) catch {
    _ => ()
  } noraise {
    _ => fail("APIC gate must not bypass original memory reserve")
  }
}

///|
test "APIC preflight rejects world collision timestep and region mismatches before CUDA" {
  let config : Json = { "num_envs": 2, "self_collisions": false }
  let s = settings(config, [])
  let valid : Json = {
    "num_envs": 2,
    "self_collisions": false,
    "control_dt_s": 0.02,
    "physics_dt_s": 0.005,
    "num_substeps": 4,
    "files": [{ "path": "step.wrp" }],
    "shared_regions": [{ "bytes": 64 }],
  }
  let (_, bytes) = validate_physics_metadata(valid, s, config)
  assert_eq(bytes, 64L)
  for
    (name, value) in [
      ("num_envs", Json(3)),
      ("self_collisions", Json(true)),
      ("physics_dt_s", Json(0.01)),
      ("shared_regions", Json([{ "bytes": 268435457 }])),
    ] {
    guard valid is Object(fields) else { fail("test metadata must be object") }
    let bad = fields.copy()
    bad[name] = value
    try validate_physics_metadata(Json(bad), s, config) catch {
      _ => ()
    } noraise {
      _ => fail("unsafe or incompatible APIC metadata accepted")
    }
  }
}

///|
test "distributed launch schedule includes resolved overrides separately from run identity" {
  let original = settings(Json::empty_object(), [])
  let extended = settings(Json::empty_object(), ["--iterations", "2"])
  let identity : Json = { "unchanged_durable_identity": true }
  assert_true(
    distributed_launch_identity(identity, original) !=
    distributed_launch_identity(identity, extended),
  )
  let changed_checkpoint = {
    ..original,
    checkpoint_every: original.checkpoint_every + 1,
  }
  assert_true(
    distributed_launch_identity(identity, original) !=
    distributed_launch_identity(identity, changed_checkpoint),
  )
  let receipt : GenerationReceipt = @json.from_json({
    "format": "moonrobo.native-tensor-checkpoint-pointer.v1",
    "generation": "generation-1-old",
    "iteration": 1,
    "files": {},
  })
  assert_true(receipt.shared_state_digest is None)
}

///|
test "microbatch settings keep logical batches and bind launch identity" {
  let default = settings({ "wm_batch": 4, "pi_batch": 6 }, [])
  assert_eq(default.batch_execution.world_microbatch, 0)
  assert_eq(default.batch_execution.actor_microbatch, 0)
  let split = settings(
    { "wm_batch": 4, "pi_batch": 6, "wm_microbatch": 2, "pi_microbatch": 3 },
    [],
  )
  assert_eq(split.learner.wm_batch, 4)
  assert_eq(split.learner.policy_batch, 6)
  assert_eq(split.batch_execution.world_microbatch, 2)
  assert_eq(split.batch_execution.actor_microbatch, 3)
  let gib = 1073741824L
  assert_eq(
    estimate_memory(default, 100L * gib, Some(64L * gib)).peak_bytes,
    estimate_memory(split, 100L * gib, Some(64L * gib)).peak_bytes,
  )
  let full_identity : Json = {
    "batch_execution": Json(default.batch_execution),
  }
  let split_identity : Json = { "batch_execution": Json(split.batch_execution) }
  assert_true(full_identity != split_identity)
  assert_true(
    distributed_launch_identity(full_identity, default) !=
    distributed_launch_identity(split_identity, split),
  )
  let invalid : Array[Json] = [
    { "wm_batch": 4, "wm_microbatch": -1 },
    { "wm_batch": 4, "wm_microbatch": 5 },
    { "pi_batch": 6, "pi_microbatch": -1 },
    { "pi_batch": 6, "pi_microbatch": 7 },
  ]
  for bad in invalid {
    try settings(bad, []) catch {
      _ => ()
    } noraise {
      _ => fail("microbatch outside original logical batch accepted")
    }
  }
}

///|
async test "bounded JSON reads exact checked size" {
  let root = @fs.tmpdir(prefix="moonrobo-bounded-json-")
  defer @fs.rmdir(root, recursive=true)
  let path = root + "/config.json"
  @fs.write_file(path, "{\"wm_microbatch\":2}", create_mode=CreateNew)
  let value = bounded_json(path, 19L)
  assert_eq(setting(value, "wm_microbatch", 0), 2)
  try bounded_json(path, 18L) catch {
    _ => ()
  } noraise {
    _ => fail("bounded JSON accepted a file above its byte limit")
  }
}

///|
test "native memory preflight uses available memory and refuses exhaustion" {
  assert_eq(
    memory_available("MemTotal: 128000000 kB\nMemAvailable:   64000000 kB\n"),
    65536000000L,
  )
  try memory_available("MemFree: 500 kB\n") catch {
    _ => ()
  } noraise {
    _ => fail("missing availability must fail closed")
  }
  try memory_available("MemAvailable: 100 MB\n") catch {
    _ => ()
  } noraise {
    _ => fail("unexpected unit must fail closed")
  }
  let s = settings(Json::empty_object(), [])
  let gib = 1073741824L
  let plan = estimate_memory(s, 100L * gib, Some(64L * gib))
  assert_eq(plan.budget_bytes, 64L * gib * 65L / 100L)
  assert_true(plan.peak_bytes > 24L * gib)
  assert_eq(
    plan.components["host_replay_and_json_checkpoint_envelope"],
    128L * 128L * 131072L,
  )
  try estimate_memory(s, 100L * gib, Some(10L * gib)) catch {
    _ => ()
  } noraise {
    _ => fail("CUDA free memory below envelope must reject")
  }
  try estimate_memory(s, 8L * gib, Some(100L * gib)) catch {
    _ => ()
  } noraise {
    _ => fail("host/cgroup constraint must also reject")
  }
}

///|
test "paper CLI memory mode distinguishes fresh save from resume at admission boundary" {
  let s = settings(
    {
      "capacity_profile": "paper-4096",
      "num_envs": 256,
      "buffer_steps": 1000,
      "wm_batch": 2048,
      "pi_batch": 4096,
      "wm_microbatch": 256,
      "pi_microbatch": 256,
      "wm_hidden": [2048, 2048, 2048],
      "pi_hidden": [2048, 1024, 512, 256],
      "critic_hidden": [256, 128],
      "observation_mode": "paper",
    },
    ["--checkpoint-format", "stream-v2"],
  )
  let physical : PhysicsPreflight = {
    manifest_sha256: "40e166ab973ba7ae11c2587a9e26d990f52b77d10ef230caee303e06203ae2e8",
    bundle_bytes: 258682953L,
    shared_region_bytes: 54331573L,
    largest_file_bytes: 55397185L,
    manifest_bytes: 107393L,
    manifest_identity: Json::null(),
  }
  let fresh = estimate_memory(
    s,
    1099511627776L,
    Some(1099511627776L),
    physical~,
    include_restore=false,
    sampler_bins=8842,
    motion_manifest_bytes=38601L,
  ).phase_plan.unwrap()
  let resume = estimate_memory(
    s,
    1099511627776L,
    Some(1099511627776L),
    physical~,
    sampler_bins=8842,
    motion_manifest_bytes=38601L,
  ).phase_plan.unwrap()
  assert_true(!fresh.restore_phases_included)
  assert_true(resume.restore_phases_included)
  assert_eq(fresh.phases.length(), 5)
  assert_eq(resume.phases.length(), 7)
  assert_eq(fresh.required_remaining_bytes, 85808773748L)
  assert_eq(resume.required_remaining_bytes, 87677263705L)
  for (include_restore, plan) in [(false, fresh), (true, resume)] {
    let needed = plan.required_remaining_bytes
    ignore(
      estimate_memory(
        s,
        needed,
        Some(needed),
        physical~,
        include_restore~,
        sampler_bins=8842,
        motion_manifest_bytes=38601L,
      ),
    )
    for (host, cuda) in [(needed - 1L, needed), (needed, needed - 1L)] {
      try
        estimate_memory(
          s,
          host,
          Some(cuda),
          physical~,
          include_restore~,
          sampler_bins=8842,
          motion_manifest_bytes=38601L,
        )
      catch {
        _ => ()
      } noraise {
        _ => fail("paper CLI admitted less than its 65 percent phase envelope")
      }
    }
  }
  // A fresh launch still cannot discard the checkpoint-save peak to fit.
  try
    estimate_memory(
      s,
      80063799296L,
      Some(80063799296L),
      physical~,
      include_restore=false,
      sampler_bins=8842,
      motion_manifest_bytes=38601L,
    )
  catch {
    _ => ()
  } noraise {
    _ => fail("fresh launch discarded mandatory save headroom")
  }
  let unknown_sampler = estimate_memory(
    s,
    1099511627776L,
    Some(1099511627776L),
    physical~,
    include_restore=false,
    motion_manifest_bytes=38601L,
  ).phase_plan.unwrap()
  assert_eq(unknown_sampler.required_remaining_bytes, 91383896394L)
  let initial = settings({}, [])
  assert_eq(
    Json(estimate_memory(initial, 1099511627776L, Some(1099511627776L))),
    Json(
      estimate_memory(
        initial,
        1099511627776L,
        Some(1099511627776L),
        include_restore=false,
      ),
    ),
  )
}

///|
test "paper high utilization requires explicit integer policy and stage monitoring" {
  let config = paper_capacity_config()
  guard config is Object(fields) else { fail("object config expected") }
  let args = ["--checkpoint-format", "stream-v2", "--cuda-memory-telemetry"]
  assert_true(settings(config, args).memory_admission_percent is None)
  for percent in [65, 80] {
    let explicit = fields.copy()
    explicit["memory_admission_percent"] = Json(percent)
    assert_eq(
      settings(Json(explicit), args).memory_admission_percent,
      Some(percent),
    )
    for
      invalid_args in [
        ["--checkpoint-format", "stream-v2"],
        ["aligned-gpu", "evaluate", "--cuda-memory-telemetry"],
        ["aligned-gpu", "export", "--cuda-memory-telemetry"],
      ] {
      try settings(Json(explicit), invalid_args) catch {
        _ => ()
      } noraise {
        _ => fail("memory policy accepted without supported monitoring path")
      }
    }
  }
  for
    value in [
      Json(64),
      Json(81),
      Json(65.5),
      Json(79.9),
      Json(true),
      Json("80"),
      Json::null(),
    ] {
    let invalid = fields.copy()
    invalid["memory_admission_percent"] = value
    try settings(Json(invalid), args) catch {
      _ => ()
    } noraise {
      _ => fail("memory policy was rounded, coerced or silently ignored")
    }
  }
  try settings({ "memory_admission_percent": 80 }, args) catch {
    _ => ()
  } noraise {
    _ => fail("initial capacity silently enabled paper admission policy")
  }
}

///|
test "paper high utilization reports actual decision while preserving baseline and phases" {
  let config : Json = {
    "capacity_profile": "paper-4096",
    "num_envs": 256,
    "buffer_steps": 1000,
    "wm_batch": 2048,
    "pi_batch": 4096,
    "wm_microbatch": 256,
    "pi_microbatch": 256,
    "wm_hidden": [2048, 2048, 2048],
    "pi_hidden": [2048, 1024, 512, 256],
    "critic_hidden": [256, 128],
    "observation_mode": "paper",
  }
  let args = ["--checkpoint-format", "stream-v2", "--cuda-memory-telemetry"]
  let original = settings(config, args)
  guard config is Object(fields) else { fail("object config expected") }
  let explicit = fields.copy()
  explicit["memory_admission_percent"] = Json(80)
  let opted_in = settings(Json(explicit), args)
  let physical : PhysicsPreflight = {
    manifest_sha256: "40e166ab973ba7ae11c2587a9e26d990f52b77d10ef230caee303e06203ae2e8",
    bundle_bytes: 258682953L,
    shared_region_bytes: 54331573L,
    largest_file_bytes: 55397185L,
    manifest_bytes: 107393L,
    manifest_identity: Json::null(),
  }
  for include_restore in [false, true] {
    let baseline = estimate_memory(
      original,
      1099511627776L,
      Some(1099511627776L),
      physical~,
      include_restore~,
      motion_manifest_bytes=38601L,
    )
    let actual = estimate_memory(
      opted_in,
      90500000000L,
      Some(90500000000L),
      physical~,
      include_restore~,
      motion_manifest_bytes=38601L,
    )
    assert_eq(Json(baseline.phase_plan), Json(actual.phase_plan))
    let decision = actual.admission_decision.unwrap()
    assert_eq(decision.admission_percent, 80)
    assert_eq(decision.minimum_free_reserve_bytes, 17179869184L)
    assert_eq(actual.budget_bytes, 72400000000L)
    assert_eq(actual.budget_bytes, decision.budget_bytes)
    assert_eq(
      decision.required_remaining_bytes,
      actual.peak_bytes + 17179869184L,
    )
    assert_eq(
      decision.baseline_65_percent_required_remaining_bytes,
      actual.phase_plan.unwrap().required_remaining_bytes,
    )
    assert_true(
      decision.required_remaining_bytes <
      decision.baseline_65_percent_required_remaining_bytes,
    )
    let needed = decision.required_remaining_bytes
    ignore(
      estimate_memory(
        opted_in,
        needed,
        Some(needed),
        physical~,
        include_restore~,
        motion_manifest_bytes=38601L,
      ),
    )
    for (host, cuda) in [(needed - 1L, needed), (needed, needed - 1L)] {
      try
        estimate_memory(
          opted_in,
          host,
          Some(cuda),
          physical~,
          include_restore~,
          motion_manifest_bytes=38601L,
        )
      catch {
        _ => ()
      } noraise {
        _ => fail("CLI high utilization lost actual 16 GiB reserve")
      }
    }
  }
}

///|
test "native profile rejects oversized batches alternate devices and unsupported precision" {
  let bad : Array[Json] = [
    { "num_envs": 129 },
    { "pi_batch": 4096 },
    { "buffer_steps": 1000 },
    { "reference_storage": "eager" },
    { "distributed": true },
    { "amp": "fp16" },
    { "precision": "float64" },
    { "device": "cuda:-1" },
    { "physics_device_id": 1 },
    { "randomization": false },
  ]
  for config in bad {
    try settings(config, []) catch {
      _ => ()
    } noraise {
      _ => fail("unsafe native profile accepted")
    }
  }
  let cpu : Json = {
    "device": "cpu",
    "backend": "mujoco",
    "num_envs": 1,
    "pi_batch": 2,
    "wm_batch": 2,
    "horizon": 2,
    "wm_window": 2,
    "wm_hidden": [4],
    "pi_hidden": [4],
    "critic_hidden": [4],
  }
  assert_eq(settings(cpu, []).device, -1)
}

///|
async test "cgroup constraint applies max minus current and recognizes unlimited" {
  let directory = @fs.tmpdir(prefix="moonrobo-native-memory-test-")
  defer @fs.rmdir(directory, recursive=true)
  @fs.write_file(directory + "/memory.max", "4096\n", create_mode=CreateNew)
  @fs.write_file(directory + "/memory.current", "1024\n", create_mode=CreateNew)
  assert_eq(constrain_cgroup(10000L, directory, true), 3072L)
  assert_eq(constrain_cgroup(2048L, directory, true), 2048L)
  @fs.write_file(
    directory + "/memory.max",
    "max\n",
    create_mode=TruncateExisting,
  )
  assert_eq(constrain_cgroup(10000L, directory, true), 10000L)
  @fs.write_file(
    directory + "/memory.max",
    "512\n",
    create_mode=TruncateExisting,
  )
  assert_eq(constrain_cgroup(10000L, directory, true), 0L)
}

///|
test "distributed profile requires explicit fresh two-rank CUDA setup and rejects resume" {
  let args = [
    "--distributed", "--rank", "1", "--world-size", "2", "--nccl-id-file", "/temporary/id.json",
    "--session-id", "native-gate-20261024-unique",
  ]
  let config : Json = { "backend": "mujoco" }
  let s = settings(config, args)
  assert_eq(s.distributed.unwrap().rank, 1)
  assert_eq(s.distributed.unwrap().world_size, 2)
  let plan = estimate_memory(s, 100L * 1073741824L, Some(64L * 1073741824L))
  assert_eq(plan.components["distributed_communicator_staging"], 1073741824L)
  for
    extra in [["--resume", "/tmp/current.json"], ["--nccl-timeout-ms", "60001"]] {
    let invalid = args.copy()
    invalid.append(extra)
    try settings(config, invalid) catch {
      _ => ()
    } noraise {
      _ => fail("invalid distributed settings accepted")
    }
  }
  try settings({ "device": "cpu", "backend": "mujoco" }, args) catch {
    _ => ()
  } noraise {
    _ => fail("CPU distributed configuration accepted")
  }
  assert_true(unix_milliseconds() > 0L)
}

///|
test "NCCL rendezvous refuses stale sessions wrong sizes and host clock skew" {
  let settings : DistributedSettings = {
    rank: 1,
    world_size: 2,
    id_file: "/unused",
    session_id: "native-gate-20261024-unique",
    timeout_ms: 30000,
    data_ready_timeout_seconds: None,
  }
  let value : RendezvousFile = {
    format: "moonrobo.native-nccl-rendezvous.v1",
    session_id: settings.session_id,
    world_size: 2,
    created_unix_ms: 100000L,
    expires_unix_ms: 130000L,
    id: Array::makei(128, i => i),
  }
  assert_eq(validate_rendezvous(value, settings, 110000L).length(), 128)
  let invalid = [
    { ..value, session_id: "other-session-20261024", },
    { ..value, world_size: 3, },
    { ..value, id: [1, 2], },
    { ..value, id: Array::make(128, 256), },
    { ..value, expires_unix_ms: 120000L, },
    { ..value, created_unix_ms: 125000L, expires_unix_ms: 155000L, },
  ]
  for wrong in invalid {
    try validate_rendezvous(wrong, settings, 110000L) catch {
      _ => ()
    } noraise {
      _ => fail("invalid rendezvous accepted")
    }
  }
  try validate_rendezvous(value, settings, 130000L) catch {
    _ => ()
  } noraise {
    _ => fail("expired rendezvous accepted")
  }
}

///|
async test "robot asset identity is independent of host root and includes nested meshes" {
  let root = @fs.tmpdir(prefix="moonrobo-native-asset-identity-")
  defer @fs.rmdir(root, recursive=true)
  for name in ["left", "right"] {
    @fs.mkdir(root + "/" + name + "/meshes", recursive=true)
    @fs.write_file(
      root + "/" + name + "/scene.xml",
      "<mujoco/>",
      create_mode=CreateNew,
    )
    @fs.write_file(
      root + "/" + name + "/meshes/body.bin",
      "same-mesh",
      create_mode=CreateNew,
    )
  }
  let original = scene_assets_hash(root + "/left")
  assert_eq(original, scene_assets_hash(root + "/right"))
  @fs.write_file(
    root + "/right/meshes/body.bin",
    "changed-mesh",
    create_mode=TruncateExisting,
  )
  assert_true(original != scene_assets_hash(root + "/right"))
  @fs.symlink(target=root + "/left/meshes/body.bin", root + "/right/link.bin")
  try scene_assets_hash(root + "/right") catch {
    _ => ()
  } noraise {
    _ => fail("unhashed symlink accepted")
  }
}
