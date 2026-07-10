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
  assert_true(plan.command.contains("--stats-max-publishing-rate"))
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
  let root = "target/moondata-recorder-lifecycle"
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
      "session-lifecycle",
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
  let loss = match
    @moondata_recorder.record_message_loss(root, plan.session_id, 7L, 2001L) {
    Ok(value) => value
    Err(error) => fail(error.message)
  }
  assert_eq(loss.message_loss_status, "observed")
  assert_eq(loss.messages_lost, 7L)
  let stopped = match
    @moondata_recorder.stop_recorder(root, plan.session_id, 2002L) {
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
