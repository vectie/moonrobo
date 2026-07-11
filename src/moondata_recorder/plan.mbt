///|
fn recorder_issue(
  code : String,
  path : String,
  message : String,
) -> @moondata_store.MoonDataStoreIssue {
  { code, path, message }
}

///|
fn safe_session_id(session_id : String) -> Bool {
  session_id != "" &&
  !session_id.contains("/") &&
  !session_id.contains("\\") &&
  session_id != "." &&
  session_id != ".."
}

///|
fn root_path(root : String, relative : String) -> String {
  if root.has_suffix("/") {
    root + relative
  } else {
    root + "/" + relative
  }
}

///|
fn validate_topic(topic : String) -> Bool {
  topic.has_prefix("/") && !topic.contains(" ") && !topic.contains("\t")
}

///|
pub fn recorder_plan(
  root : String,
  session_id : String,
  robot_id : String,
  bridge_id : String,
  topics? : Array[String] = [],
  all_topics? : Bool = true,
  max_bag_size_bytes? : Int64 = 1073741824L,
  max_bag_duration_seconds? : Int64 = 300L,
  max_cache_size_bytes? : Int64 = 104857600L,
  max_bag_files? : Int = 24,
  minimum_free_bytes? : Int64 = 5368709120L,
  executable? : String = "ros2",
  executable_args? : Array[String] = [],
) -> Result[RecorderPlan, @moondata_store.MoonDataStoreIssue] {
  if !safe_session_id(session_id) {
    return Err(
      recorder_issue(
        "recorder-session-id-unsafe", session_id, "recorder session id must be a path-safe local identifier",
      ),
    )
  }
  if root == "" || robot_id == "" || bridge_id == "" || executable == "" {
    return Err(
      recorder_issue(
        "recorder-identity-empty", session_id, "root, robot id, bridge id, and executable are required",
      ),
    )
  }
  if !all_topics && topics.is_empty() {
    return Err(
      recorder_issue(
        "recorder-topics-empty", session_id, "select all topics or provide at least one explicit ROS topic",
      ),
    )
  }
  for topic in topics {
    if !validate_topic(topic) {
      return Err(
        recorder_issue(
          "recorder-topic-invalid", topic, "ROS topics must be absolute names without whitespace",
        ),
      )
    }
  }
  if max_bag_size_bytes < 86017L ||
    max_bag_duration_seconds <= 0L ||
    max_cache_size_bytes < 0L ||
    max_bag_files <= 0 ||
    minimum_free_bytes <= max_bag_size_bytes {
    return Err(
      recorder_issue(
        "recorder-policy-invalid", session_id, "rotation, retention, cache, and disk reserve limits must be positive and internally consistent",
      ),
    )
  }
  let output_dir = root_path(root, "incoming/" + session_id)
  let command : Array[String] = []
  command.push(executable)
  for arg in executable_args {
    command.push(arg)
  }
  for
    arg in [
      "bag",
      "record",
      "--storage",
      "mcap",
      "--output",
      output_dir,
      "--max-bag-size",
      "\{max_bag_size_bytes}",
      "--max-bag-duration",
      "\{max_bag_duration_seconds}",
      "--max-cache-size",
      "\{max_cache_size_bytes}",
      "--max-bag-files",
      "\{max_bag_files}",
      "--stats_max_publishing_rate",
      "1.0",
    ] {
    command.push(arg)
  }
  if all_topics {
    command.push("--all")
  } else {
    command.push("--topics")
    for topic in topics {
      command.push(topic)
    }
  }
  Ok({
    schema_version: "moondata.recorder-plan.v1",
    root,
    session_id,
    robot_id,
    bridge_id,
    output_dir,
    script_path: root_path(root, "runs/recorders/" + session_id + ".sh"),
    log_path: root_path(root, "logs/recorders/" + session_id + ".log"),
    topics,
    all_topics,
    max_bag_size_bytes,
    max_bag_duration_seconds,
    max_cache_size_bytes,
    max_bag_files,
    minimum_free_bytes,
    command,
  })
}

///|
fn shell_quote(value : String) -> String {
  "'" + value.replace(old="'", new="'\"'\"'") + "'"
}

///|
pub fn recorder_script(plan : RecorderPlan) -> String {
  let command = [ for arg in plan.command => shell_quote(arg) ].join(" ")
  [
    "#!/bin/sh",
    "set -eu",
    "exec >> " + shell_quote(plan.log_path) + " 2>&1",
    "exec " + command,
    "",
  ].join("\n")
}
