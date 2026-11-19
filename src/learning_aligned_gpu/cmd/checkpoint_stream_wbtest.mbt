///|
async test "stream storage CPU gate stays within unchanged smoke limits" {
  let config = bounded_json(
    "examples/learning/g1-native-tensor-stream-checkpoint-gate.json", 1048576L,
  )
  let legacy = settings(config, ["--checkpoint-format", "v1"])
  let stream = settings(config, ["--checkpoint-format", "stream-v2"])
  assert_eq(legacy.device, -1)
  assert_eq(legacy.backend, "mujoco")
  assert_eq(legacy.environments, 1)
  assert_eq(legacy.learner.horizon, 4)
  assert_eq(legacy.learner.wm_window, 2)
  assert_eq(legacy.replay_steps, 64)
  assert_eq(legacy.options.warmup_steps, 16)
  assert_eq(Json(legacy.learner), Json(stream.learner))
  assert_eq(
    distributed_launch_identity(Json::null(), legacy),
    distributed_launch_identity(Json::null(), stream),
  )
  assert_false(legacy.learner.observation_noise)
  assert_eq(legacy.options.action_noise, 0.0)
  assert_false(setting(config, "randomization", true))
  assert_false(setting(config, "reset_noise", true))
  assert_false(setting(config, "self_collisions", true))
  let plan = estimate_memory(legacy, 16L * 1073741824L, None)
  assert_eq(plan.budget_bytes, 16L * 1073741824L * 65L / 100L)
}

///|
test "stream checkpoint selection stays opt in and retains memory envelope" {
  assert_true(checkpoint_format([]) == LegacyV1)
  assert_true(checkpoint_format(["--checkpoint-format", "v1"]) == LegacyV1)
  assert_true(
    checkpoint_format(["--checkpoint-format", "stream-v2"]) == StreamV2,
  )
  for
    args in [
      ["--checkpoint-format"],
      ["--checkpoint-format", "v3"],
      ["--checkpoint-format", "v1", "--checkpoint-format", "stream-v2"],
    ] {
    checkpoint_rejects(() => ignore(checkpoint_format(args)))
  }
  let config : Json = {
    "num_envs": 2,
    "buffer_steps": 64,
    "pi_batch": 2,
    "wm_batch": 2,
  }
  let original = settings(config, [])
  let streaming = settings(config, ["--checkpoint-format", "stream-v2"])
  assert_eq(
    Json(
      estimate_memory(original, 128L * 1073741824L, Some(128L * 1073741824L)),
    ),
    Json(
      estimate_memory(streaming, 128L * 1073741824L, Some(128L * 1073741824L)),
    ),
  )
}

///|
async test "checkpoint catalog preserves v1 projection and rejects v2 count fps or digest mismatches" {
  let old : Json = {
    "format": "moonrobo.native-tensor-training-generation.v1",
    "runtime": {
      "motion_names": ["a"],
      "motion_sha256": ["hash"],
      "source_fps": 50,
      "replay": ["not decoded"],
    },
  }
  assert_eq(checkpoint_catalog_json("not-opened", old), {
    "motion_names": ["a"],
    "motion_sha256": ["hash"],
    "source_fps": 50,
  })
  let catalog : Json = {
    "format": "moonrobo.native-runtime-catalog.v2",
    "motion_names": ["a"],
    "motion_sha256": ["hash"],
    "source_fps": 50,
  }
  assert_eq(validate_checkpoint_catalog(catalog, 1, 50.0), catalog)
  checkpoint_rejects(() => ignore(validate_checkpoint_catalog(catalog, 2, 50.0)))
  checkpoint_rejects(() => ignore(validate_checkpoint_catalog(catalog, 1, 60.0)))
  let descriptor : @stream.BlobDescriptor = {
    file: "catalog.json",
    dtype: "u8",
    shape: [2],
    count: 2L,
    byte_length: 2L,
    sha256: "a".repeat(64),
  }
  validate_checkpoint_catalog_descriptor(descriptor, 1, descriptor.sha256)
  checkpoint_rejects(() => {
    validate_checkpoint_catalog_descriptor(descriptor, 1, "b".repeat(64))
  })
  checkpoint_rejects(() => {
    validate_checkpoint_catalog_descriptor(
      { ..descriptor, shape: [1, 2], },
      1,
      descriptor.sha256,
    )
  })
  checkpoint_rejects(() => {
    validate_checkpoint_catalog_descriptor(
      descriptor,
      200001,
      descriptor.sha256,
    )
  })
}

///|
test "stream inventory refuses collisions expansion and malformed lengths without allocation" {
  let blob : @stream.BlobDescriptor = {
    file: "replay.values.f64le",
    dtype: "f64le",
    shape: [0, 1, 234],
    count: 0L,
    byte_length: 0L,
    sha256: "a".repeat(64),
  }
  validate_stream_members([blob], 10L)
  checkpoint_rejects(() => validate_stream_members([blob, blob], 10L))
  checkpoint_rejects(() => {
    validate_stream_members([{ ..blob, file: "state.json", }], 10L)
  })
  checkpoint_rejects(() => {
    validate_stream_members([{ ..blob, file: "../payload", }], 10L)
  })
  checkpoint_rejects(() => {
    validate_stream_members([{ ..blob, count: 1L, }], 10L)
  })
  checkpoint_rejects(() => validate_stream_members([blob], 4194305L))
  let huge = {
    ..blob,
    shape: [67108864],
    count: 67108864L,
    byte_length: 536870912L,
  }
  checkpoint_rejects(() => validate_stream_members([huge], 10L))
}

///|
async fn staged_fixture(output : String, generation : String) -> String {
  let staging = output + "/" + generation + ".partial"
  @fs.mkdir(staging)
  for name in ["world.pt", "policy.pt", "critic.pt"] {
    // Envelope-only test, not fake optimizer deserialization.
    @fs.write_file(
      staging + "/" + name,
      b"archive-envelope-fixture",
      create_mode=CreateNew,
      sync=Full,
    )
  }
  staging
}

///|
async test "checkpoint atomic publication retains previous generation when sidecar bytes are corrupt" {
  let root = @fs.tmpdir(prefix="moonrobo-checkpoint-stream-")
  defer @fs.rmdir(root, recursive=true)
  ignore(staged_fixture(root, "generation-0-legacy"))
  let legacy = seal_checkpoint_generation(
    root,
    "generation-0-legacy",
    0,
    {
      "format": "moonrobo.native-tensor-training-generation.v1",
      "identity": { "config": {} },
      "runtime": { "iteration": 0 },
    },
    [],
    None,
    LegacyV1,
  )
  assert_eq(legacy.files.length(), 4)
  let before = @fs.read_file(root + "/current.json").binary()
  let corrupt = staged_fixture(root, "generation-1-corrupt")
  let descriptor = @stream.write_u8(corrupt, "payload.u8", [3], (_, _) => {
    [b'a', b'b', b'c']
  })
  @fs.write_file(
    corrupt + "/payload.u8",
    b"xyz",
    create_mode=CreateOrTruncate,
    sync=Full,
  )
  try
    seal_checkpoint_generation(
      root,
      "generation-1-corrupt",
      1,
      { "fixture": true, "identity": { "config": {} } },
      [descriptor],
      None,
      StreamV2,
    )
  catch {
    Failure(message) => assert_true(message.contains("SHA256"))
    error => raise error
  } noraise {
    _ => fail("corrupt sidecar must stop publication")
  }
  assert_eq(@fs.read_file(root + "/current.json").binary(), before)
  assert_false(@fs.exists(root + "/generation-1-corrupt"))
  assert_true(@fs.exists(corrupt + "/state.json"))
  let staging = staged_fixture(root, "generation-2-stream")
  let empty = @stream.write_f64le(staging, "empty.f64le", [0, 1, 234], (_, _) => {
    fail("empty producer must not be called")
  })
  let receipt = seal_checkpoint_generation(
    root,
    "generation-2-stream",
    2,
    { "fixture": true, "identity": { "config": {} } },
    [empty],
    None,
    StreamV2,
  )
  assert_eq(receipt.format, "moonrobo.native-tensor-checkpoint-pointer.v2")
  assert_eq(receipt.files.length(), 5)
  assert_eq(
    receipt.files["empty.f64le"],
    file_hash(root + "/generation-2-stream/empty.f64le"),
  )
  assert_eq(
    @fs.read_file(root + "/current.json").binary(),
    @fs.read_file(root + "/generation-2-stream/receipt.json").binary(),
  )
  @fs.write_file(
    root + "/generation-2-stream/policy.pt",
    b"corrupt",
    create_mode=CreateOrTruncate,
    sync=Full,
  )
  try verify_checkpoint_generation(root + "/current.json") catch {
    Failure(message) =>
      assert_true(message.contains("hash mismatch: policy.pt"))
    error => raise error
  } noraise {
    _ =>
      fail(
        "corrupt optimizer archive must fail before metadata/headroom parsing",
      )
  }
}
