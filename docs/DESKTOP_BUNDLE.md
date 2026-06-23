# Moonrobo Desktop Bundle

`src/desktop_bundle` turns the native host, Rabbita cockpit, RoboBook root, and
Lepus project descriptor into one launchable bundle plan.

It writes three JSON descriptors:

- `lepus.project.json`: the Lepus window and localhost sidecar descriptor
- `moonrobo.desktop-host.json`: the host route and readiness manifest
- `moonrobo.desktop-bundle.json`: the combined bundle manifest and validation
  checks

## Command

```text
moon run cmd/main --target native -- desktop-bundle [robobook-root] [ui-root] [host] [port] [sidecar-path] [bundle-root]
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

The command creates `bundle-root` when it is missing, writes the descriptor
files, and prints the manifest.

## Checks

The bundle manifest reports whether the first desktop product slice is ready:

- RoboBook loads and has required files
- Rabbita UI root has an `index.html`
- sidecar path exists
- bridge sidecar manifest and launchability status are embedded from the
  selected RoboBook

The desktop sidecar check is intentionally strict for packaged operation.
During local development, pass the path to the built native desktop host you
want Lepus to launch. The robot bridge sidecar is a separate manifest entry with
its own command, protocol routes, environment, and supervision policy.

## Boundary

The bundle package does not compile Rabbita assets, build native binaries, or
talk to hardware. It is the declarative packaging boundary between MoonBit
runtime contracts and Lepus desktop launch metadata.
