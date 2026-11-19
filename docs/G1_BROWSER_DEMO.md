# MoonRobo G1 browser lab

Open [the local lab](http://127.0.0.1:5300/g1.html), or select **G1 · 14,000 轮实测** on the cockpit results page. The page includes the native APIC panel, browser-physics cross-check, three recorded browser rollouts, and an interactive reference, simulator and learned prediction. The recordings use the same browser runtime as the live lab.

[Compare the 40 shared holdouts](http://127.0.0.1:5300/compare.html?motion=M_Move3) opens both 14k MuJoCo rollouts on one 50 Hz clock. Select a dance or karate recording, scrub the timeline, or click a robot’s stop time to inspect its final pose. The shared panel uses Experiential Technologies’ G1 Moves recordings.

## Run locally

From the repository root:

```sh
export MOONROBO_G1_DEMO_ROOT="$PWD/target/supermimic-showcase"
npm --prefix ui/rabbita-cockpit run dev -- --port 5300 --strictPort
```

For the production bundle use `npm --prefix ui/rabbita-cockpit run build` followed by `npm --prefix ui/rabbita-cockpit run preview -- --port 5300 --strictPort` with the same environment variable. The ordinary static build contains the evaluation summaries and recorded footage. The local Vite server supplies the live model and references from the specified directory to loopback clients. The page uses an independently written WebAssembly SIMD inference kernel, the upstream MuJoCo 3.15.0 WASM package and Three.js. The [research site](https://supermimic.github.io/) and [its web-demo license](https://supermimic.github.io/demo/LICENSE.html) are external references.

## Recreate the private bundle

Use the native iteration-14,000 generation's original `policy.pt`, `world.pt`, `state.json`, `receipt.json`, and `catalog.json` in `$MOONROBO_G1_DEMO_ROOT/source/`. Put the iteration-4 policy, state and receipt in `source/early/`. Copy the complete original self-collision scene directory to `source/g1/` (including the meshes and compilation record). Create `private/` in the bundle root.

With `CACHE` pointing to the authorized training reference cache and `LIB` to a LibTorch adapter with native linear, LayerNorm and BF16 support:

```sh
moon run scripts/prepare_g1_demo_refs.mbtx -- "$MOONROBO_G1_DEMO_ROOT" "$CACHE" ui/rabbita-cockpit/public/g1/panel.json
KEY=$(jq -r '.[0].key' "$MOONROBO_G1_DEMO_ROOT/source/panel-sources.json")
SHARD="$MOONROBO_G1_DEMO_ROOT/source/clips/${KEY:0:2}/$KEY.f64"
moon run --target native cmd/g1_browser_export -- "$LIB" "$MOONROBO_G1_DEMO_ROOT/source" "$MOONROBO_G1_DEMO_ROOT/private/final" "$SHARD" actor-world
moon run --target native cmd/g1_browser_export -- "$LIB" "$MOONROBO_G1_DEMO_ROOT/source/early" "$MOONROBO_G1_DEMO_ROOT/private/early" "$SHARD" actor
```

Use fresh export directories. On the current Mac the adapter is `target/learning-tensor/libmoonrobo_geometry_cost_cpu.dylib` and its LibTorch dependencies are in `target/learning-venv/lib/python3.12/site-packages/torch/lib` (set `DYLD_LIBRARY_PATH`). The exporter loads named native model parameters and saved normalizers, checks archive hashes against their generation receipt, and generates native forward-pass fixtures alongside the packed weights. The reference preparer verifies the source catalog, ordering, decoded motion lengths and per-shard hashes. The HTTP allowlist exposes the packed floats and reference shards required by the demo. Training archives and optimizer state stay outside that allowlist.

To add the curated showcase, point `BONES_CACHE` and `LAFAN_CACHE` at the two locally accessible native reference caches (120 Hz and 30 Hz source data, respectively). Both contain shards already resampled for the 50 Hz controller:

```sh
moon run scripts/prepare_g1_showcase_refs.mbtx -- "$MOONROBO_G1_DEMO_ROOT" "$BONES_CACHE" "$LAFAN_CACHE" output/data/g1-lafan1/manifest.json ui/rabbita-cockpit/g1/showcase-motions.json
```

The preparer checks the pinned catalogs, clip identities and resampled bytes before publishing `source/showcase-clips/`. Without this optional pack the original 40 evaluation motions still work. Clips are loaded on selection; the browser keeps at most two cached references with a 24-frame decoded window each.

## What matched in this run

The policy takes ten oldest-first observations of 99 values and ten 73-value reference frames, then emits 29 raw G1 actions. The browser uses the actual evaluation path's joint velocities and body gyro, saved running normalizers, corrected reference heading and per-joint scales. The MuJoCo model resolves joint, actuator and velocity addresses by name. Both paths use four 5 ms physics substeps per control step. Prediction uses the final learned dynamics in both policy modes and resynchronizes with physics every 32 control steps. The push acts on the simulated pelvis. A disabled policy produces zero raw action, which puts the position servos at their default targets.

```sh
node ui/rabbita-cockpit/g1/verify.mjs "$MOONROBO_G1_DEMO_ROOT"
node ui/rabbita-cockpit/g1/panel-check.mjs "$MOONROBO_G1_DEMO_ROOT"
```

The first check compares the browser SIMD kernel with native MoonBit/LibTorch on four real-motion inputs per checkpoint, including a clip-end preview. The final actor agreed on all 116 scalar action outputs tested. The maximum absolute difference across the 70 world-model output channels was 0.00691. The second check runs the same browser WASM physics and policy modules under Node on all 40 panel clips, with friction 1, zero action noise and no pushes. Chrome independently exercised the interactive simulation and controls.

| Policy | Browser MuJoCo completed | Native APIC completed | Same termination outcome |
| --- | ---: | ---: | ---: |
| Iteration 4 | 1/40 | 1/40 | 40/40 |
| Iteration 14,000 | 37/40 | 38/40 | 39/40 |

The extra browser termination occurred at frame 254/387 in wave-and-jog (catalog index 123,207). The other two failures were shared, with different termination frames. Measured native returns are kept with the APIC results. No physical G1 or E1 trial was performed. The project's E1 integration targets 24 motors and its example disables low-level joint-position control.

The existing local MoonData experiment book listed 48 records when audited. Its legacy aligned importer dispatches on `moonrobo.supermimic-aligned-training.v1` and expects a single checkpoint and legacy export evidence. The final trainer emits `moonrobo.native-tensor-training-report.v1` with a stream-v2 generation. A scratch import of the native reports failed. The new cockpit entry reads the explicitly paired panel and pinned weights independently of the registry. [Native report](../output/bones-bf16-production-20261109/long-final-report.json) · [Native vs. WASM pass/fail](../output/bones-bf16-production-20261109/browser-native-panel.json) · [Numerical fixtures result](../output/bones-bf16-production-20261109/browser-forward-parity.jsonl)

## Presentation and model footage

The [showcase](http://127.0.0.1:5300/g1.html) opens with a recorded high jump. [Open the live frog jump](http://127.0.0.1:5300/g1.html?view=demo&motion=106023) to run the iteration-14,000 networks. The embedded lab starts on demand. The world-model prediction appears solid when viewed alone. Switching on **MuJoCo** draws the simulated body solid and the prediction in translucent blue. **Goal** adds the reference pose in translucent gray. [Open the three-layer flip](http://127.0.0.1:5300/g1.html?view=demo&motion=88725&overlay=mujoco,goal). Settings can separate the three trajectories. The follow camera supports orbit and zoom. Dragging the robot applies a push.

The selector in the bottom dock supports filtering, expanding folders, selecting a take and shuffling a folder. The first six folders supply the 36 named choices in the [SuperMimic demo](https://supermimic.github.io/demo/): 7 acrobatics, 5 contact-rich, 5 manipulation, 6 locomotion, 9 dance and 4 LAFAN1. The 32 BONES-SEED motions are our own catalog takes from the named families, not a claim of identical take, crop or rollout. The four retargeted LAFAN1 references have source hashes outside the production catalog; that does not establish unseen behaviors. A separate folder keeps the 40 evaluation clips. The **Experiments** folder runs one of six conditions on the current motion: normal tracking, policy off, slippery floor, noisy actions, pelvis push or early policy. These are interventions or checkpoint choices, not additional motions or additional evaluation results.

The [live comparison gallery](../output/g1-live-comparison-20261110/index.html) pairs genuine running sessions. The [browser smoke check](../output/g1-live-comparison-20261110/live-check.json) advances all 76 references with this model and asserts the experiment settings. It checks playback and controls; the full-motion completion figures above still refer only to the fixed panel of 40.

The white-background films come from the existing `Simulation` and `Viewer`, using the physics lane, zero noise, friction 1, no pushes, and 50 Hz control. The encoder samples every other physics-control frame at 25 fps, including the terminal frame. The following are browser MuJoCo results:

| Film | Policy iteration | Catalog index | Terminal control step |
| --- | ---: | ---: | ---: |
| High jump (hero) | 14,000 | 102085 | 155 / 155 |
| Hip-hop dance | 14,000 | 95045 | 177 / 177 |
| Sideways jog | 4 | 7040 | 41 / 167 |
| Sideways jog | 14,000 | 7040 | 167 / 167 |

The locally hosted Inter and Inter Tight fonts come from Google Fonts (OFL texts in `public/g1/licenses/`). The environment grid and compute illustration were drawn for this implementation. Third-party page screenshots are visual-review evidence only and are outside the web bundle. [Screenshot comparisons, desktop and mobile](../output/g1-visual-review-20261110/index.html).
