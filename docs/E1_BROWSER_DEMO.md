# E1 showcase

Open [E1](http://127.0.0.1:5300/e1.html) beside the existing
[G1 showcase](http://127.0.0.1:5300/g1.html). Both pages and the experiment book
link to E1. It is part of the existing Vite application, with the same fonts,
white studio presentation and project navigation. No separate hosting account
or external publication is required for this local research page.

The [read-only E1 mirror](http://127.0.0.1:5300/e1-live.html) shows measured
joint angles and IMU orientation alongside a 15-second left elbow reference.
Both models share a camera and use the actual angle scale. The preview holds
the initial pose of the other 22 actor joints. The left elbow folds by 90°
over 7.5 seconds and unfolds over the next 7.5 seconds. Select **查看峰值**
to inspect the maximum fold. The two reference endpoints match.
Both roots are anchored for display because this feed supplies no world position.

The local Vite server reads the latest pose from `MOONROBO_E1_LIVE_FILE`.
The read-only relay replaces this private file on receipt of a new source
sample. It contains `source_ns` as a decimal string, 23 joint `names`,
measured and starting positions in radians (`q`, `baseline`), and XYZW
quaternions (`ori`, `baseline_ori`). The mirror hides the measured model when
the feed expires. The reference can be scrubbed offline from the default pose.
When the private feed directory also holds a matching `shadow-poses.json`,
select **影子输出（已记录）** to compare the actor's nominal joint positions
with the elbow reading captured at that step. The left model continues to
show the current robot. The pose comparison anchors the shadow root at the
initial measured orientation.

[Compare the 40 shared holdouts](http://127.0.0.1:5300/compare.html?motion=M_Move3) opens both 14k MuJoCo rollouts on one 50 Hz clock. Select a dance or karate recording, scrub the timeline, or click a robot’s stop time to inspect its final pose. The shared panel uses Experiential Technologies’ G1 Moves recordings.

## Physical camera access audit — 2026-11-23

Camera integration is **blocked on a supported, accessible E1 image source**.
The live page currently displays joint/IMU telemetry, not camera images. On this
date the local `/__e1_pose` endpoint still returned fresh data for 23 joints.

- The public [E1 SDK](https://github.com/Noetix-Robotics/noetix_sdk_e1/tree/3055bdc644f61caf948d935ee274c5c48703c24f)
  was checked at commit `3055bdc644f61caf948d935ee274c5c48703c24f`, version
  `3.1.0`. Its complete tree, high/low controller headers, common data types and
  high-controller Python bindings expose no camera subscriber, image type or
  media controller. The repository had one public branch and no GitHub releases.
- The [Chinese E1 guide](https://web.noetixrobotics.com/docs/通用人形机器人/E1%20综合使用文档/)
  and [English E1 guide](https://web.noetixrobotics.com/docs/en/通用人形机器人/E1%20综合使用文档/)
  do not document a network image endpoint. The English specification table
  distinguishes standard E1's `DC_V93` from Education E1's `RealSense D435I`.
  The camera installed in this particular robot has not been identified; do
  not assume D435i from the generic camera-information link.
- [NOETIX Run's official release history](https://apps.apple.com/cn/app/noetix-run/id6751874215)
  lists E1 compatibility in 2.0.6, video transmission in 2.0.0, and dual-board
  video compatibility in 3.1.0. These establish an app route to investigate,
  not a public E1 stream URL or proof that this unit supplies video. App pairing
  and live video on this unit remain unverified.
- The camera methods in the public
  [Bumi MediaController](https://github.com/Noetix-Robotics/noetix_sdk_bumi/blob/95b264598ed671a76f7959a69c21b1b99f40c0b2/include/MediaController.h)
  include `subscribe_internal_video_capture` and
  `subscribe_internal_video_desensed`. These are **Bumi interfaces**; no
  E1-compatibility claim was found. They were not run against E1. Some Bumi
  documentation uses the older name `get_video_capture_data`; do not invent
  that method in the E1 adapter.

The user has ruled out logging into the motion-control board at
`192.168.55.102`. This audit did not connect to that board or change any robot
service. Earlier external checks found no camera on Atlas and no image publisher
in a bounded domain-0 DDS discovery; those checks do not establish absence of
an internal camera or a feed on another transport/domain. Atlas currently uses
`192.168.55.101`, so that address cannot be assumed to identify a separate Jetson.

To complete integration, obtain either a vendor-confirmed E1 video subscription
API/stream for this firmware, or an identified camera device on an accessible
development computer. A paired NOETIX Run video check can confirm that the
robot's camera works, but does not by itself provide a browser-embeddable feed.
No placeholder image, Bumi protocol experiment or controller login substitutes
for receiving and verifying real E1 frames.

## What it shows

- The actual E1 MJCF hierarchy, joint axes and visual meshes.
- The [retrained 14k right stoop](http://127.0.0.1:5300/e1.html?motion=retrained-14000-10#motion-lab) opens by default. Both retrained actors have recorded MuJoCo trajectories for all 40 held-out motions, including early terminations. Switching between the 7k and 14k checkpoints keeps the selected motion. Both completed 36/40, with mean returns of 0.7155 and 0.7585 respectively. Both scored 0/40 on strict tracking. The evaluation section includes the per-motion reports and downloadable actor archives with their inference metadata.
- The picker also includes the previous actor’s four calibrated and three original rollouts and the four vendor reference clips. Earlier motion URLs still select the corresponding recordings. [Original retargeting measurements](E1_RETARGETING.md)
- The current training iteration, phase, most recent checkpoint and a loss
  chart for the latest 300 logged iterations. The local bridge refreshes at
  most every 30 seconds. Its timestamp is always displayed in Asia/Shanghai.
- The final 14,000-iteration training record. The retrain used 66 training and 9 validation motions. All 40 external benchmark sessions were held out.

The model has 23 active joints, matching the current simulation experiment.
It fixes waist roll in the vendor's 24-axis scene; this is not measured
hardware calibration. The viewer performs kinematics, with no robot SDK,
motor commands or learned-policy inference.

To regenerate the three original 7k replay assets from their paired evaluation, run
`moon run scripts/prepare_e1_panel_replays.mbtx PANEL_DIR ACTOR_DIR ui/rabbita-cockpit/public/e1/assets`.
Append `anatomical` and use the corrected full-panel and trace directories
to regenerate the four calibrated replays. The exporter checks the actor and
reference digests, joint order, executed duration, terminal flag, reward sum
and frame-to-frame state continuity before packing the robot poses.

For the retrain, run the same exporter on Spark with `RUN_DIR RUN_DIR/train/evaluation-N/actor SHOWCASE_ASSETS retrained-N` (N = 7000 or 14000). It reads the original measurements from `RUN_DIR/panel` and all 40 paired traces from `RUN_DIR/site-panel40`. It checks the source checkpoint digest and recorded iteration before writing the poses. The browser downloads poses as needed. The two optional actor packages contain `actor.pt` and `actor.json`.

## Data preparation on Spark 178

`scripts/prepare_e1_showcase.mbtx` verifies the exact dataset manifest, scene,
mesh and reference hashes used by the running experiment. Run with the Spark
toolchain, using a fresh output:

```sh
moon run prepare_e1_showcase.mbtx /home/wlc003s/moonrobo/private/e1-native-20261110/data-23 /home/wlc003s/moonrobo/private/e1-native-20261110/showcase-v1
```

The export reduces the 105 MiB STL source using 2 mm vertex clustering, removes
collapsed/duplicate triangles and packs indexed mesh buffers. This approximation
affects display only. It does not modify simulation or training assets. The
four references are packed as Float32 root XYZ, quaternion XYZW, and the 23
named joint angles at 50 Hz. The output is about 9.4 MiB, including all four
motions, and lives in `ui/rabbita-cockpit/public/e1/assets/`. It retains the
Noetix BSD license and source/export digests. The browser verifies every loaded
scene, mesh and motion before using it.

## Read-only training status

Install `scripts/e1_showcase_status.mbtx` in the existing 179 job root. The
script checks the hostname, reads only the named training container's state,
bounded log tail and checkpoint pointer, and emits a compact JSON result. It
does not modify the job or load a network on the GPU.

The local Vite server enables the bridge only with explicit configuration:

```text
MOONROBO_E1_SSH_HOST=wlc004s@192.168.2.179
MOONROBO_E1_SSH_SOCKET=/tmp/moonrobo-e1-179.sock
```

These can be supplied as environment variables or in the ignored
`ui/rabbita-cockpit/.env.local`. They name an existing authenticated SSH master;
no password or private key is stored in the application. Bind local previews
to `127.0.0.1`, as the existing dev command does. The bridge coalesces concurrent
requests, caches successful observations for 30 seconds and bounds SSH runtime
and output. It never enters the browser bundle.

If the bridge is unavailable, the browser clearly labels the last observation
as a snapshot with its timestamp; it does not advance progress or fabricate
losses. Static production hosting uses the dated `public/e1/training.json`
snapshot. A fresh snapshot can be obtained by capturing the status script's
stdout from 179; keep compiler diagnostics on stderr.

Rate calculation uses separated Docker timestamp groups, since stdout can be
buffered. It excludes the world-only warm-up when estimating actor/critic-phase
throughput. This is a measured recent rate, not a guaranteed finish time.

## Checks

```sh
cd ui/rabbita-cockpit
node --test e1/status.test.mjs e1/viewer.test.mjs
node node_modules/vite/bin/vite.js build --outDir dist-e1-review
```

The tests check status validation, buffered-log timing, chart aggregation,
binary mesh decoding, every shipped asset's SHA256/layout and motion quaternion
norms. Browser review covers the desktop and 375 px layouts, motion controls,
view selection and status updates. The E1 page builds into `e1.html` beside the
existing pages. Production builds include the two downloadable E1 inference archives. The training checkpoints and optimizer state stay on Spark.
