# Hosted MoonRobo

Build the Linux native `cmd/main` executable and its matching Rabbita cockpit.
Build the browser with `MOONROBO_PUBLIC_BASE=/moonrobo/` when the authenticated
gateway publishes that path. Package both outputs in one immutable image.
The image contains no application credentials or physical bridge.

1. In `ui/rabbita-cockpit`, run `npm ci`, then
   `MOONROBO_PUBLIC_BASE=/moonrobo/ npm run build`.
2. From the repository root, build `docker build -f deploy/Containerfile.hosted
   -t registry.example/moonrobo-hosted:VERSION .` and publish to your approved
   registry. Pin the resulting digest in LunaNexa's per-client runtime profile.
3. Configure the LunaNexa gateway for client ID `moonrobo`, base path
   `/moonrobo`, and this image. Keep the gateway on a workspace-host node and
   expose only the account-bound gateway, never the private cockpit Pod.
4. Redeem a portal handoff and verify `/moonrobo/`, the health endpoint,
   per-user RoboBook persistence, and blocked physical execution routes.

## Digital robot model

The local Noetix asset pack is excluded from Git. Supply its reviewed
`examples/noetix-e1/e1_asm_251028/urdf` and `meshes` directories when building
`Containerfile.hosted`. They are installed next to the UI under
`/opt/moonrobo/models/e1_asm_251028`.

At startup, a Noetix RoboBook without that model gets a complete staged copy.
The directory is published with a portable POSIX rename, including on NFS.
An existing model directory is preserved; links and special files are refused.
The original `robot.json`, user files, accepted evidence and safety policy are
not rewritten. Displaying the model does not grant physical execution rights.

Verify the live cockpit snapshot resolves all 25 meshes with none missing,
fetch an actual mesh through the authenticated application path, and inspect
the rendered robot. Viewport diagnostics about telemetry or joint mapping
remain visible independently of mesh availability.

When upgrading, change the gateway's pinned launch profile and the existing
workspace deployment together, then restart the gateway and perform a fresh
portal handoff. Preserve the workspace volume and retain the previous digest
for rollback. A successful native build does not prove the deployed image is
current, and a ready Pod does not prove the browser robot renders.

The build context excludes `target/`, local state, deployment manifests and
credentials. Only the reviewed model directories are admitted from the local
asset pack. Do not copy live cluster overlays into this repository or image.
