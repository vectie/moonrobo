///|
fn execute_local_file_stage(
  request : LocalFileProductRequest,
  stage_id : String,
) -> Result[String, @moondata_store.MoonDataStoreIssue] {
  match stage_id {
    "import" =>
      match run_import_stage(request) {
        Ok(result) =>
          Ok(
            "registered raw dataset \{result.dataset_id} with \{result.payload_count} payload(s)",
          )
        Err(error) => Err(error)
      }
    "normalize" =>
      match run_normalize_stage(request) {
        Ok(result) =>
          Ok(
            "normalized \{result.frame_count} frame(s) into \{result.canonical_dataset_id}",
          )
        Err(error) => Err(error)
      }
    "quality" =>
      match run_quality_stage(request) {
        Ok(result) =>
          if result.quality.status == "passed" {
            Ok("quality run \{result.quality_run_id} passed")
          } else {
            Err({
              code: "pipeline-quality-blocked",
              path: @moondata_store.quality_run_path(
                request.root,
                result.quality_run_id,
              ),
              message: "quality run \{result.quality_run_id} did not pass",
            })
          }
        Err(error) => Err(error)
      }
    "curate" =>
      match run_curate_stage(request) {
        Ok(result) => Ok("accepted dataset version \{result.version_id}")
        Err(error) => Err(error)
      }
    "review-replay" =>
      match write_review_replay(request, request.version_id) {
        Ok(result) =>
          Ok(
            "materialized annotation \{result.annotation_set_id} and replay \{result.replay_artifact_id}",
          )
        Err(error) => Err(error)
      }
    "export" =>
      match run_export_stage(request) {
        Ok(result) =>
          Ok(
            "published \{result.output_record_count} record(s) as \{result.export_manifest_id}",
          )
        Err(error) => Err(error)
      }
    "finalize" =>
      match run_finalize_stage(request) {
        Ok(result) =>
          if result.status == "passed" {
            Ok("validation \{result.validation_report_id} passed")
          } else {
            Err({
              code: "pipeline-validation-blocked",
              path: result.report_path,
              message: "validation \{result.validation_report_id} finished with status \{result.status}",
            })
          }
        Err(error) => Err(error)
      }
    _ =>
      Err({
        code: "pipeline-stage-unknown",
        path: stage_id,
        message: "unknown MoonData pipeline stage",
      })
  }
}

///|
pub fn execute_local_file_pipeline(
  root : String,
  run_id : String,
  now_ms : Int64,
) -> Result[PipelineRun, @moondata_store.MoonDataStoreIssue] {
  let loaded = match read_pipeline_run(root, run_id) {
    Ok(run) => run
    Err(error) => return Err(error)
  }
  if loaded.status == "succeeded" || loaded.status == "canceled" {
    return Ok(loaded)
  }
  if loaded.status == "failed" {
    return Err({
      code: "pipeline-retry-required",
      path: pipeline_run_path(root, run_id),
      message: "failed pipeline run must be retried before execution",
    })
  }
  let mut run = start_pipeline_attempt(loaded, now_ms)
  match write_pipeline_run(root, run) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  for index in 0..<run.stages.length() {
    run = match read_pipeline_run(root, run.run_id) {
      Ok(latest) => latest
      Err(error) => return Err(error)
    }
    if run.cancel_requested {
      run = cancel_pipeline_run(run, now_ms + index.to_int64())
      match write_pipeline_run(root, run) {
        Ok(_) => return Ok(run)
        Err(error) => return Err(error)
      }
    }
    let stage = run.stages[index]
    if stage.status == "succeeded" {
      continue
    }
    run = start_pipeline_stage(run, stage.stage_id, now_ms + index.to_int64())
    match write_pipeline_run(root, run) {
      Ok(_) => ()
      Err(error) => return Err(error)
    }
    match execute_local_file_stage(run.request, stage.stage_id) {
      Ok(message) => {
        run = complete_pipeline_stage(
          run,
          stage.stage_id,
          message,
          now_ms + index.to_int64() + 1L,
        )
        match write_pipeline_run(root, run) {
          Ok(_) => ()
          Err(error) => return Err(error)
        }
      }
      Err(error) => {
        run = fail_pipeline_stage(
          run,
          stage.stage_id,
          error,
          now_ms + index.to_int64() + 1L,
        )
        if stage.stage_id == "finalize" {
          run = {
            ..run,
            validation_report_id: "validation-\{run.request.generated_at_ms + 7L}",
            validation_status: "failed",
          }
        }
        match write_pipeline_run(root, run) {
          Ok(_) => return Ok(run)
          Err(write_error) => return Err(write_error)
        }
      }
    }
  }
  let validation_report_id = "validation-\{run.request.generated_at_ms + 7L}"
  run = complete_pipeline_run(
    run,
    validation_report_id,
    now_ms + run.stages.length().to_int64() + 1L,
  )
  match write_pipeline_run(root, run) {
    Ok(_) => Ok(run)
    Err(error) => Err(error)
  }
}

///|
pub fn submit_local_file_pipeline(
  run_id : String,
  request : LocalFileProductRequest,
  now_ms : Int64,
) -> Result[PipelineRun, @moondata_store.MoonDataStoreIssue] {
  let path = pipeline_run_path(request.root, run_id)
  if @fsx.path_exists(path) {
    let existing = match read_pipeline_run(request.root, run_id) {
      Ok(run) => run
      Err(error) => return Err(error)
    }
    if existing.request != request {
      return Err({
        code: "pipeline-run-conflict",
        path,
        message: "pipeline run id already belongs to a different request",
      })
    }
    return Ok(existing)
  }
  let run = new_local_file_pipeline_run(run_id, request, now_ms)
  match write_pipeline_run(request.root, run) {
    Ok(_) => execute_local_file_pipeline(request.root, run_id, now_ms)
    Err(error) => Err(error)
  }
}

///|
pub fn resume_local_file_pipeline(
  root : String,
  run_id : String,
  now_ms : Int64,
) -> Result[PipelineRun, @moondata_store.MoonDataStoreIssue] {
  execute_local_file_pipeline(root, run_id, now_ms)
}

///|
pub fn retry_local_file_pipeline(
  root : String,
  run_id : String,
  now_ms : Int64,
) -> Result[PipelineRun, @moondata_store.MoonDataStoreIssue] {
  let loaded = match read_pipeline_run(root, run_id) {
    Ok(run) => run
    Err(error) => return Err(error)
  }
  if loaded.status != "failed" {
    return Err({
      code: "pipeline-run-not-failed",
      path: pipeline_run_path(root, run_id),
      message: "only failed pipeline runs can be retried",
    })
  }
  let queued = reset_pipeline_retry(loaded, now_ms)
  match write_pipeline_run(root, queued) {
    Ok(_) => execute_local_file_pipeline(root, run_id, now_ms + 1L)
    Err(error) => Err(error)
  }
}

///|
pub fn cancel_local_file_pipeline(
  root : String,
  run_id : String,
  now_ms : Int64,
) -> Result[PipelineRun, @moondata_store.MoonDataStoreIssue] {
  let loaded = match read_pipeline_run(root, run_id) {
    Ok(run) => run
    Err(error) => return Err(error)
  }
  if loaded.status == "succeeded" || loaded.status == "canceled" {
    return Ok(loaded)
  }
  let requested = request_pipeline_cancel(loaded, now_ms)
  let canceled = if requested.status == "running" {
    requested
  } else {
    cancel_pipeline_run(requested, now_ms)
  }
  match write_pipeline_run(root, canceled) {
    Ok(_) => Ok(canceled)
    Err(error) => Err(error)
  }
}
