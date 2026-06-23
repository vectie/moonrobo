///|
pub(all) struct RegistryIssue {
  code : String
  path : String
  message : String
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct ToolCapability {
  capability_id : String
  label : String
  http_method : String
  route : String
  body_schema : String
  execution_mode : String
  physical_execution_allowed : Bool
  safety_note : String
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct ToolProvider {
  provider_id : String
  label : String
  kind : String
  robot_id : @core.RobotId
  endpoint_base : String
  memory_required : Bool
  capabilities : Array[ToolCapability]
  registered_at_ms : Int64
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct ToolRegistry {
  registry_id : String
  robot_id : @core.RobotId
  generated_at_ms : Int64
  provider_count : Int
  capability_count : Int
  providers : Array[ToolProvider]
} derive(Debug, Eq, ToJson, FromJson)

///|
fn issue(code : String, path : String, message : String) -> RegistryIssue {
  { code, path, message }
}

///|
fn route_capability(
  capability_id : String,
  label : String,
  http_method : String,
  route : String,
  body_schema : String,
  execution_mode : String,
  safety_note : String,
) -> ToolCapability {
  {
    capability_id,
    label,
    http_method,
    route,
    body_schema,
    execution_mode,
    physical_execution_allowed: false,
    safety_note,
  }
}

///|
fn provider(
  provider_id : String,
  label : String,
  kind : String,
  robot_id : @core.RobotId,
  endpoint_base : String,
  memory_required : Bool,
  capabilities : Array[ToolCapability],
  registered_at_ms : Int64,
) -> ToolProvider {
  {
    provider_id,
    label,
    kind,
    robot_id,
    endpoint_base,
    memory_required,
    capabilities,
    registered_at_ms,
  }
}

///|
fn capability_count(providers : Array[ToolProvider]) -> Int {
  let mut count = 0
  for item in providers {
    count += item.capabilities.length()
  }
  count
}

///|
pub fn registry(
  robot_id : @core.RobotId,
  providers : Array[ToolProvider],
  generated_at_ms : Int64,
) -> ToolRegistry {
  {
    registry_id: "tool-registry-\{robot_id}",
    robot_id,
    generated_at_ms,
    provider_count: providers.length(),
    capability_count: capability_count(providers),
    providers,
  }
}

///|
pub fn moonrobo_host_provider(
  robot_id : @core.RobotId,
  registered_at_ms : Int64,
) -> ToolProvider {
  provider(
    "moonrobo-host-api",
    "Moonrobo Host API",
    "moonrobo-runtime",
    robot_id,
    "/api",
    true,
    [
      route_capability(
        "resident.read", "Read resident robot state", "GET", "/api/moontown/resident",
        "none", "read-only", "Read the Moontown robot projection without bridge authority.",
      ),
      route_capability(
        "memory.read", "Read MoonBook memory", "GET", "/api/moonbook/memory", "none",
        "read-only", "Read durable robot memory packs only.",
      ),
      route_capability(
        "task.message", "Submit operator task message", "POST", "/api/moontown/tasks/message",
        "TaskMessageRequest", "task-ingress", "Accepts observation-oriented task messages and rejects physical action wording.",
      ),
      route_capability(
        "agent.next-action", "Read next safe work item", "GET", "/api/agent/next-action",
        "none", "read-only", "Returns a typed plan for the highest-priority queue item.",
      ),
      route_capability(
        "agent.dispatch-evidence", "Dispatch allowlisted evidence action", "POST",
        "/api/agent/dispatch-next", "AgentDispatchRequest", "bounded-evidence", "Dispatches only allowlisted non-physical evidence routes.",
      ),
    ],
    registered_at_ms,
  )
}

///|
pub fn moonclaw_process_provider(
  robot_id : @core.RobotId,
  registered_at_ms : Int64,
) -> ToolProvider {
  provider(
    "moonclaw-process-planner",
    "MoonClaw Process Planner",
    "suite-tool",
    robot_id,
    "/api/moonclaw",
    true,
    [
      route_capability(
        "moonclaw.context", "Read planning context", "GET", "/api/moonclaw/context",
        "none", "read-only", "Reads resident, review, and evidence context for planning.",
      ),
      route_capability(
        "moonclaw.run-next", "Run bounded next process", "POST", "/api/moonclaw/run-next",
        "AgentProcessRunRequest", "bounded-process", "Runs the bounded process gate; physical execution still requires the Moonrobo safety pipeline.",
      ),
    ],
    registered_at_ms,
  )
}

///|
pub fn rabbita_cockpit_provider(
  robot_id : @core.RobotId,
  registered_at_ms : Int64,
) -> ToolProvider {
  provider(
    "rabbita-operator-cockpit",
    "Rabbita Operator Cockpit",
    "operator-surface",
    robot_id,
    "/",
    true,
    [
      route_capability(
        "cockpit.snapshot", "Read cockpit snapshot", "GET", "/api/cockpit/snapshot",
        "none", "read-only", "Renders robot state and evidence without owning robot parsing or bridge authority.",
      ),
      route_capability(
        "cockpit.task-message", "Submit cockpit task message", "POST", "/api/moontown/tasks/message",
        "TaskMessageRequest", "task-ingress", "Submits operator text into the same task and memory path as scheduled Moontown work.",
      ),
    ],
    registered_at_ms,
  )
}

///|
pub fn default_registry(
  robot_id : @core.RobotId,
  generated_at_ms : Int64,
) -> ToolRegistry {
  registry(
    robot_id,
    [
      moonrobo_host_provider(robot_id, generated_at_ms),
      moonclaw_process_provider(robot_id, generated_at_ms),
      rabbita_cockpit_provider(robot_id, generated_at_ms),
    ],
    generated_at_ms,
  )
}

///|
pub fn with_provider(
  current : ToolRegistry,
  provider : ToolProvider,
  generated_at_ms : Int64,
) -> ToolRegistry {
  let providers : Array[ToolProvider] = []
  let mut replaced = false
  for item in current.providers {
    if item.provider_id == provider.provider_id {
      providers.push(provider)
      replaced = true
    } else {
      providers.push(item)
    }
  }
  if !replaced {
    providers.push(provider)
  }
  registry(current.robot_id, providers, generated_at_ms)
}

///|
fn require_non_blank(
  issues : Array[RegistryIssue],
  path : String,
  value : String,
) -> Unit {
  if value.trim().to_owned() == "" {
    issues.push(issue("missing-field", path, "\{path} must not be empty"))
  }
}

///|
pub fn validate_provider(provider : ToolProvider) -> Array[RegistryIssue] {
  let issues : Array[RegistryIssue] = []
  require_non_blank(issues, "provider_id", provider.provider_id)
  require_non_blank(issues, "label", provider.label)
  require_non_blank(issues, "kind", provider.kind)
  require_non_blank(issues, "robot_id", provider.robot_id)
  if provider.capabilities.is_empty() {
    issues.push(
      issue(
        "missing-capability", "capabilities", "tool provider must expose at least one capability",
      ),
    )
  }
  for capability in provider.capabilities {
    require_non_blank(
      issues,
      "capabilities[].capability_id",
      capability.capability_id,
    )
    require_non_blank(issues, "capabilities[].label", capability.label)
    require_non_blank(
      issues,
      "capabilities[].http_method",
      capability.http_method,
    )
    require_non_blank(issues, "capabilities[].route", capability.route)
    if capability.physical_execution_allowed {
      issues.push(
        issue(
          "physical-tool-capability", "capabilities[].physical_execution_allowed",
          "tool registry entries cannot grant physical execution authority",
        ),
      )
    }
  }
  issues
}

///|
pub fn validate_registry(registry : ToolRegistry) -> Array[RegistryIssue] {
  let issues : Array[RegistryIssue] = []
  require_non_blank(issues, "registry_id", registry.registry_id)
  require_non_blank(issues, "robot_id", registry.robot_id)
  for provider in registry.providers {
    for item in validate_provider(provider) {
      issues.push(item)
    }
    if provider.robot_id != registry.robot_id {
      issues.push(
        issue(
          "robot-mismatch", "providers[].robot_id", "tool provider robot_id must match registry robot_id",
        ),
      )
    }
  }
  if registry.provider_count != registry.providers.length() {
    issues.push(
      issue(
        "provider-count-mismatch", "provider_count", "provider_count must match providers length",
      ),
    )
  }
  if registry.capability_count != capability_count(registry.providers) {
    issues.push(
      issue(
        "capability-count-mismatch", "capability_count", "capability_count must match provider capabilities",
      ),
    )
  }
  issues
}
