///|
test "data-ready barrier binds both prepared rank identities without extending NCCL TTL" {
  let settings : DistributedSettings = {
    rank: 0,
    world_size: 2,
    id_file: "/unused/id.json",
    session_id: "native-data-ready-test-20261024",
    timeout_ms: 30000,
    data_ready_timeout_seconds: Some(3600),
  }
  let coordinator : DataReadyCoordinator = {
    format: "moonrobo.native-data-ready-coordinator.v1",
    session_id: settings.session_id,
    world_size: 2,
    timeout_seconds: 3600,
    created_unix_ms: 100000L,
    expires_unix_ms: 3700000L,
  }
  validate_data_ready_coordinator(coordinator, settings, 3600000L)
  let digest = "a".repeat(64)
  let ready : DataReadyRecord = {
    format: "moonrobo.native-data-ready.v1",
    session_id: settings.session_id,
    world_size: 2,
    rank: 0,
    coordinator_created_unix_ms: 100000L,
    created_unix_ms: 110000L,
    expires_unix_ms: 3700000L,
    launch_identity_sha256: digest,
  }
  let release : DataReadyRelease = {
    format: "moonrobo.native-data-ready-release.v1",
    session_id: settings.session_id,
    world_size: 2,
    created_unix_ms: 3600000L,
    expires_unix_ms: 3660000L,
    ready: [ready, { ..ready, rank: 1, created_unix_ms: 3599000L, }],
  }
  validate_data_ready_release(release, coordinator, settings, digest, 3601000L)
  let decoded : DataReadyRelease = @json.from_json(Json(release))
  validate_data_ready_release(decoded, coordinator, settings, digest, 3601000L)
  assert_eq(settings.timeout_ms, 30000)
  for
    invalid in [
      { ..release, ready: [ready], },
      {
        ..release,
        ready: [
          ready,
          { ..ready, rank: 1, launch_identity_sha256: "b".repeat(64), },
        ],
      },
      { ..release, ready: [ready, ready], },
      { ..release, expires_unix_ms: 7200000L, },
      { ..release, session_id: "native-data-ready-other-20261024", },
    ] {
    try
      validate_data_ready_release(
        invalid, coordinator, settings, digest, 3601000L,
      )
    catch {
      _ => ()
    } noraise {
      _ => fail("invalid data-ready release accepted")
    }
  }
  try
    validate_data_ready_release(
      release, coordinator, settings, digest, 3660000L,
    )
  catch {
    _ => ()
  } noraise {
    _ => fail("expired data-ready release accepted")
  }
}

///|
async test "data-ready disabled mode performs no filesystem access" {
  let settings : DistributedSettings = {
    rank: 0,
    world_size: 2,
    id_file: "/nonexistent-parent/unused.json",
    session_id: "native-data-ready-test-20261024",
    timeout_ms: 30000,
    data_ready_timeout_seconds: None,
  }
  await_data_ready(settings, Json::empty_object())
  report_data_ready_failure(Some(settings))
}

///|
test "data-ready is explicit and bounded" {
  let args = [
    "--distributed", "--rank", "0", "--world-size", "2", "--session-id", "native-data-ready-test-20261024",
    "--nccl-id-file", "/unused/id.json",
  ]
  assert_true(
    distributed_settings(Json::empty_object(), args).unwrap().data_ready_timeout_seconds
    is None,
  )
  for invalid in ["0", "59", "21601"] {
    let options = args.copy()
    options.append(["--data-ready-timeout-seconds", invalid])
    try distributed_settings(Json::empty_object(), options) catch {
      _ => ()
    } noraise {
      _ => fail("unbounded data-ready wait accepted")
    }
  }
}
