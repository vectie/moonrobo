///|
pub(all) struct RuntimeLaunchReceipt {
  launch_id : String
  runtime_id : String
  robot_id : String
  bridge_id : String
  status : String
  ready : Bool
  script_path : String
  log_path : String
  receipt_path : String
  command : Array[String]
  bridge_base_url : String
  issue_count : Int
  plan : @supervisor.SupervisorPlan
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct RuntimeLaunchResult {
  persisted : Bool
  launch_id : String
  script_path : String
  receipt_path : String
  command : Array[String]
  receipt : RuntimeLaunchReceipt
} derive(Debug, Eq, ToJson, FromJson)

///|
fn issue(
  status : Int,
  code : String,
  path : String,
  message : String,
) -> @pipeline.PipelineIssue {
  { http_status: status, code, path, message }
}

///|
fn launcher_dir(root : String) -> String {
  @runtime.moonrobo_runtime_supervisor_dir(root)
}

///|
fn ensure_launcher_dir(root : String) -> Result[Unit, @pipeline.PipelineIssue] {
  match @runtime.ensure_process_dirs(root) {
    Ok(_) => ()
    Err(error) => return Err(issue(500, error.code, error.path, error.message))
  }
  let dir = launcher_dir(root)
  if @fsx.path_exists(dir) {
    Ok(())
  } else {
    @fsx.create_dir(dir) catch {
      _ =>
        return Err(
          issue(
            500, "create-runtime-launch-dir", dir, "failed to create runtime supervisor launch directory",
          ),
        )
    }
    Ok(())
  }
}

///|
pub fn launch_id_for_plan(plan : @supervisor.SupervisorPlan) -> String {
  "runtime-supervisor-\{plan.runtime_id}"
}

///|
pub fn script_path(root : String, launch_id : String) -> String {
  launcher_dir(root) + "/\{launch_id}.sh"
}

///|
pub fn log_path(root : String, launch_id : String) -> String {
  launcher_dir(root) + "/\{launch_id}.log"
}

///|
pub fn receipt_path(root : String, launch_id : String) -> String {
  launcher_dir(root) + "/\{launch_id}.json"
}

///|
pub fn active_run_path(root : String) -> String {
  launcher_dir(root) + "/active.json"
}

///|
pub fn receipt_json(
  receipt : RuntimeLaunchReceipt,
  indent? : Int = 2,
) -> String {
  receipt.to_json().stringify(indent~)
}

///|
pub fn prepare_launch(
  root : String,
  plan : @supervisor.SupervisorPlan,
  launch_id? : String = launch_id_for_plan(plan),
) -> Result[RuntimeLaunchResult, @pipeline.PipelineIssue] {
  match ensure_launcher_dir(root) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  let script = script_path(root, launch_id)
  let log_file = log_path(root, launch_id)
  let receipt_file = receipt_path(root, launch_id)
  @fsx.write_string_to_file(
    script,
    @supervisor.shell_script(plan, log_path=log_file),
  ) catch {
    _ =>
      return Err(
        issue(
          500, "write-runtime-launch-script", script, "failed to write runtime supervisor script",
        ),
      )
  }
  let command = ["sh", script]
  let receipt : RuntimeLaunchReceipt = {
    launch_id,
    runtime_id: plan.runtime_id,
    robot_id: plan.robot_id,
    bridge_id: plan.bridge_id,
    status: if plan.ready {
      "prepared"
    } else {
      "blocked"
    },
    ready: plan.ready,
    script_path: script,
    log_path: log_file,
    receipt_path: receipt_file,
    command,
    bridge_base_url: plan.bridge_base_url,
    issue_count: plan.issues.length(),
    plan,
  }
  @fsx.write_string_to_file(receipt_file, receipt_json(receipt)) catch {
    _ =>
      return Err(
        issue(
          500, "write-runtime-launch-receipt", receipt_file, "failed to write runtime supervisor launch receipt",
        ),
      )
  }
  Ok({
    persisted: true,
    launch_id,
    script_path: script,
    receipt_path: receipt_file,
    command,
    receipt,
  })
}
