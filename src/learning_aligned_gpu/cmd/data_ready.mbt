///|
struct DataReadyCoordinator {
  format : String
  session_id : String
  world_size : Int32
  timeout_seconds : Int32
  created_unix_ms : Int64
  expires_unix_ms : Int64
} derive(ToJson, FromJson)

///|
struct DataReadyRecord {
  format : String
  session_id : String
  world_size : Int32
  rank : Int32
  coordinator_created_unix_ms : Int64
  created_unix_ms : Int64
  expires_unix_ms : Int64
  launch_identity_sha256 : String
} derive(ToJson, FromJson)

///|
struct DataReadyRelease {
  format : String
  session_id : String
  world_size : Int32
  created_unix_ms : Int64
  expires_unix_ms : Int64
  ready : Array[DataReadyRecord]
} derive(ToJson, FromJson)

///|
fn data_ready_digest(value : String) -> Bool {
  value.length() == 64 &&
  value.iter().all(c => (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f'))
}

///|
fn validate_data_ready_coordinator(
  value : DataReadyCoordinator,
  settings : DistributedSettings,
  now : Int64,
) -> Unit raise {
  guard settings.data_ready_timeout_seconds is Some(timeout) &&
    value.format == "moonrobo.native-data-ready-coordinator.v1" &&
    value.session_id == settings.session_id &&
    value.world_size == 2 &&
    value.timeout_seconds == timeout &&
    value.created_unix_ms > 0L &&
    value.created_unix_ms <= now + 10000L &&
    value.expires_unix_ms > now &&
    value.expires_unix_ms - value.created_unix_ms == timeout.to_int64() * 1000L else {
    fail(
      "data-ready coordinator is absent, stale, or disagrees with session/timeout; start a fresh coordinated session",
    )
  }
}

///|
fn validate_data_ready_release(
  value : DataReadyRelease,
  coordinator : DataReadyCoordinator,
  settings : DistributedSettings,
  identity : String,
  now : Int64,
) -> Unit raise {
  guard value.format == "moonrobo.native-data-ready-release.v1" &&
    value.session_id == settings.session_id &&
    value.world_size == 2 &&
    value.ready.length() == 2 &&
    value.created_unix_ms >= coordinator.created_unix_ms &&
    value.created_unix_ms <= now + 10000L &&
    value.created_unix_ms < coordinator.expires_unix_ms &&
    value.expires_unix_ms > now &&
    value.expires_unix_ms - value.created_unix_ms == 60000L &&
    data_ready_digest(identity) else {
    fail("invalid or expired two-rank data-ready release")
  }
  for rank, ready in value.ready {
    guard ready.format == "moonrobo.native-data-ready.v1" &&
      ready.rank == rank &&
      ready.session_id == settings.session_id &&
      ready.world_size == 2 &&
      ready.coordinator_created_unix_ms == coordinator.created_unix_ms &&
      ready.expires_unix_ms == coordinator.expires_unix_ms &&
      ready.created_unix_ms >= coordinator.created_unix_ms - 10000L &&
      ready.created_unix_ms <= value.created_unix_ms + 10000L &&
      ready.launch_identity_sha256 == identity else {
      fail(
        "ranks disagree on prepared executable/configuration/assets/effective launch schedule",
      )
    }
  }
}

///|
async fn data_ready_json(path : String) -> Json {
  guard @fs.kind(path, follow_symlink=false) == Regular else {
    fail("data-ready record must be a regular file")
  }
  bounded_json(path, 4096L)
}

///|
async fn data_ready_paths(settings : DistributedSettings) -> Unit {
  let path = settings.id_file
  guard path.has_prefix("/") &&
    path.length() <= 2048 &&
    !path.contains("//") &&
    path.split("/").all(p => p != "." && p != "..") &&
    path
    .iter()
    .all(c => {
      (c >= 'a' && c <= 'z') ||
      (c >= 'A' && c <= 'Z') ||
      (c >= '0' && c <= '9') ||
      c == '/' ||
      c == '-' ||
      c == '_' ||
      c == '.'
    }) &&
    @fs.realpath(dirname(path)) == dirname(path) else {
    fail("data-ready mode requires an absolute canonical ASCII rendezvous path")
  }
}

///|
async fn atomic_data_ready(path : String, value : Json) -> Unit {
  let bytes = @utf8.encode(value.stringify() + "\n")
  guard bytes.length() <= 4096 else { fail("data-ready record exceeds 4 KiB") }
  @fs.write_file(
    path + ".partial",
    bytes,
    create_mode=CreateNew,
    permission=0o600,
    sync=Full,
  )
  @fs.rename(path + ".partial", path, replace=false)
  sync_path(dirname(path))
}

///|
/// Optional startup barrier. Its long, bounded preparation wait is separate
/// from NCCL's unchanged short-lived ticket and collective timeout.
async fn await_data_ready(
  settings : DistributedSettings,
  identity : Json,
) -> Unit {
  guard settings.data_ready_timeout_seconds is Some(_) else { return }
  data_ready_paths(settings)
  let coordinator : DataReadyCoordinator = @json.from_json(
    data_ready_json(settings.id_file + ".data-ready-coordinator.json"),
  )
  validate_data_ready_coordinator(coordinator, settings, unix_milliseconds())
  guard !@fs.exists(settings.id_file) else {
    fail("NCCL ticket must not exist before the data-ready barrier")
  }
  let digest = text_hash(identity.stringify())
  let ready : DataReadyRecord = {
    format: "moonrobo.native-data-ready.v1",
    session_id: settings.session_id,
    world_size: 2,
    rank: settings.rank,
    coordinator_created_unix_ms: coordinator.created_unix_ms,
    created_unix_ms: unix_milliseconds(),
    expires_unix_ms: coordinator.expires_unix_ms,
    launch_identity_sha256: digest,
  }
  atomic_data_ready(
    settings.id_file + ".rank-\{settings.rank}.data-ready.json",
    Json(ready),
  )
  println(
    (
      {
        "stage": "native-rank-data-ready",
        "rank": settings.rank,
        "session_id": settings.session_id,
        "launch_identity_sha256": digest,
        "preparation_deadline_unix_ms": Json(coordinator.expires_unix_ms),
      } : Json).stringify(),
  )
  let release_path = settings.id_file + ".data-ready-release.json"
  let abort_path = settings.id_file + ".data-ready-aborted.json"
  let remaining = coordinator.expires_unix_ms - unix_milliseconds()
  let deadline = @async.now() + remaining.max(0L)
  while !@fs.exists(release_path) {
    if @fs.exists(abort_path) {
      let abort = data_ready_json(abort_path)
      fail(
        "data-ready coordination aborted; inspect retained coordinator/rank logs: " +
        abort.stringify(),
      )
    }
    guard @async.now() < deadline else {
      fail(
        "bounded two-rank data preparation wait expired; NCCL ticket was not issued",
      )
    }
    @async.sleep(250)
  }
  guard !@fs.exists(abort_path) else {
    fail("data-ready coordination was aborted")
  }
  let release : DataReadyRelease = @json.from_json(
    data_ready_json(release_path),
  )
  validate_data_ready_release(
    release,
    coordinator,
    settings,
    digest,
    unix_milliseconds(),
  )
  println(
    (
      {
        "stage": "native-all-ranks-data-ready",
        "rank": settings.rank,
        "session_id": settings.session_id,
        "launch_identity_sha256": digest,
        "short_nccl_ticket_timeout_ms": settings.timeout_ms,
      } : Json).stringify(),
  )
}

///|
/// Called by the CLI's errdefer. Never masks the original failure, and does
/// nothing unless the explicit coordinator and session validate. All evidence
/// uses CreateNew; a failed session must not be reused.
async fn report_data_ready_failure(settings : DistributedSettings?) -> Unit {
  if settings is Some(settings) &&
    settings.data_ready_timeout_seconds is Some(_) {
    try {
      data_ready_paths(settings)
      let coordinator : DataReadyCoordinator = @json.from_json(
        data_ready_json(settings.id_file + ".data-ready-coordinator.json"),
      )
      validate_data_ready_coordinator(
        coordinator,
        settings,
        unix_milliseconds(),
      )
      atomic_data_ready(
        settings.id_file + ".rank-\{settings.rank}.data-ready-failed.json",
        {
          "format": "moonrobo.native-data-ready-failure.v1",
          "session_id": settings.session_id,
          "rank": settings.rank,
          "world_size": 2,
          "created_unix_ms": Json(unix_milliseconds()),
          "reason": "native rank failed; retained rank log contains the original error",
        },
      )
    } catch {
      _ => ()
    }
  }
}
