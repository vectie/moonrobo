# Native E1 training on two DGX Sparks

This package runs the existing native SuperMimic-style world model, imagined
actor/GAE critic, adaptive reset sampler, checkpoint, frozen actor and full-clip
evaluation with E1 physics. It has no robot SDK or motor-command dependency.

The working split is **178 for data, 179 for model execution**. The job roots are:

- 178: `/home/wlc003s/moonrobo/private/e1-native-20261110`
- 179: `/home/wlc004s/moonrobo/private/e1-native-20261110`

Both hosts have 3.7 TiB filesystems (nominal 4 TB). Build logs, data, checkpoints
and models stay there. The Mac checkout is the source/editing and compact-report
location, and its system-disk capacity does not describe either Spark.

## Embodiment and algorithm

`profile()` selects 23 physical axes. `profile(joints=24)` selects the lab's
24-axis model. The 23-axis scene fixes the vendor model's waist-roll hinge at
zero. This is a versioned simulation approximation pending confirmation against
the actual robot, not measured hardware calibration.

The first implementation keeps the established internal 29-axis state/tensor
layout. E1 physical axes occupy a prefix in the profile's named order. Remaining
actions, simulated state, imagined state and noisy joint observation channels
are projected to zero. This representation is declared in each export. The
public E1 `Actor::forward` returns only the 23/24 physical actions; its
`forward_embedded` returns the masked internal representation. The actor,
critic, world model and normalizers are newly trained for E1.

The current observation is the embedded SMC input: 99 values per frame,
10 history frames, and 10 reference frames of 73 values. Default-pose subtraction,
joint velocity and body gyro in rad/s, gravity, previous action and relative 6D
reference orientation match the native training path. `Profile::observation`
builds this input from explicitly calibrated physical vectors. The historical
compact 78/84/87-dimensional SDK contract in `learning_e1` is a different API.

The `training` configuration uses world window 8, imagination horizon 32,
world batch 256, actor batch 512, 64-row microbatches, 128 physical environments,
the existing 2048-wide world and 2048/1024/512/256 actor networks, and 500
world-only warm-up iterations. Physics is CPU MuJoCo at 200 Hz with 50 Hz
control; learning runs on the selected CPU/CUDA device. The corrected rotation
and heading implementation is used. G1's compiled BF16/Newton bundle is not an
E1 physics artifact and is not loaded by this entry point.

UTD is 0.1 per vector environment step: nominally 1,280 new physical transitions,
2,560 world windows (2 per new transition), and 16,384 imagined steps (12.8 per
new transition) per iteration. These ratios match the paper's nominal reuse;
the environment/global batch sizes and execution backend remain smaller.
Warm-up and extra actor-readiness collection are included in actual cumulative
exposure telemetry. The 14,000-iteration run uses a 14,000-iteration cosine decay,
rather than truncating a 250,000-iteration schedule.

`smoke` uses small networks and short windows to exercise the whole lifecycle.
`method-gate` retains training architecture, W8/H32 and batches, but enables
actor/critic updates immediately for a bounded integration check. It does not
change the production warm-up configuration.

## Data

`prepare` is a staging/diagnostic command. It reads the vendor E1 MJCF/meshes and four numeric NPZ motion files using
MoonBit. It checks array shapes, maps the documented Isaac breadth-first joint
order to the profile, converts WXYZ root rotation to the CSV boundary convention,
resamples each clip using its actual source FPS to 50 Hz, and recomputes velocities
and E1 body features. The source files and derived artifacts have SHA256 records.
Meshes are copied into a standalone scene bundle, with the vendor license.

Its four original references are not an admitted production curriculum.
`validate-model` independently compares source URDF, MJCF, MoonBit FK, recorded
NPZ body poses, and the locked-waist variant. `dance1` fails recorded-pose
consistency by 6 cm and 24 degrees and is quarantined.

`prepare-qualified` accounts for the four vendor candidates and all 40 pinned
LAFAN1 G1 candidates on 178. It measures source/native FK agreement, declares
any deterministic time scaling, then fits anatomical position/orientation tasks
using a bounded joint/velocity QP, bounded floating-base pose corrections,
line search, inferred stance locks, model-derived sole support, and native
collision penalties. Every complete candidate is screened frame by frame for
task error, joint limits/speed, actual sole-plane distance, self penetration,
prolonged unsupported/floating poses, and root-orientation deviation. Failed
clips remain in the exclusion inventory; frames are not silently cropped.

The admission sidecar binds the immutable accepted catalog to model validation,
per-clip reports, runtime and source identities, generator executable, and
versioned thresholds. A normal `train` must pass admission before allocating
the learner. Only explicit `--diagnostic true` bypasses it for legacy lifecycle
fixtures. Kinematic/geometric admission does not certify dynamic tracking.

These are separate vendor files; subject/action independence is not established.
The immutable dataset rejects repeated IDs and a repeated source hash across
splits. Scene, mesh, motion and checkpoint hashes are verified before use.

`retarget` takes G1 CSV, the matching G1 scene and source FPS. It uses the
shared two-pass anatomical fitter, native collision geometry and joint and
velocity bounds. The output is a separate candidate with foot errors, arm
angles and a geometric screen. `retarget-legacy` reproduces the original
single-clip positional fitter. For the two-pass panel baseline, select
`benchmark-panel --panel-bind legacy-zero`. The
[E1 retargeting measurements](../../docs/E1_RETARGETING.md) include the
40-motion comparisons, frozen-policy rollouts and reproduction commands.

The eager loader is bounded to 512 MiB of selected serialized training references
and the declared environment/batch limits. Full BONES-scale mmap/APIC throughput
is not claimed by this entry point.

## Commands

Build with the headers matching the selected MuJoCo shared library:

```sh
CPATH=/ABSOLUTE/mujoco/include moon build cmd/e1_train --release --target native
```

The resulting `e1_train.exe` supports:

```text
prepare  --lab-assets DIR --output NEW_DATASET --joints 23|24
validate-model --lab-assets DIR --dataset STAGED_DATASET --library FILE
         --output NEW_MODEL_AUDIT
prepare-qualified --dataset STAGED_DATASET --lab-assets DIR --library FILE
         --model-validation MODEL_AUDIT/validation.json --g1-directory DIR
         --g1-scene FILE --output NEW_QUALIFIED_DATASET
config   --profile smoke|method-gate|training --output NEW_CONFIG.json
inspect  --dataset DIR
train    --dataset DIR --config FILE --tensor-library FILE --library FILE
         --output RUN --iterations N --device 0 [--resume RUN/current.json]
         [--evaluate-every 500] [--diagnostic false]
export   --checkpoint RUN/current.json --tensor-library FILE --output NEW_ACTOR
evaluate --actor DIR --dataset DIR --tensor-library FILE --library FILE
         --output NEW_REPORT.json [--split validation] [--clip-indices '[0]']
retarget --dataset DIR --library FILE --g1-scene FILE --g1-csv FILE
         --fps SOURCE_FPS --output NEW_CANDIDATE
prepare-reembodied --training-dataset PARENT_CATALOG --dataset STAGED_TARGET
         --lab-assets DIR --library FILE --model-validation TARGET_AUDIT/validation.json
         --g1-directory LAFAN_ROOT --bones-directory BONES_ROOT --g1-scene FILE
         --output NEW_CATALOG
```

For a 24-axis experiment, stage a new scene with `prepare --joints 24`, run
`validate-model` on that scene, then use `prepare-reembodied`. This reloads
the parent curriculum's original source recordings and fits every trajectory
on the new body, including the native E1 clips. The whole-body fit can use
waist roll before guarded shoulder/elbow refinement. Source hashes, splits,
tempo and full durations are checked against the parent. Every candidate has
an acceptance or rejection report under the existing geometry thresholds.
Train a fresh model against this catalog and regenerate evaluation references
using the same target scene. Existing 23-axis checkpoints keep their original
joint indices and references.

The repository-owned `scripts/e1_spark_workflow.mbtx` records the original diagnostic two-host
setup, verified source/input packages, container images and resource limits.
Run it on the specified host with that host's toolchain and job root:

```sh
moon run e1_spark_workflow.mbtx prepare 178 /home/wlc003s/moonrobo/private/e1-native-20261110
moon run e1_spark_workflow.mbtx train-final 179 /home/wlc004s/moonrobo/private/e1-native-20261110
moon run e1_spark_workflow.mbtx resume-final 179 /home/wlc004s/moonrobo/private/e1-native-20261110
moon run e1_spark_workflow.mbtx export-final 179 /home/wlc004s/moonrobo/private/e1-native-20261110
moon run e1_spark_workflow.mbtx evaluate-final 179 /home/wlc004s/moonrobo/private/e1-native-20261110
```

Preparation/export/report paths must be fresh. Use a new run root for another
experiment. The driver is an integration workflow; direct `train` with the
`training` configuration selects a normal experiment and its requested length.
The corrected run uses `scripts/e1_qualified_training.mbtx`: freeze config and
executable, run the qualified two-iteration gate with actor/critic updates and
full-motion train/validation evaluation, then start a fresh 14,000-iteration
run on 179. Normal checkpoint evaluation covers every admitted motion from
frame zero every 500 iterations and at the final iteration.

## Checkpoints and inference

Generations contain all three networks and Adam state, saved normalizers,
stream-v2 replay/history/sampler metadata and blobs, source/profile/runtime
identities, and per-file digests. A single atomic `current.json` pointer publishes
a finished generation. An output-directory lock prevents concurrent trainers.

Resume validates the selected robot, dataset, scene assets, configuration,
tensor/MuJoCo libraries and all generation members. It resumes optimizer/learner
progress and reset sampling, performs a fresh physical reset, and refills replay.
This is **warm physical resume**, not an identical simulator trajectory.

Export contains an E1-specific manifest and actor-only native archive with empty
Adam state. It is a LibTorch/MoonBit archive, not TorchScript or ONNX. The runtime
needs the reference preview, saved normalizers, matching history ordering and
calibrated body/reference frames. No SDK quaternion convention is assumed.

Evaluation starts at clip frame zero, keeps each clip's full duration denominator
after early termination, disables training noise/randomization/timeouts, and
reports training/validation scope explicitly. A successful software gate does
not imply motion-tracking convergence or hardware readiness.

Training applies a Linux host/cgroup and CUDA limiting-availability check at
65%, without adding host and CUDA memory on the GB10. Its conservative eager
estimate and the separate synchronized CUDA allocator peak are reported. The
container additionally has a 100 GiB cap; neither measure guarantees no OOM.

## Verification

The locomotion comparison uses `e1_train prepare-locomotion` on 178. Pass
`--dataset`, `--model-validation`, `--library`, `--g1-directory`,
`--g1-scene` and a fresh `--output`. It fits four eight-second source
windows per walking, running or sprinting recording. Subjects 3 and 4 belong
to validation. The fitter smooths translation, orientation and joint angles
and checks the filtered poses against the original body and stance targets.
Each motion report includes acceleration percentiles and tracking errors from
100 ms MuJoCo rollouts using the E1 servos. These local resets limit what the
screen establishes about continuous motion.

Use `prepare-moving-locomotion` with the same arguments to select windows by
measured speed. Both source and retargeted mean horizontal speeds must reach
0.3 m/s for walking, 1.2 m/s for running or 2.0 m/s for sprinting. Report
the admitted coverage per split when interpreting a result.

On 179, `benchmark` accepts the regular `evaluate` arguments and an additional
`--training-dataset` pointing to the actor's original catalog. It verifies
both admissions and records both dataset identities. The per-clip report
includes active-joint, root, and tracked-body RMSE, plus body position error
after subtracting root translation. Strict success requires completion and all
four existing RMSE limits.

For a matched pilot, `train --initialize-from POINTER` transfers all three
networks, their Adam state and normalizers. Collection, replay and iteration
count start fresh. The initialization receipt identifies the source checkpoint.
The comparison driver fixes seed, physical collection, learning rate and
microbatches across its two runs and varies the global batch sizes.

Run the E1 tests with the tensor plugin. Supplying the frozen actor/checkpoint
paths also executes exact CPU checkpoint/export action parity and corrupt-digest
rejection; missing integration inputs are explicitly reported as skipped.

```sh
MOONROBO_TENSOR_LIBRARY=/ABSOLUTE/libmoonrobo_learning_tensor.so \
MOONROBO_MUJOCO_LIBRARY=/ABSOLUTE/libmujoco.so.3.15.0 \
MOONROBO_E1_DATASET=/ABSOLUTE/QUALIFIED_DATASET \
MOONROBO_E1_ACTOR=/ABSOLUTE/out/actor-23 \
MOONROBO_E1_CHECKPOINT=/ABSOLUTE/out/smoke-23/current.json \
moon test src/learning_e1_training --target native
```

The scoped G1 regressions exercise the learner, microbatches, normalization,
actor archive, runtime and geometry paths using the actual Spark tensor plugin.
Original Double defaults are preserved for G1 host observation subtraction;
the 29-axis path bypasses the new projections.
