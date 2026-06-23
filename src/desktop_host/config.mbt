///|
pub(all) struct DesktopRoute {
  http_method : String
  path : String
  body : String
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct DesktopHostConfig {
  robobook_root : String
  ui_root : String
  host : String
  port : Int
  sidecar_path : String
  bridge_host : String
  bridge_port : Int
} derive(Debug, Eq, ToJson, FromJson)

///|
pub fn default_host() -> String {
  "127.0.0.1"
}

///|
pub fn default_port() -> Int {
  5290
}

///|
pub fn default_ui_root() -> String {
  "ui/rabbita-cockpit"
}

///|
pub fn default_sidecar_path() -> String {
  "moonrobo-sidecar"
}

///|
pub fn default_bridge_host() -> String {
  "127.0.0.1"
}

///|
pub fn default_bridge_port() -> Int {
  5391
}

///|
pub fn readiness_path() -> String {
  "/__moonrobo_health"
}

///|
pub fn default_config(robobook_root : String) -> DesktopHostConfig {
  {
    robobook_root,
    ui_root: default_ui_root(),
    host: default_host(),
    port: default_port(),
    sidecar_path: default_sidecar_path(),
    bridge_host: default_bridge_host(),
    bridge_port: default_bridge_port(),
  }
}

///|
pub fn config(
  robobook_root : String,
  ui_root? : String = default_ui_root(),
  host? : String = default_host(),
  port? : Int = default_port(),
  sidecar_path? : String = default_sidecar_path(),
  bridge_host? : String = default_bridge_host(),
  bridge_port? : Int = default_bridge_port(),
) -> DesktopHostConfig {
  { robobook_root, ui_root, host, port, sidecar_path, bridge_host, bridge_port }
}

///|
pub fn base_url(config : DesktopHostConfig) -> String {
  "http://\{config.host}:\{config.port}"
}

///|
pub fn route_catalog() -> Array[DesktopRoute] {
  [
    {
      http_method: "GET",
      path: readiness_path(),
      body: "desktop host readiness",
    },
    {
      http_method: "GET",
      path: @host_api.health_path(),
      body: "robot runtime health",
    },
    {
      http_method: "GET",
      path: @host_api.snapshot_path(),
      body: "cockpit snapshot projection",
    },
    {
      http_method: "GET",
      path: @host_api.bridge_sidecar_path(),
      body: "bridge sidecar and physical runtime manifest",
    },
    {
      http_method: "GET",
      path: @host_api.runtime_supervisor_path(),
      body: "physical runtime supervisor plan",
    },
    {
      http_method: "GET",
      path: @host_api.runtime_supervisor_script_path(),
      body: "physical runtime supervisor shell script",
    },
    {
      http_method: "POST",
      path: @host_api.runtime_supervisor_launch_path(),
      body: "prepare physical runtime supervisor launch receipt",
    },
    {
      http_method: "GET",
      path: @host_api.runtime_supervisor_run_path(),
      body: "physical runtime supervisor active process receipt",
    },
    {
      http_method: "GET",
      path: @host_api.runtime_health_path(),
      body: "physical runtime health and telemetry probe",
    },
    {
      http_method: "POST",
      path: @host_api.runtime_supervisor_start_path(),
      body: "start physical runtime supervisor process",
    },
    {
      http_method: "POST",
      path: @host_api.runtime_supervisor_stop_path(),
      body: "stop physical runtime supervisor process",
    },
    {
      http_method: "POST",
      path: @host_api.runtime_emergency_stop_path(),
      body: "send emergency stop through active physical runtime",
    },
    {
      http_method: "GET",
      path: @host_api.resident_path(),
      body: "moontown resident robot projection",
    },
    {
      http_method: "GET",
      path: @host_api.replay_path("{session_id}"),
      body: "observation replay timeline",
    },
    {
      http_method: "GET",
      path: @host_api.dataset_episode_path("{session_id}"),
      body: "dataset episode export",
    },
    {
      http_method: "GET",
      path: @host_api.dataset_episode_quality_path("{session_id}"),
      body: "dataset episode quality report",
    },
    {
      http_method: "GET",
      path: @host_api.moonstat_status_path(),
      body: "moonstat status projection",
    },
    {
      http_method: "GET",
      path: @host_api.moonbook_memory_path(),
      body: "moonbook memory projection",
    },
    {
      http_method: "POST",
      path: @host_api.moonbook_remember_path(),
      body: "persist moonbook memory projection",
    },
    {
      http_method: "GET",
      path: @host_api.moonbook_task_messages_path(),
      body: "moonbook task-message plan ledger",
    },
    {
      http_method: "GET",
      path: @host_api.moonbook_task_message_status_path("{task_id}"),
      body: "moonbook task-message execution status",
    },
    {
      http_method: "POST",
      path: @host_api.moonbook_task_message_execute_sidecar_path("{task_id}"),
      body: "native sidecar execution for a reviewed task message",
    },
    {
      http_method: "GET",
      path: @host_api.agent_work_queue_path(),
      body: "agent work queue projection",
    },
    {
      http_method: "GET",
      path: @host_api.agent_next_action_path(),
      body: "agent next action projection",
    },
    {
      http_method: "POST",
      path: @host_api.agent_dispatch_next_path(),
      body: "safe next action evidence dispatch",
    },
    {
      http_method: "GET",
      path: @host_api.tool_registry_path(),
      body: "bounded tool registry projection",
    },
    {
      http_method: "POST",
      path: @host_api.tool_register_path(),
      body: "persist bounded tool provider metadata",
    },
    {
      http_method: "POST",
      path: @host_api.intent_evaluate_path(),
      body: "safety-gated command intent evaluation",
    },
    {
      http_method: "POST",
      path: @host_api.intent_dry_run_path(),
      body: "dry-run evidence capture",
    },
    {
      http_method: "POST",
      path: @host_api.intent_approve_path(),
      body: "operator approval capture",
    },
    {
      http_method: "POST",
      path: @host_api.intent_execute_path(),
      body: "safety-gated bridge execution",
    },
    {
      http_method: "POST",
      path: @host_api.observation_start_path(),
      body: "read-only observation session start",
    },
    {
      http_method: "POST",
      path: @host_api.observation_frame_path("{id}"),
      body: "read-only observation telemetry frame ingest",
    },
    {
      http_method: "POST",
      path: @host_api.observation_stop_path("{id}"),
      body: "read-only observation session stop",
    },
    {
      http_method: "POST",
      path: @host_api.moontown_observe_task_path(),
      body: "moontown observation task request",
    },
    {
      http_method: "POST",
      path: @host_api.moontown_observe_run_path(),
      body: "moontown observation run pipeline",
    },
  ]
}

///|
pub fn health_json(config : DesktopHostConfig) -> Json {
  {
    "ok": true,
    "service": "moonrobo",
    "robobook_root": config.robobook_root,
    "ui_root": config.ui_root,
    "readiness_path": readiness_path(),
    "snapshot_path": @host_api.snapshot_path(),
    "read_only": true,
  }
}

///|
fn route_catalog_json() -> Array[Json] {
  [
    for route in route_catalog() => route.to_json()
  ]
}

///|
pub fn service_manifest_json(config : DesktopHostConfig) -> Json {
  {
    "kind": "moonrobo-desktop-host",
    "service": "moonrobo",
    "base_url": base_url(config),
    "robobook_root": config.robobook_root,
    "ui_root": config.ui_root,
    "readiness_path": readiness_path(),
    "routes": route_catalog_json(),
    "bridge_sidecar_manifest_path": @host_api.bridge_sidecar_path(),
    "physical_runtime_manifest_path": @host_api.bridge_sidecar_path(),
    "bridge_base_url": "http://\{config.bridge_host}:\{config.bridge_port}",
    "read_only": true,
  }
}

///|
pub fn lepus_project_json(config : DesktopHostConfig) -> Json {
  {
    "identifier": "app.vectie.moonrobo",
    "productName": "Moonrobo",
    "version": "0.1.0",
    "runtime": {
      "backend": "system-webview",
      "assetProtocol": "lepus",
      "devtools": false,
    },
    "window": {
      "label": "main",
      "title": "Moonrobo",
      "width": 1280,
      "height": 820,
      "resizable": true,
      "source": {
        "localhost": {
          "host": config.host,
          "port": config.port,
          "path": "/",
          "readinessPath": readiness_path(),
          "command": [
            config.sidecar_path,
            "serve",
            config.robobook_root,
            config.ui_root,
            config.host,
            config.port.to_string(),
            config.bridge_host,
            config.bridge_port.to_string(),
          ],
        },
      },
    },
    "plugins": [{ "name": "localhost" }, { "name": "serviceDiscovery" }],
    "capabilities": [
      {
        "name": "main",
        "windows": ["main"],
        "permissions": ["localhost", "service-discovery"],
      },
    ],
  }
}
