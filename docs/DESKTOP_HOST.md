# Moonrobo Desktop Host

`src/desktop_host` is the native boundary between the Rabbita cockpit and the
Lepus desktop shell. It keeps the desktop surface thin:

- static Rabbita assets are served from one UI root
- `/__moonrobo_health` reports host readiness
- `/api/health`, `/api/cockpit/snapshot`, `/api/moontown/resident`,
  `/api/moontown/tasks/*`, `/api/bridge/sidecar`, `/api/sessions/*`,
  `/api/replays/*`, `/api/datasets/episodes/*`, `/api/policies/*`, and
  `/api/intents/*` delegate to `src/host_api`
- project metadata is emitted as Lepus JSON

## Commands

```text
moon run cmd/main --target native -- serve [robotbook-root] [ui-root] [host] [port]
moon run cmd/main --target native -- host-manifest [robotbook-root] [ui-root] [host] [port]
moon run cmd/main --target native -- desktop-project [robotbook-root] [ui-root] [host] [port] [sidecar-path]
moon run cmd/main --target native -- desktop-bundle [robotbook-root] [ui-root] [host] [port] [sidecar-path] [bundle-root]
moon run cmd/main --target native -- bridge-sidecar [robotbook-root]
```

Defaults:

```text
robotbook-root: examples/noetix-e1
ui-root: ui/rabbita-cockpit
host: 127.0.0.1
port: 5290
sidecar-path: moonrobo-sidecar
bundle-root: _build/moonrobo-desktop
```

## Boundary

The desktop host does not parse RobotBooks, evaluate safety, or talk directly to
hardware SDKs. It serves local HTTP and Lepus metadata only. Robot logic stays in
`src/core`, `src/runtime`, `src/pipeline`, `src/host_api`, and bridge packages.
`/api/bridge/sidecar` exposes the bridge process manifest owned by
`src/bridge_sidecar`: command, protocol version, health route, telemetry route,
execution route, environment, supervision policy, and launchability status.
`/api/moontown/resident` exposes the selected RobotBook as a read-only resident
robot projection for town surfaces.
`/api/moontown/tasks/observe` lets a town standing goal request a read-only
observation task without taking over bridge control.
`/api/moontown/tasks/observe-run` runs the bounded observation pipeline and
returns persisted evidence, replay, and resident state.
`/api/sessions/{session_id}/frames` appends typed telemetry frames to active
observation sessions.
`/api/replays/{session_id}` exposes a compact replay timeline for the persisted
observation telemetry artifacts.
`/api/datasets/episodes/{session_id}` exports that replay and review evidence
as a dataset episode for offline quality and learning workflows.
`/api/datasets/episodes/{session_id}/quality` reports blockers and warnings for
that episode before it is used in downstream dataset or policy workflows.
`POST /api/policies/evaluate` converts a learned-policy proposal into a
command intent, evaluates the safety result, writes the run receipt plus
`runs/policy-evals/{evaluation_id}.json`, and keeps
`physical_execution_allowed` false.
`GET /api/policies/evaluations` and
`GET /api/policies/evaluations/{evaluation_id}` expose that ledger for
read-only audit.

The current server handles accepted TCP connections concurrently and closes each
connection after one HTTP response. This keeps the first desktop sidecar simple
while supporting browser burst loads for the Rabbita shell and API routes.

`POST /api/intents/evaluate` accepts one command-intent submission, evaluates it
through the safety pipeline, writes a RobotBook receipt, and returns the pipeline
result. `POST /api/intents/dry-run` and `POST /api/intents/approve` write the
evidence IDs needed for a later ready evaluation. `POST /api/intents/execute`
revalidates that evidence and records bridge completion through the execution
boundary. The current local host uses deterministic completion until a supervised
SDK sidecar owns the physical transport.
`POST /api/sessions/observe`, `POST /api/sessions/{id}/frames`, and
`POST /api/sessions/{id}/stop` record read-only observation session evidence
under `runs/observations/` and `runs/telemetry/`.
`POST /api/moontown/tasks/observe-run` composes those routes into one desktop
host contract for scheduled observation runs.
`GET /api/replays/{session_id}` reads that session plus its sorted
`runs/telemetry/{session_id}/` frames and returns the timeline used by Rabbita
and town surfaces.
`GET /api/datasets/episodes/{session_id}` reads the same session, telemetry
frames, and matching process review to emit a replayable dataset episode.
`GET /api/datasets/episodes/{session_id}/quality` evaluates that episode for
minimum replayability and review acceptance.
`POST /api/policies/evaluate` is the offline policy gate. It is deliberately
separate from `/api/intents/execute`, so policy output can be reviewed,
simulated, and recorded without moving hardware.
`GET /api/moonstat/status` includes the latest policy gate and ledger path for
the Rabbita cockpit and suite status surfaces.

## Verification

The native test suite includes a browser-burst smoke test that starts the host
and requests the Rabbita root, readiness route, API health route, and cockpit
snapshot route at the same time.

`src/desktop_bundle` now writes the Lepus project descriptor, host manifest, and
combined bundle manifest with bridge sidecar metadata. The next packaging step
is to point `sidecar-path` at the built native desktop host produced by release
packaging and then supervise the bridge sidecar described by the manifest.
