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
