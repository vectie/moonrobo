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

## Cluster refresh, 2026-11-11

The current working-source cockpit and native CLI are deployed as
`moon/hosted-apps@sha256:c3127565be01639c16d8ab188c006950f80c0ba8d27adfa5d206fb439f1a71fd`.
Both the personal launch profile and shared `moonrobo-jiaan` use this image.
The shared deployment retains its existing state mount, while obsolete
binary/UI hostPath mounts have been removed. Read-only physical execution is
unchanged; all 25 model meshes resolved, and existing joint-map diagnostics
remain visible. No physical bridge, training job or GPU service was changed.
Preserve the base image's glibc/loader; copying older build-host platform
libraries can leave the native app healthy while breaking bundled tools.
Private state/build/rollback evidence is on management node .173 under
`/home/HwHiAiUser/moon-public/work/products-20261111-r1`. The complete suite
acceptance is recorded in MoonTown's `docs/project/CLUSTER_REFRESH_20261111.md`.

## Public G1 / E1 comparison

[Open the public comparison on M_Move3](https://suanli.kechuangfuwu.com:8443/robo/?motion=M_Move3).
This route serves the frozen 14k policies’ 40 paired MuJoCo recordings through
a dedicated static service on the management node. The comparison build takes
its public assets from the two mesh manifests and the paired recording manifest.
It supports direct links, e.g. `/robo/?motion=B_SpiralDance`.

Run `npm --prefix ui/rabbita-cockpit run build:compare` from the repository root.
The standalone site is written to `target/robo-public/site`. For a new release,
stage that directory on the management node in a fresh versioned release
directory and compare the transferred files’ SHA-256 digests with the build.
Set the site hostPath in `deploy/compare/workload.yaml` to that directory and
apply `kubectl apply -k deploy/compare` in the LunaNexa management context.
Release `f92474f04b6ad557` uses the first 16 hex digits of the SHA-256 of its
sorted `sha256sum` file inventory. Rollback uses the prior release directory
and deployment configuration.


The [workflow comparison](https://suanli.kechuangfuwu.com:8443/robo/workflow.html?motion=M_Move3)
uses the same picker and links back to the physical pose at the selected step.
Run the frozen `compare-panel` job with `--record-poses true --record-workflow true`
in a fresh output directory. Run
`moon run scripts/prepare_paired_workflow.mbtx --target native -- BENCHMARK RECORDED PLAYER_MANIFEST NEW_OUTPUT`.
It checks every physical pose stream and the complete per-clip evaluation against
the published baseline before exporting the transition metrics. Place the
verified export under `ui/rabbita-cockpit/public/heldout/workflow/` for the
comparison build. Run `node --test ui/rabbita-cockpit/heldout/playback.test.mjs`
to check that the two observed time windows and eight reward components sum to
the published scores for all 40 pairs.

The [body orientation study](https://suanli.kechuangfuwu.com:8443/robo/orientation.html?motion=M_Move3)
aligns the frozen G1 Moves source, E1 reference and both physical poses for each control frame.
Use the same dataset, scene, source directory and panel as the paired evaluation. Run
`orientation-panel` with `--recorded` pointing to the published physical recordings and
`--output` pointing to a fresh directory. It rebuilds the pinned references and reconciles
the two physical orientation rewards before writing four world wxyz streams per frame.
Frame zero is the reset. Within each frame the group order and 14 named bodies are in
`manifest.json`. The G1 streams use the E1 anatomical bind axes.

The three additional `compare-panel` runs use the original frozen executable with
pose/workflow recording enabled. Change only the E1 actor (7k or 14k) and
`--panel-bind` (anatomical or legacy-zero). Keep each full `rollouts` directory.
For `scripts/prepare_orientation_controls.mbtx`, supply the baseline rollout directory,
a parent holding the three rollout directories named `p7bind0`, `p7`, `bind0`,
the player manifest and a new `controls.json`. For independent fixed-source scoring,
run `orientation-controls` with `--training-dataset`, `--library`, `--geometry`
(the orientation export), `--recorded` (baseline), `--cases` (parent containing
each case's `rollouts/`), `--controls` and a fresh `--output` named `source-controls.json`.
This reads MuJoCo xmat from each recorded physical pose, verifies the current E1
pose against the parallel FK output, and scores all four against one source over
their common survival with G1. Place both control reports alongside the geometry
export in `ui/rabbita-cockpit/public/heldout/orientation/` before building.

The [E1 arm IK comparison](https://suanli.kechuangfuwu.com:8443/robo/arm-ik.html)
freezes the anatomical 14k E1 actor. In the same `compare-panel` command, set
`--record-poses true --record-workflow true --record-references true`, using a fresh
directory for each `--arm-orientation original|shoulders|elbows|both|arms-only`.
All angular residuals added here use the existing distal-arm weight of 0.12.
For the supplementary arms-only refinement, first generate the original screened
trajectory and then use only the arm columns of the IK Jacobian with the frozen
root, waist and legs. Re-run the ordinary reference screen on the refined rows.

Run `arm-ik-study` with `--training-dataset`, `--library`, `--cases` (parent of the
named runs), `--recorded` (frozen 14k baseline), `--geometry` (verified orientation
export), the pinned `--panel` and a fresh `--output`. This release has two native
builds. A second `original` run named `bridge` supplies the control for the
arms-only build. Its reference and rollout results must also reproduce the baseline.
Place the report at `ui/rabbita-cockpit/public/heldout/arm-ik/results.json` alongside the five named subdirectories containing their original `references.json` and `final.json` and run
`node --test ui/rabbita-cockpit/heldout/arm-ik.test.mjs` before the comparison build.

The [E1 fine-tuning comparison](https://suanli.kechuangfuwu.com:8443/robo/arm-ik.html#finetune)
uses the same guarded arm references for the frozen 14k and fine-tuned actors.
`prepare-arm-finetune` rebuilds the parent curriculum and verifies the hash of
each original cross-embodiment trajectory before refining the arms. The new
run warm-starts from the 14k checkpoint with `--initialize-from`. Its schedule
and 21 additional recordings are pinned in
[the experiment protocol](../output/e1-arm-finetune-20261115/protocol.json).
Evaluate both actors with their own training manifests. Use `heldout-panel`
on each source-rate group and `compare-panel --record-poses true` for the
candidate's 40-motion replay. `scripts/compare_e1_arm_finetune.mbtx` verifies
the paired reports and aggregates by motion. `policy-tracking-study` reads
both pose archives and the frozen guarded references to measure shoulders
and stance feet over each pair's common physical steps.
