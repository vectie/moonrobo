# Moonrobo Desktop Bundle

`src/desktop_bundle` turns the native host, Rabbita cockpit, RoboBook root,
Lepus project descriptor, and physical runtime supervisor into one launchable
bundle plan.

It writes three JSON descriptors, three runner artifacts, and a packaged UI
asset directory:

- `lepus.project.json`: the Lepus window descriptor whose localhost command is
  `sh moonrobo.desktop-launch.sh`
- `moonrobo.desktop-host.json`: the host route and readiness manifest
- `moonrobo.desktop-bundle.json`: the combined bundle manifest and validation
  checks
- `moonrobo.release-build.sh`: the generated script that builds the native
  MoonBit command packages, builds the Rabbita cockpit, and copies release
  artifacts into bundle-local paths
- `moonrobo.desktop-launch.sh`: the Lepus-facing script that starts the
  physical runtime supervisor in the background, starts the desktop host, waits
  for the desktop host, and cleans up both processes
- `moonrobo.runtime-supervisor.sh`: the generated POSIX runner that starts the
  SDK snapshot collector, waits for its snapshot file, starts the SDK bridge
  sidecar, probes bridge health, and stops both processes in reverse order
- `ui/`: the packaged Rabbita cockpit assets served by the bundle-local
  desktop host

## Command

```text
moon run cmd/main --target native -- desktop-bundle [robobook-root] [ui-root] [host] [port] [sidecar-path] [bundle-root] [bridge-host] [bridge-port]
```

Defaults:

```text
robobook-root: examples/noetix-e1
ui-root: ui/rabbita-cockpit
host: 127.0.0.1
port: 5290
sidecar-path: moonrobo-sidecar
bundle-root: _build/moonrobo-desktop
bridge-host: 127.0.0.1
bridge-port: 5391
```

The command creates `bundle-root` when it is missing, writes the descriptors and
runners, and prints the manifest. Run `sh moonrobo.release-build.sh` from the
repository root before launching the bundle; it installs:

- `bin/moonrobo-desktop-host`
- `bin/moonrobo-sdk-e1-bridge`
- `ui/index.html` and static Rabbita assets

## Checks

The bundle manifest reports whether the first desktop product slice is ready:

- RoboBook loads and has required files
- bundle-local Rabbita cockpit has an `ui/index.html`
- bundle-local desktop host binary path exists
- bridge sidecar manifest and launchability status are embedded from the
  selected RoboBook
- physical runtime process graph is embedded for the SDK collector and bridge
  sidecar, including the shared snapshot file and dependency order
- release artifact build commands and bundle-local binary/UI paths are embedded
- runtime supervisor plan and `sh moonrobo.runtime-supervisor.sh` command are
  embedded so Lepus packaging can launch the physical runtime consistently
- desktop host command and runtime supervisor share the configured bridge host
  and port
- `sh moonrobo.desktop-launch.sh` is embedded as the Lepus localhost command,
  so the packaged desktop entrypoint starts both the physical runtime
  supervisor and the desktop host

The desktop host and UI checks are intentionally strict for packaged operation:
after the release script runs, the host serves `bundle-root/ui` and launch
scripts call `bundle-root/bin` commands. The robot bridge sidecar is a separate
manifest entry with its own command, protocol routes, environment, supervision
policy, and physical runtime process graph. The supervisor runner is generated
from that same graph and points at the bundle-local SDK bridge binary.

## Boundary

The bundle package does not talk to hardware. It is the declarative packaging
boundary between MoonBit runtime contracts, Rabbita build output, and Lepus
desktop launch metadata, plus generated process runners that a packaged desktop
shell can execute with `sh`.
