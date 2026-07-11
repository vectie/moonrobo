///|
fn pipeline_issue(
  code : String,
  path : String,
  message : String,
) -> @moondata_store.MoonDataStoreIssue {
  { code, path, message }
}

///|
fn safe_pipeline_run_id(run_id : String) -> Bool {
  run_id != "" &&
  !run_id.contains("/") &&
  !run_id.contains("\\") &&
  run_id != "." &&
  run_id != ".."
}

///|
pub fn pipeline_run_path(root : String, run_id : String) -> String {
  let separator = if root.has_suffix("/") { "" } else { "/" }
  root + separator + "runs/pipelines/" + run_id + ".json"
}

///|
fn decode_pipeline_run_file(
  path : String,
) -> Result[PipelineRun, @moondata_store.MoonDataStoreIssue] {
  let text = @fsx.read_file_to_string(path) catch {
    _ =>
      return Err(
        pipeline_issue(
          "read-pipeline-run", path, "failed to read MoonData pipeline run",
        ),
      )
  }
  let json = @json.parse(text) catch {
    _ =>
      return Err(
        pipeline_issue(
          "parse-pipeline-run", path, "failed to parse MoonData pipeline run",
        ),
      )
  }
  let run : PipelineRun = @json.from_json(json) catch {
    _ =>
      return Err(
        pipeline_issue(
          "decode-pipeline-run", path, "failed to decode MoonData pipeline run contract",
        ),
      )
  }
  Ok(run)
}

///|
fn recover_pipeline_run_file(
  path : String,
) -> Result[PipelineRun, @moondata_store.MoonDataStoreIssue] {
  match decode_pipeline_run_file(path) {
    Ok(run) => Ok(run)
    Err(current_error) => {
      let next_path = path + ".next"
      if @fsx.path_exists(next_path) {
        match decode_pipeline_run_file(next_path) {
          Ok(run) => return Ok(run)
          Err(_) => ()
        }
      }
      let previous_path = path + ".previous"
      if @fsx.path_exists(previous_path) {
        match decode_pipeline_run_file(previous_path) {
          Ok(run) => return Ok(run)
          Err(_) => ()
        }
      }
      Err(current_error)
    }
  }
}

///|
fn write_pipeline_text(
  path : String,
  text : String,
) -> Result[Unit, @moondata_store.MoonDataStoreIssue] {
  @fsx.write_string_to_file(path, text) catch {
    _ =>
      return Err(
        pipeline_issue(
          "write-pipeline-run", path, "failed to persist MoonData pipeline run",
        ),
      )
  }
  Ok(())
}

///|
pub fn write_pipeline_run(
  root : String,
  run : PipelineRun,
) -> Result[String, @moondata_store.MoonDataStoreIssue] {
  if !safe_pipeline_run_id(run.run_id) {
    return Err(
      pipeline_issue(
        "pipeline-run-id-unsafe",
        run.run_id,
        "pipeline run id must be a path-safe local identifier",
      ),
    )
  }
  match @moondata_store.initialize_root(root) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  let path = pipeline_run_path(root, run.run_id)
  let next_path = path + ".next"
  let previous_path = path + ".previous"
  let body = run.to_json().stringify(indent=2)
  match write_pipeline_text(next_path, body) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  match decode_pipeline_run_file(next_path) {
    Ok(staged) =>
      if staged != run {
        return Err(
          pipeline_issue(
            "verify-pipeline-run", next_path, "staged MoonData pipeline run changed during serialization",
          ),
        )
      }
    Err(error) => return Err(error)
  }
  if @fsx.path_exists(path) {
    let current = @fsx.read_file_to_string(path) catch { _ => "" }
    if current != "" {
      match write_pipeline_text(previous_path, current) {
        Ok(_) => ()
        Err(error) => return Err(error)
      }
    }
  }
  match write_pipeline_text(path, body) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  if @fsx.path_exists(next_path) {
    @fsx.remove_file(next_path) catch {
      _ => ()
    }
  }
  Ok(path)
}

///|
pub fn read_pipeline_run(
  root : String,
  run_id : String,
) -> Result[PipelineRun, @moondata_store.MoonDataStoreIssue] {
  if !safe_pipeline_run_id(run_id) {
    return Err(
      pipeline_issue(
        "pipeline-run-id-unsafe", run_id, "pipeline run id must be a path-safe local identifier",
      ),
    )
  }
  let path = pipeline_run_path(root, run_id)
  recover_pipeline_run_file(path)
}

///|
pub fn list_pipeline_runs(
  root : String,
) -> Result[Array[PipelineRun], @moondata_store.MoonDataStoreIssue] {
  match @moondata_store.initialize_root(root) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  let separator = if root.has_suffix("/") { "" } else { "/" }
  let dir = root + separator + "runs/pipelines"
  let names = @fsx.read_dir(dir) catch {
    _ =>
      return Err(
        pipeline_issue(
          "list-pipeline-runs", dir, "failed to list MoonData pipeline runs",
        ),
      )
  }
  let runs : Array[PipelineRun] = []
  for name in names {
    if name.has_suffix(".json") {
      let path = dir + "/" + name
      match recover_pipeline_run_file(path) {
        Ok(run) => runs.push(run)
        Err(_) => continue
      }
    }
  }
  Ok(runs)
}
