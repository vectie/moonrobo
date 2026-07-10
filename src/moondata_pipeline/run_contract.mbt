///|
pub(all) struct PipelineRunError {
  stage_id : String
  code : String
  path : String
  message : String
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct PipelineStageRun {
  stage_id : String
  status : String
  attempt : Int
  started_at_ms : Int64
  completed_at_ms : Int64
  message : String
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct PipelineRun {
  schema_version : String
  run_id : String
  pipeline_kind : String
  status : String
  revision : Int
  attempt : Int
  created_at_ms : Int64
  updated_at_ms : Int64
  current_stage : String
  cancel_requested : Bool
  request : LocalFileProductRequest
  stages : Array[PipelineStageRun]
  error : PipelineRunError?
  validation_report_id : String
  validation_status : String
} derive(Debug, Eq, ToJson, FromJson)

///|
pub fn local_file_pipeline_stage_ids() -> Array[String] {
  [
    "import", "normalize", "quality", "curate", "review-replay", "export", "finalize",
  ]
}

///|
fn pending_pipeline_stage(stage_id : String) -> PipelineStageRun {
  {
    stage_id,
    status: "pending",
    attempt: 0,
    started_at_ms: 0L,
    completed_at_ms: 0L,
    message: "waiting",
  }
}

///|
pub fn new_local_file_pipeline_run(
  run_id : String,
  request : LocalFileProductRequest,
  created_at_ms : Int64,
) -> PipelineRun {
  let stages = local_file_pipeline_stage_ids().map(pending_pipeline_stage)
  {
    schema_version: "moondata.pipeline-run.v1",
    run_id,
    pipeline_kind: "local-file-product",
    status: "queued",
    revision: 0,
    attempt: 0,
    created_at_ms,
    updated_at_ms: created_at_ms,
    current_stage: "",
    cancel_requested: false,
    request,
    stages,
    error: None,
    validation_report_id: "",
    validation_status: "not-run",
  }
}

///|
fn replace_pipeline_stage(
  stages : Array[PipelineStageRun],
  replacement : PipelineStageRun,
) -> Array[PipelineStageRun] {
  stages.map(fn(stage) {
    if stage.stage_id == replacement.stage_id {
      replacement
    } else {
      stage
    }
  })
}

///|
fn pipeline_stage(run : PipelineRun, stage_id : String) -> PipelineStageRun? {
  for stage in run.stages {
    if stage.stage_id == stage_id {
      return Some(stage)
    }
  }
  None
}

///|
fn start_pipeline_attempt(run : PipelineRun, now_ms : Int64) -> PipelineRun {
  {
    ..run,
    status: "running",
    revision: run.revision + 1,
    attempt: run.attempt + 1,
    updated_at_ms: now_ms,
    current_stage: "",
    error: None,
  }
}

///|
fn start_pipeline_stage(
  run : PipelineRun,
  stage_id : String,
  now_ms : Int64,
) -> PipelineRun {
  let stage = pipeline_stage(run, stage_id).unwrap_or(
    pending_pipeline_stage(stage_id),
  )
  let running = {
    ..stage,
    status: "running",
    attempt: stage.attempt + 1,
    started_at_ms: now_ms,
    completed_at_ms: 0L,
    message: "running",
  }
  {
    ..run,
    status: "running",
    revision: run.revision + 1,
    updated_at_ms: now_ms,
    current_stage: stage_id,
    stages: replace_pipeline_stage(run.stages, running),
  }
}

///|
fn complete_pipeline_stage(
  run : PipelineRun,
  stage_id : String,
  message : String,
  now_ms : Int64,
) -> PipelineRun {
  let stage = pipeline_stage(run, stage_id).unwrap_or(
    pending_pipeline_stage(stage_id),
  )
  let completed = {
    ..stage,
    status: "succeeded",
    completed_at_ms: now_ms,
    message,
  }
  {
    ..run,
    revision: run.revision + 1,
    updated_at_ms: now_ms,
    current_stage: "",
    stages: replace_pipeline_stage(run.stages, completed),
  }
}

///|
fn fail_pipeline_stage(
  run : PipelineRun,
  stage_id : String,
  failure : @moondata_store.MoonDataStoreIssue,
  now_ms : Int64,
) -> PipelineRun {
  let stage = pipeline_stage(run, stage_id).unwrap_or(
    pending_pipeline_stage(stage_id),
  )
  let failed = {
    ..stage,
    status: "failed",
    completed_at_ms: now_ms,
    message: failure.message,
  }
  {
    ..run,
    status: "failed",
    revision: run.revision + 1,
    updated_at_ms: now_ms,
    current_stage: stage_id,
    stages: replace_pipeline_stage(run.stages, failed),
    error: Some({
      stage_id,
      code: failure.code,
      path: failure.path,
      message: failure.message,
    }),
  }
}

///|
fn complete_pipeline_run(
  run : PipelineRun,
  validation_report_id : String,
  now_ms : Int64,
) -> PipelineRun {
  {
    ..run,
    status: "succeeded",
    revision: run.revision + 1,
    updated_at_ms: now_ms,
    current_stage: "",
    error: None,
    validation_report_id,
    validation_status: "passed",
  }
}

///|
fn cancel_pipeline_run(run : PipelineRun, now_ms : Int64) -> PipelineRun {
  {
    ..run,
    status: "canceled",
    revision: run.revision + 1,
    updated_at_ms: now_ms,
    current_stage: "",
    cancel_requested: true,
  }
}

///|
fn request_pipeline_cancel(run : PipelineRun, now_ms : Int64) -> PipelineRun {
  if run.status == "succeeded" || run.status == "canceled" {
    run
  } else {
    {
      ..run,
      revision: run.revision + 1,
      updated_at_ms: now_ms,
      cancel_requested: true,
    }
  }
}

///|
fn reset_pipeline_retry(run : PipelineRun, now_ms : Int64) -> PipelineRun {
  let stages = run.stages.map(fn(stage) {
    if stage.status == "failed" || stage.status == "running" {
      { ..stage, status: "pending", completed_at_ms: 0L, message: "waiting" }
    } else {
      stage
    }
  })
  {
    ..run,
    status: "queued",
    revision: run.revision + 1,
    updated_at_ms: now_ms,
    current_stage: "",
    cancel_requested: false,
    stages,
    error: None,
  }
}
