///|
pub(all) struct ReadinessCheck {
  code : String
  status : String
  path : String
  message : String
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct PlatformReadinessReport {
  report_id : String
  root : String
  robot_id : @core.RobotId
  ready : Bool
  status : String
  check_count : Int
  pass_count : Int
  fail_count : Int
  conversation_turn_count : Int
  memory_card_count : Int
  registered_capability_count : Int
  task_execution_count : Int
  latest_runtime_status : String
  checks : Array[ReadinessCheck]
} derive(Debug, Eq, ToJson, FromJson)

///|
fn check(
  code : String,
  status : String,
  path : String,
  message : String,
) -> ReadinessCheck {
  { code, status, path, message }
}

///|
fn pass(code : String, path : String, message : String) -> ReadinessCheck {
  check(code, "pass", path, message)
}

///|
fn fail(code : String, path : String, message : String) -> ReadinessCheck {
  check(code, "fail", path, message)
}

///|
fn count_status(checks : Array[ReadinessCheck], status : String) -> Int {
  let mut count = 0
  for item in checks {
    if item.status == status {
      count += 1
    }
  }
  count
}

///|
fn task_message_count(root : String) -> Int {
  match @runtime.list_moonbook_task_message_paths(root) {
    Ok(paths) => paths.length()
    Err(_) => 0
  }
}

///|
fn task_execution_count(root : String) -> Int {
  match @runtime.list_task_execution_snapshot_paths(root) {
    Ok(paths) => paths.length()
    Err(_) => 0
  }
}

///|
fn latest_memory(root : String) -> @moonbook.MoonBookMemoryPack? {
  let paths = match @runtime.list_moonbook_memory_paths(root) {
    Ok(paths) => paths
    Err(_) => return None
  }
  if paths.is_empty() {
    return None
  }
  let text = match
    @runtime.read_moonbook_memory_json_file(paths[paths.length() - 1]) {
    Ok(text) => text
    Err(_) => return None
  }
  let json = @json.parse(text) catch { _ => return None }
  let pack : @moonbook.MoonBookMemoryPack = @json.from_json(json) catch {
    _ => return None
  }
  Some(pack)
}

///|
fn latest_runtime_health(root : String) -> @runtime_health.RuntimeHealthRecord? {
  match @runtime.read_latest_runtime_health(root) {
    Ok(record) => record
    Err(_) => None
  }
}

///|
fn tool_registry(root : String) -> @tool_registry.ToolRegistry? {
  match @runtime.read_tool_registry(root) {
    Ok(registry) => Some(registry)
    Err(_) => None
  }
}

///|
fn capability_available(
  registry : @tool_registry.ToolRegistry,
  route : String,
) -> Bool {
  registry.providers.any(fn(provider) {
    provider.capabilities.any(fn(capability) { capability.route == route })
  })
}

///|
fn registry_ready(
  registry : @tool_registry.ToolRegistry?,
  robot_id : @core.RobotId,
) -> ReadinessCheck {
  match registry {
    Some(value) =>
      if value.robot_id == robot_id &&
        capability_available(value, "/api/moonbook/conversation") &&
        capability_available(value, "/api/moontown/tasks/message") &&
        capability_available(value, "/api/moontown/tasks/observe-run") {
        pass(
          "tool-registry-ready", "agents/tool-registry.json", "bounded Moonrobo tool capabilities are registered",
        )
      } else {
        fail(
          "tool-registry-ready", "agents/tool-registry.json", "tool registry is missing required Moonrobo capabilities",
        )
      }
    None =>
      fail(
        "tool-registry-ready", "agents/tool-registry.json", "tool registry is not persisted",
      )
  }
}

///|
pub fn report(
  root : String,
  book : @runtime.LoadedRoboBook,
) -> PlatformReadinessReport {
  let task_messages = task_message_count(root)
  let executions = task_execution_count(root)
  let memory = latest_memory(root)
  let health = latest_runtime_health(root)
  let registry = tool_registry(root)
  let memory_card_count = match memory {
    Some(pack) => pack.card_count
    None => 0
  }
  let capability_count = match registry {
    Some(value) => value.capability_count
    None => 0
  }
  let runtime_status = match health {
    Some(record) => record.status
    None => "missing"
  }
  let checks : Array[ReadinessCheck] = [
    if book.status.ready {
      pass(
        "robobook-ready", root, "RoboBook profile and required paths are ready",
      )
    } else {
      fail(
        "robobook-ready", root, "RoboBook profile or required paths are not ready",
      )
    },
    if task_messages > 0 {
      pass(
        "task-message-present", "moonbook/task-messages", "MoonBook has persisted task messages",
      )
    } else {
      fail(
        "task-message-present", "moonbook/task-messages", "MoonBook has no persisted task messages",
      )
    },
    if memory_card_count > 0 {
      pass(
        "moonbook-memory-ready", "moonbook/memory", "MoonBook memory contains robot recall cards",
      )
    } else {
      fail(
        "moonbook-memory-ready", "moonbook/memory", "MoonBook memory is not persisted",
      )
    },
    registry_ready(registry, book.profile.id),
    if runtime_status == "healthy" {
      pass(
        "runtime-health-ready", "runs/runtime-health/latest.json", "runtime health is healthy",
      )
    } else {
      fail(
        "runtime-health-ready", "runs/runtime-health/latest.json", "runtime health is not healthy",
      )
    },
    if executions > 0 {
      pass(
        "task-execution-ready", "runs/task-executions", "task execution evidence is persisted",
      )
    } else {
      fail(
        "task-execution-ready", "runs/task-executions", "no task execution evidence is persisted",
      )
    },
  ]
  let fail_count = count_status(checks, "fail")
  let pass_count = count_status(checks, "pass")
  let ready = fail_count == 0
  {
    report_id: "moonrobo-readiness-\{book.profile.id}",
    root,
    robot_id: book.profile.id,
    ready,
    status: if ready {
      "ready"
    } else {
      "blocked"
    },
    check_count: checks.length(),
    pass_count,
    fail_count,
    conversation_turn_count: task_messages,
    memory_card_count,
    registered_capability_count: capability_count,
    task_execution_count: executions,
    latest_runtime_status: runtime_status,
    checks,
  }
}

///|
pub fn report_json(
  report : PlatformReadinessReport,
  indent? : Int = 2,
) -> String {
  report.to_json().stringify(indent~)
}
