# Moonrobo Desktop Host

`src/desktop_host` is the native boundary between the Rabbita cockpit and the
Lepus desktop shell. It keeps the desktop surface thin:

- static Rabbita assets are served from one UI root
- `/__moonrobo_health` reports host readiness
- `/api/health` and `/api/cockpit/snapshot` delegate to `src/host_api`
- project metadata is emitted as Lepus JSON

## Commands

```text
moon run cmd/main --target native -- serve [robotbook-root] [ui-root] [host] [port]
moon run cmd/main --target native -- host-manifest [robotbook-root] [ui-root] [host] [port]
moon run cmd/main --target native -- desktop-project [robotbook-root] [ui-root] [host] [port] [sidecar-path]
```

Defaults:

```text
robotbook-root: examples/noetix-e1
ui-root: ui/rabbita-cockpit
host: 127.0.0.1
port: 5290
sidecar-path: moonrobo-sidecar
```

## Boundary

The desktop host does not parse RobotBooks, evaluate safety, or talk directly to
hardware SDKs. It serves local HTTP and Lepus metadata only. Robot logic stays in
`src/core`, `src/runtime`, `src/pipeline`, `src/host_api`, and bridge packages.

The current server handles accepted TCP connections concurrently and closes each
connection after one HTTP response. This keeps the first desktop sidecar simple
while supporting browser burst loads for the Rabbita shell and API routes.

## Verification

The native test suite includes a browser-burst smoke test that starts the host
and requests the Rabbita root, readiness route, API health route, and cockpit
snapshot route at the same time.

The next packaging step is to produce a packaged Rabbita asset directory, build
the native sidecar, and let Lepus launch the sidecar command emitted by
`desktop-project`.
