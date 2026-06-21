///|
pub(all) struct DesktopRoute {
  http_method : String
  path : String
  body : String
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct DesktopHostConfig {
  robotbook_root : String
  ui_root : String
  host : String
  port : Int
  sidecar_path : String
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
pub fn readiness_path() -> String {
  "/__moonrobo_health"
}

///|
pub fn default_config(robotbook_root : String) -> DesktopHostConfig {
  {
    robotbook_root,
    ui_root: default_ui_root(),
    host: default_host(),
    port: default_port(),
    sidecar_path: default_sidecar_path(),
  }
}

///|
pub fn config(
  robotbook_root : String,
  ui_root? : String = default_ui_root(),
  host? : String = default_host(),
  port? : Int = default_port(),
  sidecar_path? : String = default_sidecar_path(),
) -> DesktopHostConfig {
  { robotbook_root, ui_root, host, port, sidecar_path }
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
      body: "bridge sidecar manifest",
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
      path: @host_api.agent_work_queue_path(),
      body: "agent work queue projection",
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
    "robotbook_root": config.robotbook_root,
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
    "robotbook_root": config.robotbook_root,
    "ui_root": config.ui_root,
    "readiness_path": readiness_path(),
    "routes": route_catalog_json(),
    "bridge_sidecar_manifest_path": @host_api.bridge_sidecar_path(),
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
            config.robotbook_root,
            config.ui_root,
            config.host,
            config.port.to_string(),
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
