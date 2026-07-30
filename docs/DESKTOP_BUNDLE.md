# MoonRobo Desktop Bundle

`src/desktop_bundle` turns the native host, Rabbita cockpit, RoboBook root,
MoonData-aware runtime projections, Lepusa project descriptor, and physical
runtime supervisor into one launchable bundle plan.

It writes four JSON descriptors, three runner artifacts, and packaged UI and
RoboBook seed directories:

- `lepusa.json`: the current Lepusa project descriptor consumed by native
  verification, bundling, and release tooling
- `lepus.project.json`: the legacy Lepus window descriptor whose localhost
  command is `sh moonrobo.desktop-launch.sh`
- `moonrobo.desktop-host.json`: the host route and readiness manifest
- `moonrobo.desktop-bundle.json`: the combined bundle manifest and validation
  checks
- `moonrobo.release-build.sh`: the generated script that builds the native
  MoonBit command packages, builds the Rabbita cockpit, and copies release
  artifacts into bundle-local paths
- `moonrobo.desktop-launch.sh`: the Lepusa-facing script that starts the
  physical runtime supervisor in the background, starts the desktop host, waits
  for the desktop host, and cleans up both processes
- `moonrobo.runtime-supervisor.sh`: the generated POSIX runner that starts the
  SDK snapshot collector, waits for its snapshot file, starts the SDK bridge
  sidecar, probes bridge health, and stops both processes in reverse order
- `ui/`: the packaged Rabbita cockpit assets served by the bundle-local
  desktop host
- `robobook-seed/`: the tracked Noetix E1 product seed copied into Lepusa's
  writable application-data directory on first launch

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
- a tracked-only `robobook-seed/` without local runtime evidence or ignored CAD
  packs

## Lepusa release

With a Lepusa checkout available, validate and materialize the native package:

```text
moon -C /path/to/lepusa run cmd/main --target native -- verify macos --strict --project /absolute/path/to/_build/moonrobo-desktop/lepusa.json
moon -C /path/to/lepusa run cmd/main --target native -- build macos /absolute/path/to/_build/moonrobo-lepusa --project /absolute/path/to/_build/moonrobo-desktop/lepusa.json
```

The packaged launcher copies `robobook-seed/` into
`LEPUSA_APP_DATA_DIR/robobook` on first launch, serves the cockpit from
`LEPUSA_RESOURCE_DIR/ui`, and starts in safe cockpit-only mode when the external
Noetix SDK is not installed beside the writable RoboBook root. The public
preview uses macOS ad-hoc signing (`identity: "-"`); replace it with a Developer
ID identity and notarization profile for a trusted distribution build.

## Checks

The bundle manifest reports whether the first desktop product slice is ready:

- RoboBook loads and has required files
- bundle-local Rabbita cockpit has an `ui/index.html`
- bundle-local desktop host binary path exists
- bridge sidecar manifest and launchability status are embedded from the
  selected RoboBook
- physical runtime process graph is embedded for the SDK collector,
  high-control writer, and bridge sidecar, including the shared snapshot file,
  command outbox file, and dependency order
- release artifact build commands and bundle-local binary/UI paths are embedded
- runtime supervisor plan and `sh moonrobo.runtime-supervisor.sh` command are
  embedded so Lepusa packaging can launch the physical runtime consistently
- desktop host command and runtime supervisor share the configured bridge host
  and port
- `moonrobo-desktop-launch` is embedded as the Lepusa localhost command, so the
  packaged desktop entrypoint starts the host and starts the physical runtime
  supervisor only when the external SDK is available

The desktop host and UI checks are intentionally strict for packaged operation:
after the release script runs, the host serves `bundle-root/ui` and launch
scripts call `bundle-root/bin` commands. The robot bridge sidecar is a separate
manifest entry with its own command, protocol routes, environment, supervision
policy, and physical runtime process graph. The supervisor runner is generated
from that same graph and points at the bundle-local SDK bridge binary.

## Boundary

The bundle package does not talk to hardware. It is the declarative packaging
boundary between MoonBit runtime contracts, Rabbita build output, and Lepusa
desktop launch metadata, plus generated process runners that a packaged desktop
shell can execute with `sh`.
