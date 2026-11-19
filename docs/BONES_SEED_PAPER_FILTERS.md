# BONES-SEED paper filtering and training readiness

Audit date: 2026-10-24. Source is the local [SuperMimic v1 PDF](../output/pdf/supermimic-2610.28480v1.pdf), Appendix E, printed pages 15 and 17, Table A.7 on page 17 ([online paper](https://arxiv.org/pdf/2610.28480)). The intervening page 16 contains hyperparameters and a separate velocity-tracking task; its absolute fall thresholds are not motion-filter definitions.

The paper uses 129,514 filtered G1 motions. On 2026-10-24, MoonBit conversion completed on 178 for all **142,220** released G1 clips, totaling **124,554,605 source frames**, at `~/moonrobo/private/bones-seed/aligned-g1-v1`. The [MoonBit importer](../scripts/import_bones_seed_g1.mbtx) records this source corpus as unfiltered. The subsequent disclosed **partial** filter finished on 178 at 06:46:57 Beijing time, accepting **137,289** clips and rejecting **4,931**. Its 90,208,329-byte `manifest.paper-partial.json` has SHA-256 `64c21768fd7f2fad74d06153b1ada1faa958520abb8b234baa29d455572eb383`. The result is **7,775 clips larger** than the paper's 129,514-motion set; it is not the paper-exact benchmark. [Filter exit record](../output/spark-runtime-20261024/bones-filter-final/178/bones-filter-state-20261024-final.json), [manifest audit](../output/spark-runtime-20261024/bones-filter-final/178/bones-filter-manifest-audit-20261024-b.json).

The converted corpus was also copied from 178 to 179 over `10.0.0.1` →
`10.0.0.2` using the ConnectX-7 interfaces, with a 200 MiB/s transfer limit.
The initial rsync reported 142,221 regular files and 90,328,276,353 payload
bytes, without deleting any files. This included the 142,220 clips and
unfiltered manifest; filter receipts and the then-unpublished filtered
manifest were excluded. The destination unfiltered manifest SHA-256 matched 178:
`97e9f4910c2d986d2c825f04104a4189eafc5e6df1853d61697a9bb6bc0a9d19`.
On 179, a separate read-only, CPU-only, 16 GiB-capped preflight verified
all 142,220 clips against that manifest, finishing at 05:59 Beijing time
with exit 0 and `OOMKilled=false`. It checked data hashes, not CUDA runtime
or asset compatibility, and executed no training. The Python source hashes
in that receipt describe the pre-refill-fix files; those files were archived
before applying the later actor-readiness repair. The completed filtered
manifest and receipts were subsequently transferred to 179. Read-only final
receipt scans on both hosts found all **142,220** decisions, a contiguous
prefix through index 142,219, 137,289 accepted, 4,931 rejected and no
temporary files; the [178 scan](../output/spark-runtime-20261024/bones-filter-final/178/bones-filter-progress-20261024-final.json) and [179 scan](../output/spark-runtime-20261024/bones-filter-final/179/bones-filter-received-progress-20261024-final.json) agree. The [manifest SHA-256 on 179](../output/spark-runtime-20261024/bones-filter-final/179/bones-filter-received-sha-20261024-final.txt) matches 178. These checks verify receipt structure and copied bytes, not independent MuJoCo re-evaluation. Neither transfer nor catalog verification loads the corpus onto a GPU.

The read-only [progress inspector](../scripts/inspect_bones_filter_progress.mbtx)
counts completed receipt files instead of relying on console output. During
the run, receipt 0 appeared at 05:40 and receipt 9,999 at 05:47 while the
console log had not yet displayed those milestones. An initial scan raced an
atomic rename of a `.json.partial` file; the inspector now skips temporary
names before filesystem inspection, while missing or malformed final `.json`
receipts still fail. The earlier failed and successful scans remain as
historical evidence; the filter process was not restarted or modified.

## Disclosed rules

| Pass | Published definition | Published output |
| --- | --- | --- |
| Source corpus | Public BONES-SEED G1-retargeted release | 142,220 clips |
| Action-name exclusions | Remove terrain/object interaction names using a SONIC-derived keyword list plus additional terms. Examples are `stair`, `ladder`, `box`, `chair`, `sit`, `climb`, `jump off 50cm`, `look over fence`. | Remove 12,553; retain 129,667 |
| Elevated support | With floor at zero, let `z_min(t)` be the lowest body-link height. Reject when it stays above 0.20 m for at least 0.6 s. | Included in the following 153 removals |
| Penetration | Reject if `z_min(t)` is below −0.12 m at any point, or below −0.08 m for more than 80% of the clip. | Included in the following 153 removals |
| Floating feet | Both feet have exact collision-geometry-to-plane distance greater than 0.02 m for at least 0.5 s, while the pelvis is upright, at standing height, and the body is nearly stationary. Distance must use MuJoCo `mj_geomDistance`, not foot link origins. The stationary condition excludes ballistic jumps. | Combined feasibility pass removes 153; retain 129,514 |

Appendix E specifies that feasibility thresholds were tuned for the G1 retarget at 50 Hz. Thus these checks belong after the 120 Hz source conversion and 50 Hz resampling. They must use the actual compiled robot, all relevant body links, and collision geometry; the 14 tracked reward bodies alone are not an equivalent definition of minimum body-link height. The reported clean-ground foot distance distribution (−0.004 ± 0.004 m) explains the published threshold and is not an additional rejection rule. [Paper, pp. 15 and 17](https://arxiv.org/pdf/2610.28480#page=17).

The paper's Appendix E discloses the name pass and these three feasibility tests; it does **not** define a further joint-limit, joint-velocity, contact-force or generic quality-score threshold for selecting training clips. Joint-limit penalties elsewhere in the paper and the absolute fall thresholds of its separate velocity-command task are training/task definitions, not dataset filters. Adding such gates would create another dataset, not fill an undocumented Appendix E parameter.

### Public SONIC name-filter baseline found

The [released SONIC data-processing file at pinned revision `45c03facbf848e0c743091b7d9c17952096ff908`](https://github.com/NVlabs/GR00T-WholeBodyControl/blob/45c03facbf848e0c743091b7d9c17952096ff908/gear_sonic/data_process/filter_and_copy_bones_data.py) contains **40 default exclusion strings** (source-file SHA-256 `b6b50d441a4876a382eb3ff33ba940c487d1647230b5ecacaa37cfcf521258da`). Its `should_filter_out` lowercases the input filename and each keyword, then performs substring membership; the copy pass tests `parent-directory/basename.pkl`, with an optional include-list and `--add-keywords`. This is a reproducible **SONIC baseline**, not the complete SuperMimic list: Appendix E says SuperMimic *adapted* the list and added terms SONIC misses, without publishing the final list or a pinned SONIC revision. Some SONIC defaults (`acrobatics_`, `cartwheel`, `handstand`, `safety_roll`) can remove acrobatic actions; the paper's final benchmark contains flips and side rolls, so copying all 40 defaults without inspecting membership is especially unjustified. The raw G1 CSV names, SONIC's intermediate PKL parent/basename and our converted `date/name` IDs also need an explicit mapping before claiming identical name decisions. The official [BONES-SEED dataset card](https://huggingface.co/datasets/bones-studio/seed/blob/main/README.md) describes the public `g1/csv/{date}/{motion_name}.csv` path and metadata fields, but publishes no SuperMimic accepted-ID manifest.

This source enables a separately named, provenance-pinned `SONIC-default-keywords + disclosed-feasibility` **candidate** filter. It cannot be relabeled as the 129,514-motion paper benchmark merely because its count is near 129,514. Keep the current 137,289-motion catalog labeled `paper-partial` for training and same-set evaluation while exact membership is unresolved; for a new candidate catalog, retain both manifests and all excluded IDs/reasons rather than replacing the completed partial result.

## Details needed for an exact benchmark claim

1. SuperMimic's **additional** keywords, its chosen SONIC revision and exact mapping from BONES CSV clip IDs to the names tested by its filter. A current public SONIC default list and its lowercase-substring behavior are known (above); that does not establish the authors' final list or their exact matching inputs. The paper's examples are not a complete list.
2. The numerical upright gate for the floating-feet rule, including its geometric convention.
3. The standing-height gate or range for that rule.
4. The stationary metric, bodies/components measured, thresholds and any smoothing used for that rule.
5. The exact compiled G1 model and foot collision-geometry set used in filtering. Appendix E does not publish an asset hash or geometry identifiers.
6. Exact temporal implementation details at run boundaries, or preferably the authors' accepted/rejected clip IDs and hashes. Duration comparisons on sampled frames can differ by one frame unless the original convention is known.

Several numerical checks are therefore implementable from the paper; saying that all feasibility thresholds are unpublished would be incorrect. The listed missing definitions still prevent proving membership in the exact 129,514-clip set. A local filter may record explicitly chosen assumptions and its own accepted/rejected IDs, but matching the clip count alone is insufficient evidence. Never tune undocumented gates merely to hit the reported count, silently substitute foot-origin heights, or mark the unfiltered corpus as the paper benchmark.

The inspected `../smc/tools/download_data.sh` obtains only the 40 LAFAN1 G1 CSVs and robot assets. Its `supermimic/motion.py` performs reference interpolation/FK, not BONES name or feasibility filtering. No BONES filter implementation was found in that reference path; it cannot supply the missing Appendix E definitions.

## Current execution paths

| Path | Implemented behavior | Remaining limitation |
| --- | --- | --- |
| `scripts/import_bones_seed_g1.mbtx` | Header-based joint mapping, cm→m, Euler-degrees→xyzw, joint-degrees→radians, per-clip hashes, source/mirror provenance | Produces an unfiltered 120 Hz catalog; does not establish the paper subset |
| `providers/motion_learning/aligned/train.py` | CUDA PyTorch learner, manifest loading, disk-backed reference cache, bounded batch gathers, memory planning, independent runs and explicit gradient averaging; the 179 single-host gate and subsequent two-host 128-env-per-rank/one-iteration physics and optimizer gate passed over RoCE, with GDR disabled and no OOM | Full-corpus training, sustained memory/throughput and learning-quality results still need execution evidence; the small distributed gate does not establish a speed or convergence advantage |
| `scripts/run_g1_aligned.mbtx` → `src/learning_aligned/cmd` | Native MoonBit scalar CPU Float64 learner; optional CUDA APIC physics; eager or bounded disk reference storage | CUDA physics does not make the learner CUDA-resident. Native runner rejects CUDA learner/AMP and distributed requests |
| `src/learning_aligned_gpu/cmd` → `learning_aligned_gpu` / `runtime` | Parallel MoonBit Float32 tensor learner integrated with bounded physical collection/replay/reference batches, differentiable batched geometry, 8-step model fitting, 32-step actor imagination/GAE critic, Adam, normalization and checkpoint/RNG restore. Earlier CPU-MuJoCo/CUDA-learner gates passed; the later [two-host native APIC GPU-physics/DDP gate](DGX_SPARK_CONNECTX7_RDMA.md#native-apic-gpu-physics-and-two-rank-learner-gate) completed one synchronized iteration at 2 environments per rank on the 40-motion LAFAN1 set, using NCCL `NET/IB` with `GDR 0`; CPU readback of saved shared parameters, Adam state and normalizers matched across ranks | This verifies a small GPU-physics/learner/collective execution path and shared-state consistency, not SDK numerical equivalence, distributed resume, convergence, full BONES throughput or a speed advantage. AMP/bf16 remains unsupported |
| `src/learning_aligned/motion_io.mbt` → `MotionLibrary` | `reference_storage=mmap` stages bounded source chunks into resumable disk shards, reads through a fixed 64 KiB window, derives frame indices from boundaries, computes FK on demand; reused by the tensor runner | Metadata and time bins remain resident. The tensor CLI adds conservative memory preflight and bounded gathers, but full-corpus native training memory/throughput is unmeasured; eager mode still rejects known full-paper/raw sizes |
| `src/learning_tensor` | Explicitly loaded LibTorch C++ plugin integrated into `learning_aligned_gpu`: device tensors, batched math/autograd, Float32/BFloat16 storage, Adam state and tensor checkpoints; intermediate tensors and optimizer moments stay on the selected device; CPU checks and small GB10 Float32 learner gate passed | BFloat16 storage support is not mixed-precision learner/autocast support; matched cross-runtime CUDA numerical parity and sustained resource use still need validation |

The scalar MoonBit, tensor MoonBit and preserved Python paths remain parallel implementations. The Python module has completed small single-host and two-host distributed Newton GPU physics/CUDA learner gates. The tensor MoonBit command is a separate executable; its earlier CPU-MuJoCo/CUDA-learner gates and 179 single-host [APIC GPU-physics gate](DGX_SPARK_APIC_EXPORT_PLAN.md) remain historical records. The later [178+179 APIC DDP gate](DGX_SPARK_CONNECTX7_RDMA.md#native-apic-gpu-physics-and-two-rank-learner-gate) exercised native APIC GPU physics and the Float32 CUDA learner together at 2 environments per rank, with matching CPU readback of saved shared state. The independent SDK numerical comparison still has a retained mismatch. These runs do not establish bf16 parity between implementations, SDK numerical equivalence, cross-host resume, convergence or full paper-scale behavior; the scalar wrapper does not silently call either GPU learner. The [native DDP memory measurements and saved-state verification](DGX_SPARK_CONNECTX7_RDMA.md) supplement the first-run results below.

The native LibTorch image built on 179 has ID
`sha256:c1656ac956e04e071bef22248828a6e352457923577c9239f32a7bf5ae8046bb`;
its `libmoonrobo_learning_tensor.so` SHA-256 is
`dc06566941056d8d637c4f2e90eb55278557afd4651f10875120874473d61b0c`.
The first 2-env native CUDA attempt returned a physics error because the
host-built executable lacked MuJoCo C headers. Building the MoonBit executable
requires `CPATH` to include the **matching pinned MuJoCo 3.15.0 installation's
include directory**, which must contain `mujoco/mujoco.h`, and recompilation
of `src/learning_physics/mujoco_stub.c`. The compiled header ABI must match the
runtime selected by `--library`; setting `CPATH` or changing `--library` only
at execution cannot add bindings omitted at build time. The CLI now exposes
the compiled header version and refuses missing headers with this diagnostic.
After that build correction, the compiled header ABI is `3015000` and the
native executable SHA-256 is
`815ea5ba1154b976158016e11fdbc8eadfab88bc836d404a063e2d67eb7605dc`.
The actuator-equipped scene is
`data/g1_description/scene-no-self-collision.xml`, SHA-256
`34cf0cf3c5fa5452fc24d33d9f31fb4a4435f3050366041e1dc853b39bdd20ee`;
the raw `g1_29dof.xml` has no actuators and is unsuitable for this native
MuJoCo control gate. Do not substitute the two scenes silently.

On 179, the corrected executable completed a 2-environment paper-width
Float32 CUDA learner with CPU MuJoCo physics: iteration 1 recorded 36
physical and 64 imagined transitions, one model update, one actor update and
four critic updates. Resume reached iteration 2 with cumulative counters
42 physical, 128 imagined, two model, two actor and eight critic updates;
the runtime reported `resume_kind=exact`. The container cap was 16 GiB and
no OOM was observed; peak memory was not measured. This demonstrates a
working checkpoint continuation, not an uninterrupted-versus-resumed CUDA
bitwise comparison or native Newton/APIC GPU physics.

A separate [178 native DDP report](../output/spark-runtime-20261024/native-ddp/178/runs/native-ddp-gate-20261024-c/rank-0/report.json) and [179 report](../output/spark-runtime-20261024/native-ddp/179/runs/native-ddp-gate-20261024-c/rank-1/report.json) record one synchronized Float32 CUDA learner iteration with CPU MuJoCo physics and two environments per rank. Each rank collected 36 physical transitions and imagined 64 transitions, then performed one world-model, one actor and four critic updates. The `global_counters` fields sum work across ranks (72 physical and 128 imagined transitions, 2 model/2 actor/8 critic *rank-local update operations*); they do not indicate two synchronized training iterations. Both [178](../output/spark-runtime-20261024/native-ddp/178/native-ddp-gate-20261024-c-container.json) and [179](../output/spark-runtime-20261024/native-ddp/179/native-ddp-gate-20261024-c-container.json) containers exited 0 with `OOMKilled=false`. Their [178](../output/spark-runtime-20261024/native-ddp/178/native-ddp-gate-20261024-c.log) and [179](../output/spark-runtime-20261024/native-ddp/179/native-ddp-gate-20261024-c.log) logs show NCCL `NET/IB` and `GDR 0`. The 16 GiB caps bounded the gate, but measured peak memory is absent. Distributed checkpoint metadata reports `resume_supported=false`; no cross-host resume or training-quality claim follows from this gate.

## Audit change and verification

`distributed.assert_same_learner` originally changed scalar Float tensor dtype with `view(torch.uint8)`. PyTorch rejects that operation for zero-dimensional normalizer counts and Adam step tensors, so two-node resume failed before checkpoint comparison. The digest now preserves the original shape in its header and flattens only the byte view. Two CPU-only regression cases cover scalar/bfloat16 encoding, shape/value distinction, and mismatched-rank rejection. They passed on local PyTorch 2.9.1; no NCCL/GPU execution is claimed.

The subsequent bounded-storage implementation replaces the temporary mapped-storage refusal. The compatibility option `mmap` uses fixed-window disk IO in MoonBit, rather than mapping the entire corpus. See [native reference storage](../src/learning_aligned/storage/README.md). Full-corpus eager loading remains refused; the separate tensor runner accepts the narrowly configured native DDP path above. Small eager CPU catalogs remain supported. Isolated tests cover capacity boundaries plus native disk interpolation/FK/goals/bin parity, reuse, corruption rebuild and source tamper rejection. This does not complete native BONES/CUDA training. Full-corpus sustained physical training, numerical migration parity and full-corpus memory/throughput measurements remain unverified; the small execution gates recorded above have passed.

## Reproducible partial filtering command

The completed native filter used a 16 GiB cgroup limit with no additional
swap, two CPU cores and no GPU. It ran from 04:36:07 to 06:46:57 Beijing time
and exited 0 with `OOMKilled=false`. The [read-only memory monitor](../output/spark-runtime-20261024/bones-filter-final/178/runs/bones-filter-memory-20261024-a/final-summary.json)
recorded a maximum sampled `memory.current` of 16 GiB and a maximum observed
kernel `memory.peak` of 17,179,877,376 bytes (8 KiB over the configured cap),
with `oom=0` and `oom_kill=0`; file-cache reclaim was active. Monitoring began
after launch and the final cgroup disappeared between polls, so this is **not
a certified full-lifetime peak**. It is also not evidence that subsequent
training fits the same limit.
The native training configuration can reuse its per-clip `.f64` cache by
setting `motion_cache_dir` to the same `filter-reference-cache` directory.
Python's whole-catalog `.f32` cache is a different format. A restarted filter
reuses valid shards and decision receipts but still rehashes the inputs;
the cache-preparation phase has no per-clip progress log. The source-frame
counts imply at most approximately 29.43 GiB of resampled `.f64` frame data,
which stays on disk. Every training launch still needs its own actual
host/CUDA memory preflight.

The complete 142,220-clip unfiltered import wrote `manifest.json` on 178. The [MoonBit partial filter](../scripts/filter_bones_seed_g1.mbtx) then evaluated the two disclosed body-height feasibility rules at 50 Hz through the compiled G1 MuJoCo model. It refused a partial source release and used the native fixed-window reference cache; it did not hold all resampled frames in RAM or GPU memory. The [completed invocation](../output/spark-runtime-20261024/bones-filter-final/178/bones-filter-state-20261024-final.json) pinned the MuJoCo 3.15.0 shared library, `scene-no-self-collision.xml`, source manifest, cache and config paths. To reproduce from the repository root, supply the corresponding local paths:

```bash
moon run --target native scripts/filter_bones_seed_g1.mbtx \
  /private/bones-seed/converted/manifest.json \
  /path/to/libmujoco.so \
  /private/g1_description/scene.xml \
  /private/bones-seed/filter-reference-cache \
  examples/learning/bones-paper-partial-filter.json
```

The completed run used the checked-in config with an empty `name_exclusion_terms` list because the full author list has not been published in the paper. An operator may supply a separate JSON config with a chosen complete list; matching is explicitly ASCII-lowercase substring matching against the catalog clip ID, and its file bytes are SHA-256 pinned in the receipts. That local choice remains unverified against the authors' exact list. The script never substitutes the paper's example terms for a complete list.

The filter computes the minimum world-z among all G1 body origins connected to the compiled robot after `mj_forward`, excluding the world. A run of at least 30 consecutive 50 Hz samples with minimum z above 0.20 m triggers the elevated rule. Any sample below −0.12 m, or strictly more than 80% below −0.08 m, triggers the penetration rule. The [manifest audit](../output/spark-runtime-20261024/bones-filter-final/178/bones-filter-manifest-audit-20261024-b.json) counted 3,946 elevated, 812 below −0.12 m and 328 below −0.08 m reason occurrences. Their sum, 5,086, exceeds 4,931 rejected clips by 155 because some clips carry multiple reasons; the summary does not identify how many clips overlap. Accepted clips contain 121,458,621 source frames, 50,243,634,836 source bytes and 87,996,168,100 converted bytes. These counts and rule labels are manifest/receipt outcomes, not a fresh physics recomputation. The floating-feet rule was **not run**: its exact geometry-distance implementation and upright, standing-height and stationary gates are unavailable. The output must not be called the paper's 129,514-motion set.

The script creates per-clip decision receipts under `paper-partial-decisions-v1/` beside the source manifest and publishes `manifest.paper-partial.json` in that same directory, preserving relative `clips/...` paths. Each receipt records accepted/rejected status, reason IDs, SHA-256 of the original G1 archive and source CSV, plus the unfiltered manifest, config, scene XML, **sorted scene-asset directory tree**, MuJoCo library and converted clip. The tree digest includes the sibling MJCF includes and meshes; it rejects symlinks or special files and is limited to 8,192 files and 16 GiB of source bytes. The archive defaults to `g1.tar.gz` in the converted catalog's parent directory; `MOONROBO_BONES_ARCHIVE` can select another local path. All file hashes use 64 KiB streaming reads. The manifest, configuration, individual CSV and receipt are limited to 512 MiB, 1 MiB, 128 MiB and 64 KiB before parsing. Restarting an interrupted run reuses matching receipts and verifies clip bytes; a changed source/config/model fails closed. The final manifest contains the accepted clip IDs in both train and same-motion evaluation splits, rejected IDs with reasons, exact accepted byte/frame totals, and `paper_exact_motion_set=false`. Source clips and the unfiltered `manifest.json` remain untouched. Metadata for all clips and reset bins remains resident; the 50 Hz frame array does not. This was data preparation, not a training launch.

The [read-only final-manifest audit](../scripts/audit_bones_partial_manifest.mbtx) ran successfully in a second 16 GiB, two-CPU container after the first container lacked a C compiler; the failed build log and exit 255 are retained. It checked the 90,208,329-byte manifest's accepted/rejected partition, train/evaluation ID order, accepted frame/byte totals, rule flags and hash-field syntax, then emitted the SHA-256 above. It did **not** read CSVs, compare declared hashes with external files, read every receipt or recompute MuJoCo decisions. The separate full receipt scans above verified all 142,220 published decision files. [Successful audit output](../output/spark-runtime-20261024/bones-filter-final/178/bones-filter-manifest-audit-20261024-b.json), [successful container state](../output/spark-runtime-20261024/bones-filter-final/178/bones-filter-manifest-audit-state-20261024-b.json), [first failed build](../output/spark-runtime-20261024/bones-filter-final/178/bones-filter-manifest-audit-20261024-a.log).

That successful remote audit used script SHA-256 `5d54238a263c97aab1e271055c98c6835c7fa1d74a676b518253bac35f90f713`. A later **local-only** change added a pre-addition exact-integer overflow guard; its script SHA-256 is `136ce05cb9e82957821f9e13b4729592d6425196284fd4dfa750bd75e9224402`. The new version passed a narrow CPU test and has **not** been deployed on 178 or used to create the saved remote audit result. The observed corpus totals are far below that guard's limit.

`preflight_g1_smc_node.mbtx` can accept this separate partial status after verifying the complete source manifest, original archive, current compiled scene, configured MuJoCo library and filter config, each converted clip, and every decision receipt. It has **not yet been run on the filtered manifest**. Set `MOONROBO_MUJOCO_LIBRARY` to the local library path and, for a non-default config, `MOONROBO_BONES_FILTER_CONFIG` to the local config file before that preflight. Its report distinguishes receipt verification from physical decisions, which it does **not** recompute. The unfiltered catalog remains independently accepted under its original label.
