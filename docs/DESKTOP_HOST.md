# Moonrobo Desktop Host

`src/desktop_host` is the native boundary between the Rabbita cockpit and the
Lepus desktop shell. It keeps the desktop surface thin:

- static Rabbita assets are served from one UI root
- `/__moonrobo_health` reports host readiness
- `/api/health`, `/api/cockpit/snapshot`, and `/api/intents/*` delegate to
  `src/host_api`
- project metadata is emitted as Lepus JSON

## Commands

```text
moon run cmd/main --target native -- serve [robotbook-root] [ui-root] [host] [port]
moon run cmd/main --target native -- host-manifest [robotbook-root] [ui-root] [host] [port]
moon run cmd/main --target native -- desktop-project [robotbook-root] [ui-root] [host] [port] [sidecar-path]
moon run cmd/main --target native -- desktop-bundle [robotbook-root] [ui-root] [host] [port] [sidecar-path] [bundle-root]
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

## Verification

The native test suite includes a browser-burst smoke test that starts the host
and requests the Rabbita root, readiness route, API health route, and cockpit
snapshot route at the same time.

`src/desktop_bundle` now writes the Lepus project descriptor, host manifest, and
combined bundle manifest. The next packaging step is to point `sidecar-path` at
the built native sidecar produced by release packaging.
