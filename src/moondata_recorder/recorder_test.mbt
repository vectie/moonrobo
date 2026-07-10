///|
fn recorder_mcap_fixture(finalized : Bool) -> Bytes {
  let magic : Array[Byte] = [0x89, 0x4d, 0x43, 0x41, 0x50, 0x30, 0x0d, 0x0a]
  let size = 20
  Bytes::makei(size, fn(index) {
    if index < 8 {
      magic[index]
    } else if finalized && index >= size - 8 {
      magic[index - (size - 8)]
    } else {
      (index + 1).to_byte()
    }
  })
}

///|
fn stopped_recorder_session(
  plan : @moondata_recorder.RecorderPlan,
  started_at_ms : Int64,
) -> @moondata_recorder.RecorderSession {
  {
    schema_version: "moondata.recorder-session.v2",
    session_id: plan.session_id,
    status: "stopped",
    pid: 0,
    running: false,
    revision: 1,
    created_at_ms: started_at_ms,
    updated_at_ms: started_at_ms,
    started_at_ms,
    stopped_at_ms: started_at_ms + 1L,
    available_bytes: 1000000L,
    disk_pressure: false,
    message_loss_status: "clear",
    messages_lost: 0L,
    chunks: [],
    recoveries: [],
    plan,
    message: "fixture stopped",
  }
}

///|
test "recorder plan makes rotation retention and loss telemetry explicit" {
  let plan = match
    @moondata_recorder.recorder_plan(
      "target/moondata-recorder-plan",
      "session-plan",
      "robot-plan",
      "ros2-plan",
      all_topics=false,
      topics=["/joint_states", "/tf"],
      max_bag_size_bytes=200000L,
      max_bag_duration_seconds=60L,
      max_cache_size_bytes=50000L,
      max_bag_files=8,
      minimum_free_bytes=400000L,
    ) {
    Ok(value) => value
    Err(error) => fail(error.message)
  }
  assert_eq(plan.command[0], "ros2")
  assert_true(plan.command.contains("mcap"))
  assert_true(plan.command.contains("--max-bag-size"))
  assert_true(plan.command.contains("--max-bag-duration"))
  assert_true(plan.command.contains("--max-cache-size"))
  assert_true(plan.command.contains("--max-bag-files"))
  assert_true(plan.command.contains("--stats_max_publishing_rate"))
  assert_true(plan.command.contains("--topics"))
  assert_true(plan.command.contains("/joint_states"))
  assert_false(plan.command.contains("--all"))
  let script = @moondata_recorder.recorder_script(plan)
  assert_true(script.contains("exec 'ros2' 'bag' 'record'"))
  assert_true(script.contains("session-plan.log"))
}

///|
test "recorder refuses invalid topic and retention policies" {
  let no_topics = @moondata_recorder.recorder_plan(
    "target/moondata-recorder-invalid",
    "session-invalid",
    "robot-invalid",
    "ros2-invalid",
    all_topics=false,
  )
  assert_true(no_topics is Err({ code: "recorder-topics-empty", .. }))
  let invalid_topic = @moondata_recorder.recorder_plan(
    "target/moondata-recorder-invalid",
    "session-invalid",
    "robot-invalid",
    "ros2-invalid",
    all_topics=false,
    topics=["joint states"],
  )
  assert_true(invalid_topic is Err({ code: "recorder-topic-invalid", .. }))
}

///|
test "recorder disk gate refuses to launch a process" {
  let root = "target/moondata-recorder-disk-gate"
  let plan = match
    @moondata_recorder.recorder_plan(
      root,
      "session-disk-gate",
      "robot-disk-gate",
      "ros2-disk-gate",
      minimum_free_bytes=9000000000000000000L,
    ) {
    Ok(value) => value
    Err(error) => fail(error.message)
  }
  let result = @moondata_recorder.start_recorder(plan, 1000L)
  assert_true(result is Err({ code: "recorder-disk-pressure", .. }))
  assert_false(
    @fsx.path_exists(
      @moondata_recorder.recorder_session_path(root, "session-disk-gate"),
    ),
  )
}

///|
test "recorder discovers finalized and interrupted MCAP chunks" {
  let root = "target/moondata-recorder-chunks"
  ignore(@moondata_store.initialize_root(root))
  let output = root + "/incoming/session-chunks"
  if !@fsx.path_exists(output) {
    @fsx.create_dir(output) catch {
      _ => fail("failed to create recorder chunk fixture directory")
    }
  }
  @fsx.write_bytes_to_file(
    output + "/capture_0.mcap",
    recorder_mcap_fixture(true),
  ) catch {
    _ => fail("failed to write finalized recorder chunk")
  }
  @fsx.write_bytes_to_file(
    output + "/capture_1.mcap",
    recorder_mcap_fixture(false),
  ) catch {
    _ => fail("failed to write interrupted recorder chunk")
  }
  let chunks = match @moondata_recorder.discover_recorder_chunks(output) {
    Ok(value) => value
    Err(error) => fail(error.message)
  }
  assert_eq(chunks.length(), 2)
  assert_true(chunks.any(fn(chunk) { chunk.finalized }))
  assert_true(chunks.any(fn(chunk) { chunk.recovery_required }))
}

///|
test "recorder persists process lifecycle and message loss" {
  let root = "target/moondata-recorder-lifecycle-v2"
  if !@fsx.path_exists("target") {
    @fsx.create_dir("target") catch {
      _ => fail("failed to create target directory")
    }
  }
  let fake = "target/moondata-recorder-fake.sh"
  @fsx.write_string_to_file(
    fake, "#!/bin/sh\ntrap 'exit 0' TERM INT\nwhile :; do sleep 1; done\n",
  ) catch {
    _ => fail("failed to write fake recorder")
  }
  let plan = match
    @moondata_recorder.recorder_plan(
      root,
      "session-lifecycle-v2",
      "robot-lifecycle",
      "ros2-lifecycle",
      max_bag_size_bytes=100000L,
      minimum_free_bytes=200000L,
      executable="sh",
      executable_args=[fake],
    ) {
    Ok(value) => value
    Err(error) => fail(error.message)
  }
  let started = match @moondata_recorder.start_recorder(plan, 2000L) {
    Ok(value) => value
    Err(error) => fail(error.message)
  }
  assert_eq(started.status, "recording")
  assert_true(started.pid > 0)
  assert_true(@fsx.path_exists(plan.script_path))
  let live_seal = @moondata_recorder.seal_recorder_chunks(
    root,
    plan.session_id,
    2001L,
  )
  assert_true(live_seal is Err({ code: "recorder-session-active", .. }))
  let loss = match
    @moondata_recorder.record_message_loss(root, plan.session_id, 7L, 2002L) {
    Ok(value) => value
    Err(error) => fail(error.message)
  }
  assert_eq(loss.message_loss_status, "observed")
  assert_eq(loss.messages_lost, 7L)
  let stopped = match
    @moondata_recorder.stop_recorder(root, plan.session_id, 2003L) {
    Ok(value) => value
    Err(error) => fail(error.message)
  }
  assert_false(stopped.running)
  assert_true(stopped.status == "stopping" || stopped.status == "stopped")
  let persisted = match
    @moondata_recorder.read_recorder_session(root, plan.session_id) {
    Ok(value) => value
    Err(error) => fail(error.message)
  }
  assert_eq(persisted.revision, stopped.revision)
  assert_eq(persisted.messages_lost, 7L)
}

///|
test "recorder sealing promotes finalized chunks and preserves recovery work" {
  let root = "target/moondata-recorder-seal"
  ignore(@moondata_store.initialize_root(root))
  let plan = match
    @moondata_recorder.recorder_plan(
      root,
      "session-seal",
      "robot-seal",
      "ros2-seal",
      max_bag_size_bytes=100000L,
      minimum_free_bytes=200000L,
    ) {
    Ok(value) => value
    Err(error) => fail(error.message)
  }
  if !@fsx.path_exists(plan.output_dir) {
    @fsx.create_dir(plan.output_dir) catch {
      _ => fail("failed to create recorder seal output")
    }
  }
  @fsx.write_bytes_to_file(
    plan.output_dir + "/capture_0.mcap",
    recorder_mcap_fixture(true),
  ) catch {
    _ => fail("failed to write sealable recorder chunk")
  }
  @fsx.write_bytes_to_file(
    plan.output_dir + "/capture_1.mcap",
    recorder_mcap_fixture(false),
  ) catch {
    _ => fail("failed to write recovery recorder chunk")
  }
  let session = stopped_recorder_session(plan, 3000L)
  ignore(@moondata_recorder.write_recorder_session(root, session))
  let result = match
    @moondata_recorder.seal_recorder_chunks(root, plan.session_id, 3002L) {
    Ok(value) => value
    Err(error) => fail(error.message)
  }
  assert_eq(result.sealed_count, 1)
  assert_eq(result.recovery_required_count, 1)
  assert_eq(result.invalid_count, 0)
  assert_eq(result.session.status, "recovery-required")
  assert_true(result.captures[0].dataset_id.has_prefix("dataset-session-seal-"))
  assert_true(
    result.captures[0].blob_uri.has_prefix("moondata://blobs/sha256/"),
  )
  let repeated = match
    @moondata_recorder.seal_recorder_chunks(root, plan.session_id, 3003L) {
    Ok(value) => value
    Err(error) => fail(error.message)
  }
  assert_true(repeated.captures[0].existed)
  assert_eq(repeated.captures[0].capture_id, result.captures[0].capture_id)
}

///|
test "recorder recovery preserves damaged bytes and marks lossy output" {
  let root = "target/moondata-recorder-recovery-v2"
  ignore(@moondata_store.initialize_root(root))
  let plan = @moondata_recorder.recorder_plan(
    root,
    "session-recovery-v2",
    "robot-recovery",
    "ros2-recovery",
    max_bag_size_bytes=100000L,
    minimum_free_bytes=200000L,
  ).unwrap()
  if !@fsx.path_exists(plan.output_dir) {
    @fsx.create_dir(plan.output_dir) catch {
      _ => fail("failed to create recorder recovery output")
    }
  }
  let damaged_path = plan.output_dir + "/capture_damaged.mcap"
  let recovered_fixture = "target/moondata-recorder-recovered-fixture.mcap"
  @fsx.write_bytes_to_file(damaged_path, recorder_mcap_fixture(false)) catch {
    _ => fail("failed to write damaged recorder fixture")
  }
  @fsx.write_bytes_to_file(recovered_fixture, recorder_mcap_fixture(true)) catch {
    _ => fail("failed to write recovered recorder fixture")
  }
  let fake = "target/moondata-recorder-recover-fake.sh"
  @fsx.write_string_to_file(
    fake,
    "#!/bin/sh\ncp '" + recovered_fixture + "' \"$4\"\nexit 3\n",
  ) catch {
    _ => fail("failed to write fake MCAP recovery tool")
  }
  ignore(
    @moondata_recorder.write_recorder_session(
      root,
      stopped_recorder_session(plan, 5000L),
    ),
  )
  let command = @moondata_recorder.mcap_recovery_command(
    damaged_path,
    damaged_path + ".recovered.next",
    executable="sh",
    executable_args=[fake],
  )
  assert_eq(command[2], "recover")
  let result = @moondata_recorder.recover_recorder_chunks(
    root,
    plan.session_id,
    5002L,
    executable="sh",
    executable_args=[fake],
  ).unwrap()
  assert_eq(result.recovered_count, 1)
  assert_eq(result.lossy_count, 1)
  assert_eq(result.failed_count, 0)
  assert_eq(result.session.status, "recovered")
  assert_eq(result.session.recoveries[0].exit_code, 3)
  assert_true(result.session.recoveries[0].lossy)
  assert_true(
    result.session.recoveries[0].original_source_id.has_prefix(
      "source-session-recovery-v2-",
    ),
  )
  assert_true(
    result.session.recoveries[0].original_blob_uri.has_prefix(
      "moondata://blobs/sha256/",
    ),
  )
  let chunks = @moondata_recorder.discover_recorder_chunks(plan.output_dir).unwrap()
  assert_true(chunks[0].finalized)
  let promoted = @moondata_recorder.seal_recorder_chunks(
    root,
    plan.session_id,
    5003L,
  ).unwrap()
  assert_eq(promoted.sealed_count, 1)
  assert_eq(promoted.recovery_required_count, 0)
  let finalized = @moondata_recorder.finalize_recorder_session(
    root,
    plan.session_id,
    5004L,
    executable="sh",
    executable_args=[fake],
  ).unwrap()
  assert_true(finalized.ready)
  assert_eq(finalized.status, "sealed")
  assert_true(finalized.promotion is Some(_))
  let validation = @moondata_validate.validate_and_write_root(
    root,
    generated_at_ms=5005L,
  ).unwrap()
  assert_eq(validation.status, "passed")
}

///|
test "recorder recovery failure keeps the damaged chunk" {
  let root = "target/moondata-recorder-recovery-failed-v2"
  ignore(@moondata_store.initialize_root(root))
  let plan = @moondata_recorder.recorder_plan(
    root,
    "session-recovery-failed-v2",
    "robot-recovery",
    "ros2-recovery",
    max_bag_size_bytes=100000L,
    minimum_free_bytes=200000L,
  ).unwrap()
  if !@fsx.path_exists(plan.output_dir) {
    @fsx.create_dir(plan.output_dir) catch {
      _ => fail("failed to create failed recovery output")
    }
  }
  let damaged_path = plan.output_dir + "/capture_failed.mcap"
  @fsx.write_bytes_to_file(damaged_path, recorder_mcap_fixture(false)) catch {
    _ => fail("failed to write failed recovery fixture")
  }
  let fake = "target/moondata-recorder-recover-failed.sh"
  @fsx.write_string_to_file(fake, "#!/bin/sh\nexit 1\n") catch {
    _ => fail("failed to write failing MCAP recovery tool")
  }
  ignore(
    @moondata_recorder.write_recorder_session(
      root,
      stopped_recorder_session(plan, 6000L),
    ),
  )
  let result = @moondata_recorder.recover_recorder_chunks(
    root,
    plan.session_id,
    6002L,
    executable="sh",
    executable_args=[fake],
  ).unwrap()
  assert_eq(result.recovered_count, 0)
  assert_eq(result.failed_count, 1)
  assert_eq(result.session.status, "recovery-failed")
  assert_eq(result.session.recoveries[0].exit_code, 1)
  let chunks = @moondata_recorder.discover_recorder_chunks(plan.output_dir).unwrap()
  assert_true(chunks[0].recovery_required)
  let finalized = @moondata_recorder.finalize_recorder_session(
    root,
    plan.session_id,
    6003L,
    executable="sh",
    executable_args=[fake],
  ).unwrap()
  assert_false(finalized.ready)
  assert_eq(finalized.status, "recovery-failed")
  assert_true(finalized.promotion is None)
}
