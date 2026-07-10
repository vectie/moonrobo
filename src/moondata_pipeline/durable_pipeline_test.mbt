///|
fn reset_pipeline_run_file(root : String, run_id : String) -> Unit raise {
  let path = @moondata_pipeline.pipeline_run_path(root, run_id)
  for candidate in [path, path + ".next", path + ".previous"] {
    if @fsx.path_exists(candidate) {
      @fsx.remove_file(candidate) catch {
        _ => fail("failed to reset pipeline run")
      }
    }
  }
}

///|
fn pipeline_test_stage(
  run : @moondata_pipeline.PipelineRun,
  stage_id : String,
) -> @moondata_pipeline.PipelineStageRun raise {
  for stage in run.stages {
    if stage.stage_id == stage_id {
      return stage
    }
  }
  fail("missing pipeline stage " + stage_id)
}

///|
test "durable pipeline persists a validation-gated completed run" {
  let root = "target/moondata-durable-pipeline-success"
  let input = "target/moondata-durable-pipeline-success-input"
  let run_id = "run-durable-success"
  reset_pipeline_run_file(root, run_id)
  write_input(input)
  let request = @moondata_pipeline.local_file_product_request(
    root, input, "ds-durable-success", "robot-durable", "bridge-durable", 1200L,
  )
  let submitted = match
    @moondata_pipeline.submit_local_file_pipeline(run_id, request, 1200L) {
    Ok(run) => run
    Err(error) => fail("submit failed: " + error.message)
  }
  assert_eq(submitted.status, "succeeded")
  assert_eq(submitted.validation_status, "passed")
  assert_eq(submitted.validation_report_id, "validation-1207")
  assert_eq(submitted.attempt, 1)
  for stage in submitted.stages {
    assert_eq(stage.status, "succeeded")
    assert_eq(stage.attempt, 1)
  }
  let loaded = match @moondata_pipeline.read_pipeline_run(root, run_id) {
    Ok(run) => run
    Err(error) => fail("read failed: " + error.message)
  }
  assert_true(loaded == submitted)
  let repeated = match
    @moondata_pipeline.submit_local_file_pipeline(run_id, request, 1300L) {
    Ok(run) => run
    Err(error) => fail("idempotent submit failed: " + error.message)
  }
  assert_eq(repeated.revision, submitted.revision)
  let terminal_cancel = match
    @moondata_pipeline.cancel_local_file_pipeline(root, run_id, 1301L) {
    Ok(run) => run
    Err(error) => fail("terminal cancel failed: " + error.message)
  }
  assert_eq(terminal_cancel.status, "succeeded")
  assert_eq(terminal_cancel.revision, submitted.revision)
  let runs = match @moondata_pipeline.list_pipeline_runs(root) {
    Ok(value) => value
    Err(error) => fail("list failed: " + error.message)
  }
  assert_true(runs.length() >= 1)
}

///|
test "retry preserves successful checkpoints and retries the failed stage" {
  let root = "target/moondata-durable-pipeline-retry"
  let input = "target/moondata-durable-pipeline-retry-input"
  let run_id = "run-durable-retry"
  reset_pipeline_run_file(root, run_id)
  write_input(input)
  let request = @moondata_pipeline.local_file_product_request(
    root,
    input,
    "ds-durable-retry",
    "robot-durable",
    "bridge-durable",
    2200L,
    target_format="unsupported",
  )
  let first = match
    @moondata_pipeline.submit_local_file_pipeline(run_id, request, 2200L) {
    Ok(run) => run
    Err(error) => fail("submit failed: " + error.message)
  }
  assert_eq(first.status, "failed")
  assert_eq(first.current_stage, "export")
  assert_eq(pipeline_test_stage(first, "import").attempt, 1)
  assert_eq(pipeline_test_stage(first, "review-replay").attempt, 1)
  assert_eq(pipeline_test_stage(first, "export").attempt, 1)
  let retried = match
    @moondata_pipeline.retry_local_file_pipeline(root, run_id, 2300L) {
    Ok(run) => run
    Err(error) => fail("retry failed: " + error.message)
  }
  assert_eq(retried.status, "failed")
  assert_eq(retried.attempt, 2)
  assert_eq(pipeline_test_stage(retried, "import").attempt, 1)
  assert_eq(pipeline_test_stage(retried, "review-replay").attempt, 1)
  assert_eq(pipeline_test_stage(retried, "export").attempt, 2)
}

///|
test "queued pipeline can be canceled durably before execution" {
  let root = "target/moondata-durable-pipeline-cancel"
  let run_id = "run-durable-cancel"
  reset_pipeline_run_file(root, run_id)
  let request = @moondata_pipeline.local_file_product_request(
    root, "target/moondata-unused-input", "ds-durable-cancel", "robot-durable", "bridge-durable",
    3200L,
  )
  let queued = @moondata_pipeline.new_local_file_pipeline_run(
    run_id, request, 3200L,
  )
  match @moondata_pipeline.write_pipeline_run(root, queued) {
    Ok(_) => ()
    Err(error) => fail("write failed: " + error.message)
  }
  let canceled = match
    @moondata_pipeline.cancel_local_file_pipeline(root, run_id, 3201L) {
    Ok(run) => run
    Err(error) => fail("cancel failed: " + error.message)
  }
  assert_eq(canceled.status, "canceled")
  assert_true(canceled.cancel_requested)
  let resumed = match
    @moondata_pipeline.resume_local_file_pipeline(root, run_id, 3202L) {
    Ok(run) => run
    Err(error) => fail("resume failed: " + error.message)
  }
  assert_eq(resumed.status, "canceled")
  assert_eq(pipeline_test_stage(resumed, "import").attempt, 0)
}

///|
test "pipeline run ids cannot escape the run store" {
  let request = @moondata_pipeline.local_file_product_request(
    "target/moondata-durable-pipeline-safe-id", "target/moondata-unused-input", "ds-safe-id",
    "robot-durable", "bridge-durable", 4200L,
  )
  let run = @moondata_pipeline.new_local_file_pipeline_run(
    "../unsafe", request, 4200L,
  )
  let result = @moondata_pipeline.write_pipeline_run(request.root, run)
  assert_true(result is Err({ code: "pipeline-run-id-unsafe", .. }))
}

///|
test "pipeline run read recovers the previous durable checkpoint" {
  let root = "target/moondata-durable-pipeline-recovery"
  let run_id = "run-durable-recovery"
  reset_pipeline_run_file(root, run_id)
  let request = @moondata_pipeline.local_file_product_request(
    root, "target/moondata-unused-input", "ds-durable-recovery", "robot-durable",
    "bridge-durable", 5200L,
  )
  let first = @moondata_pipeline.new_local_file_pipeline_run(
    run_id, request, 5200L,
  )
  match @moondata_pipeline.write_pipeline_run(root, first) {
    Ok(_) => ()
    Err(error) => fail("first write failed: " + error.message)
  }
  let second = { ..first, revision: 1, updated_at_ms: 5201L }
  match @moondata_pipeline.write_pipeline_run(root, second) {
    Ok(_) => ()
    Err(error) => fail("second write failed: " + error.message)
  }
  let path = @moondata_pipeline.pipeline_run_path(root, run_id)
  @fsx.write_string_to_file(path, "{interrupted") catch {
    _ => fail("failed to corrupt current checkpoint")
  }
  let recovered = match @moondata_pipeline.read_pipeline_run(root, run_id) {
    Ok(run) => run
    Err(error) => fail("recovery failed: " + error.message)
  }
  assert_eq(recovered.revision, 0)
  assert_eq(recovered.status, "queued")
}
