# Moonrobo Desktop Host

`src/desktop_host` is the native boundary between the Rabbita cockpit and the
Lepus desktop shell. It keeps the desktop surface thin:

- static Rabbita assets are served from one UI root
- `/__moonrobo_health` reports host readiness
- `/api/health`, `/api/cockpit/snapshot`, `/api/moontown/resident`,
  `/api/moontown/tasks/*`, `/api/bridge/sidecar`,
  `/api/runtime/supervisor`, `/api/sessions/*`, `/api/replays/*`,
  `/api/datasets/episodes/*`, `/api/policies/*`, `/api/moonbook/*`,
  `/api/agent/*`, `/api/tools/*`, and
  `/api/intents/*`
  delegate to `src/host_api`
- project metadata is emitted as Lepus JSON

## Commands

```text
moon run cmd/main --target native -- serve [robobook-root] [ui-root] [host] [port]
moon run cmd/main --target native -- host-manifest [robobook-root] [ui-root] [host] [port]
moon run cmd/main --target native -- desktop-project [robobook-root] [ui-root] [host] [port] [sidecar-path]
moon run cmd/main --target native -- desktop-bundle [robobook-root] [ui-root] [host] [port] [sidecar-path] [bundle-root]
moon run cmd/main --target native -- bridge-sidecar [robobook-root]
moon run cmd/main --target native -- runtime-supervisor [robobook-root]
moon run cmd/main --target native -- runtime-supervisor-script [robobook-root]
```

Defaults:

```text
robobook-root: examples/noetix-e1
ui-root: ui/rabbita-cockpit
host: 127.0.0.1
port: 5290
sidecar-path: moonrobo-sidecar
bundle-root: _build/moonrobo-desktop
```

## Boundary

The desktop host does not parse RoboBooks, evaluate safety, or talk directly to
hardware SDKs. It serves local HTTP and Lepus metadata only. Robot logic stays in
`src/core`, `src/runtime`, `src/pipeline`, `src/host_api`, and bridge packages.
`/api/bridge/sidecar` exposes the bridge process manifest owned by
`src/bridge_sidecar`: command, protocol version, health route, telemetry route,
execution route, environment, supervision policy, launchability status, and the
physical runtime process graph for the SDK collector plus bridge sidecar.
`/api/runtime/supervisor` converts that graph into the concrete lifecycle plan:
manifest validation, collector start, snapshot wait, bridge start, health probe,
and reverse stop order.
`/api/runtime/supervisor/script` returns the executable POSIX runner for the
same plan as `text/plain`.
`/api/moontown/resident` exposes the selected RoboBook as a read-only resident
robot projection for town surfaces.
`/api/moontown/tasks/observe` lets a town standing goal request a read-only
observation task without taking over bridge control.
`/api/moontown/tasks/message` lets Rabbita or Moontown submit a user message as
a bounded task intent. It accepts observation-oriented messages, rejects
physical action wording, starts the read-only observation session, and persists
MoonBook memory for the changed robot agenda.
`/api/moontown/tasks/observe-run` runs the bounded observation pipeline and
returns persisted evidence, replay, and resident state.
`/api/sessions/{session_id}/frames` appends typed telemetry frames to active
observation sessions.
`/api/replays/{session_id}` exposes a compact replay timeline for the persisted
observation telemetry artifacts.
`/api/replays/{session_id}/annotations` records and lists replay curation
labels; `/api/replays/{session_id}/annotations/{annotation_id}` reads one label.
`/api/datasets/episodes/{session_id}` exports that replay and review evidence
as a dataset episode for offline quality and learning workflows.
`/api/datasets/episodes/{session_id}/quality` reports blockers and warnings for
that episode before it is used in downstream dataset or policy workflows,
including missing curation annotations.
`POST /api/policies/evaluate` converts a learned-policy proposal into a
command intent, evaluates the safety result, writes the run receipt plus
`runs/policy-evals/{evaluation_id}.json`, and keeps
`physical_execution_allowed` false.
`GET /api/policies/evaluations` and
`GET /api/policies/evaluations/{evaluation_id}` expose that ledger for
read-only audit.
`GET /api/moonbook/memory` projects the current robot memory pack; `POST
/api/moonbook/remember` persists it under `moonbook/memory/` so MoonBook can
recall what the robot observed and what remains next. RoboBook supplies the
robot decorator and evidence projection over that MoonBook substrate.
`GET /api/agent/work-queue` projects resident, review, replay annotation,
dataset quality, and policy ledgers into the next prioritized work items for
Rabbita and Moontown surfaces.
`GET /api/agent/next-action` adds the route/method/body contract and optional
safe request body template for the top work item while keeping physical
execution disallowed.
`POST /api/agent/dispatch-next` submits the selected safe evidence action from
that contract. It only dispatches allowlisted non-physical POST routes and
returns both the request body and downstream response for audit.
`GET /api/tools/registry` persists and returns the bounded provider registry
under `agents/tool-registry.json`. `POST /api/tools/register` replaces or
appends one provider entry and rejects any provider that attempts to grant
physical execution authority.

Rabbita or Moontown can expose this as a user message surface without becoming a
separate chat platform. The message is converted to a task intent by
`/api/moontown/tasks/message`, remembered in MoonBook after accepted
observation, and only allowlisted evidence actions can be dispatched from the
desktop host.

The current server handles accepted TCP connections concurrently and closes each
connection after one HTTP response. This keeps the first desktop sidecar simple
while supporting browser burst loads for the Rabbita shell and API routes.

`POST /api/intents/evaluate` accepts one command-intent submission, evaluates it
through the safety pipeline, writes a RoboBook receipt, and returns the pipeline
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
`POST /api/replays/{session_id}/annotations` writes
`runs/annotations/{session_id}/{annotation_id}.json` after confirming the
session exists. The matching `GET` routes expose those labels for dataset
curation.
`GET /api/datasets/episodes/{session_id}` reads the same session, telemetry
frames, and matching process review to emit a replayable dataset episode.
`GET /api/datasets/episodes/{session_id}/quality` evaluates that episode for
minimum replayability, review acceptance, and replay curation.
`POST /api/policies/evaluate` is the offline policy gate. It is deliberately
separate from `/api/intents/execute`, so policy output can be reviewed,
simulated, and recorded without moving hardware.
`GET /api/moonstat/status` includes the latest policy gate and ledger path for
the Rabbita cockpit and suite status surfaces.
`GET /api/moonbook/memory` and `POST /api/moonbook/remember` bridge RoboBook
evidence into MoonBook memory cards for resident state, latest evidence, and
next work.
`GET /api/agent/work-queue` is the desktop task rail contract: it identifies
whether the next operator or agent action is bridge connection, evidence review,
replay annotation, dataset repair, policy dry-run, policy approval, or offline
policy evaluation.
`GET /api/agent/next-action` is the action-plan contract consumed by the
Rabbita task rail. It carries a safe draft request body for mutating evidence
routes, remains read-only planning metadata, and never starts bridge processes
or moves hardware.
`POST /api/agent/dispatch-next` is the matching evidence dispatcher. It can
write replay annotations, run bounded observation evidence collection, or record
offline policy evaluation only when the selected queue action has a safe body
template and `physical_execution_allowed` remains false.

## Verification

The native test suite includes a browser-burst smoke test that starts the host
and requests the Rabbita root, readiness route, API health route, and cockpit
snapshot route at the same time.

`src/desktop_bundle` now writes the Lepus project descriptor, host manifest,
combined bundle manifest, `moonrobo.desktop-launch.sh`, and
`moonrobo.runtime-supervisor.sh`. The bundle-owned Lepus command is
`sh moonrobo.desktop-launch.sh`, which starts the physical runtime supervisor
and the desktop host together. The next packaging step is to point
`sidecar-path` and bridge commands at built release binaries.
