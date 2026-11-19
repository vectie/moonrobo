# G1 to E1 arm retargeting and frozen-policy evaluation

On November 11, 2026 we changed the arm calibration used to generate E1 references from BONES-SEED G1 motions. We reran the same 40 external motions in MuJoCo with the frozen E1 policies at 7,000 and 14,000 iterations. The 7k policy completed 35 motions on the corrected references. The [corrected stoop replay](http://127.0.0.1:5300/e1.html?motion=7k-stoop-calibrated#motion-lab) and [original stoop replay](http://127.0.0.1:5300/e1.html?motion=7k-stoop#motion-lab) use the same actor.

## What was wrong

The fitter used zero joint angles on both skeletons to compute segment offsets and body-frame orientation corrections. At zero, the G1 left forearm points forward and the E1 forearm hangs down. The angle between their marker directions is 91.98°. The resulting offset could turn a bent G1 arm into a nearly straight E1 arm even before the first controller action. On frame zero of the right stoop, the G1 right elbow bends 97.06°, the original E1 reference bends 3.86°, and the calibrated E1 reference bends 85.30°. These are angles between the upper-arm and forearm marker vectors. [Bind measurements](../output/e1-arm-transfer-20261111/bind-geometry.json) · [Frame measurements](../output/e1-arm-transfer-20261111/summary.json)

The corrected fitter evaluates its G1 bind pose with both elbows at +π/2. It looks up the hinge addresses from the left and right elbow bodies. This reduces the measured left forearm bind gap to 4.76°. The offset applies only when deriving the correspondence. Each source frame uses its recorded joint angles, and a vendor E1 source uses its own zero bind. Both fitting passes use the same correspondence. The upstream SuperMimic training entry point consumes supplied motion files or registry motions. The cross-robot calibration is part of MoonRobo's E1 data preparation. [Fitter](../src/learning_e1_training/trajectory_fit.mbt) · [Upstream training entry point at the reviewed revision](https://github.com/HybridRobotics/supermimic/blob/abc124c1bd5976341034668af3d12c087f2f1f55/src/supermimic/scripts/train.py#L61)

![Stoop at reset in the same camera view. The original E1 rollout is on the left and the corrected rollout is on the right.](../output/e1-retarget-fix-20261111/stoop-before-after.jpg)

Calibration alone caused a new failure on the horse-step dance. At frame 219 (4.38 s) the left and right distal elbow links overlapped by **34.59 mm**. The IK line search could trade penetration for a reduction in total task error. When a clip fails the self-contact check, the fitter now retries with a penetration bound in the line search, then screens the exported frames again. It uses the retry only if the self-contact failure clears and no new rejection reason appears. The final maximum on this dance is **17.45 mm** at frame 291, between the right hip-yaw and left distal elbow links. The admission limit is 20 mm. The frozen 7k actor completed its 451 steps. The other 39 reference hashes match the arm-calibration-only experiment. [Per-clip contacts, frames and reference digests](../output/e1-retarget-fix-20261111/results/references.json)

## Reference fidelity and policy performance

The panel contains 15,281 reference frames at 50 Hz. Each arm metric averages both arms and every frame within a clip, then weights the 40 clips equally. For each arm, bend measures the unsigned angle between shoulder-to-elbow and elbow-to-distal markers. Forearm direction compares the two elbow-to-distal vectors in world coordinates. None of the 40 source hashes occurs in the actor's E1 training catalog. The legacy path reproduced all 40 original reference hashes and the complete 7k per-clip evaluation records. [Paired summary](../output/e1-retarget-fix-20261111/summary.json) · [Original evaluation](../output/e1-bones-panel40-20261111/results/comparison.json) · [Legacy rerun](../output/e1-retarget-fix-20261111/legacy/final.json)

| Measure | Original references | Corrected references |
| --- | ---: | ---: |
| Mean elbow-bend error | 35.50° | 9.54° (38/40 improved) |
| Mean world forearm-direction error | 65.36° | 13.51° (40/40 improved) |
| References passing all geometric checks | 33/40 | 35/40 |
| 7k full motions / mean normalized return | 36/40 · 0.60094 | 35/40 · 0.54278 |
| 14k full motions / mean normalized return | 34/40 · 0.61343 | 34/40 · 0.56189 |
| Strict tracking, each actor | 0/40 | 0/40 |

Both actors attempted all 40 references, including the five that failed the corrected geometric screen. The 7k policy newly lost the dance turn at step 497 of 575 (9.94 s). At 14k the corrected stoop finished, and the one-hand behind-to-low motion newly terminated. Returns use the target for the corresponding run. [7k per-motion scores](../output/e1-retarget-fix-20261111/results/comparison.json) · [14k per-motion scores](../output/e1-retarget-fix-20261111/results/final.json)

The corrected stoop shows a second, independent issue. At frame zero the simulated right elbow pitch equals its corrected reference at −1.531 rad. The first 7k setpoint is −0.311 rad. At 0.20 s the measured joint is at −0.235 rad while the reference is at −1.650 rad. Across the entire stoop, the actual robot's two-arm bend error relative to G1 is 76.12° with the original references and 76.14° after calibration. A policy can finish this motion and still straighten the arm. On the dance turn, the corresponding error improves from 25.77° to 23.94° over the **498 frames common to both rollouts**, including reset. [Joint targets, commands and measured angles](../output/e1-retarget-fix-20261111/stoop-elbow.json) · [Matched-prefix rollout measurements for all three showcase comparisons](../output/e1-retarget-fix-20261111/rollout-arms.json)

Torso motion also has a physical limit in this model. The stoop reaches 36.63° of torso tilt relative to the pelvis on G1. The 23-axis E1 simulation has waist yaw and a fixed 0.08° mount tilt. Hip flexion or pelvis tilt can change the world pose, while the torso-to-pelvis tilt stays fixed. The panel measures two historical actors trained on the earlier catalog. Training a policy on a newly qualified catalog and measuring whether it follows these arms remain open. [Torso measurements](../output/e1-arm-transfer-20261111/torso-tilt.json)

## Reproduction

`prepare-qualified`, `prepare-locomotion` and `prepare-moving-locomotion` generate new qualified catalogs using the shared fitter. `retarget` exports one separate candidate at source tempo, with the geometry screen, arm errors and collision details in `retarget.json`. Its candidate acceptance also applies the historical 8 cm foot-target check. `retarget-legacy` runs the original standalone positional IK. For the prior full-panel two-pass fitter use `--panel-bind legacy-zero`.

The commands below use Bash, the authorized G1 CSV tree, the pinned 40-clip panel, and the original E1 dataset and actor exports. Output directories must be fresh. The full and trace runs use the same executable, both actors and the same four selected traces as the demo.

```bash
common=(--training-dataset "$E1_DATA" --tensor-library "$TENSOR_LIB"
        --library "$MUJOCO_LIB" --g1-scene "$G1_SCENE"
        --g1-directory "$G1_CSVS" --panel "$PANEL_JSON")
actors=(--actor "$ACTOR_14K" --comparison-actor "$ACTOR_7K")
"$E1_TRAIN" benchmark-panel "${common[@]}" "${actors[@]}" --output "$RUN/results"
"$E1_TRAIN" benchmark-panel "${common[@]}" --actor "$ACTOR_7K" \
    --panel-bind legacy-zero --output "$RUN/legacy"
"$E1_TRAIN" trace-panel "${common[@]}" "${actors[@]}" \
    --clip-indices '[10,26,28,38]' --output "$RUN/divergence"
moon run scripts/prepare_e1_panel_replays.mbtx "$RUN" "$ACTOR_7K" \
    ui/rabbita-cockpit/public/e1/assets anatomical
```

The corrected demo files contain simulated policy poses through the actual terminal frame. The replay exporter checks actor identity, reference digest, joint order, state continuity, step count, terminal flag and reward sum against the full evaluation. The dated results include the generator SHA256, both runtime identities and per-clip source and output hashes. [Replay exporter](../scripts/prepare_e1_panel_replays.mbtx) · [Verified replay manifest](../ui/rabbita-cockpit/public/e1/assets/panel-7000-anatomical/manifest.json)

To include the licensed horse-step regression in the native E1 package tests, also set `MOONROBO_G1_SCENE` and `MOONROBO_E1_HORSE_STEP_CSV` to the matching scene and panel clip 26. It checks the pinned source hash, serialized output hash, full frame count, geometry screen and forearm direction. [Native test setup](../src/learning_e1_training/README.md#commands)
