# Hosted MoonRobo image

This profile packages the CPU-only MoonRobo cockpit for an account-bound
LunaNexa WebIDE. It does not include a physical robot bridge, SDK, model, or
cluster configuration.

1. In `ui/rabbita-cockpit`, run `MOONROBO_PUBLIC_BASE=/moonrobo/ npm ci &&
   MOONROBO_PUBLIC_BASE=/moonrobo/ npm run build`.
2. From the repository root, build `docker build -f deploy/Containerfile.hosted
   -t registry.example/moonrobo-hosted:VERSION .` and publish to your approved
   registry. Pin the resulting digest in LunaNexa's per-client runtime profile.
3. Configure the LunaNexa gateway for client ID `moonrobo`, base path
   `/moonrobo`, and this image. Keep the gateway on a workspace-host node and
   expose only the account-bound gateway, never the private cockpit Pod.
4. Redeem a portal handoff and verify `/moonrobo/`, the health endpoint,
   per-user RoboBook persistence, and blocked physical execution routes.

The build context excludes `target/`, local state, deployment manifests and
credentials. Do not copy live cluster overlays into this repository or image.
