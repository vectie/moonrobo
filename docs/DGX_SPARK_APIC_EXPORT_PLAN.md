# Small genuine G1 APIC export for the native CUDA learner

The minimum existing route to a genuine two-environment, four-operation
artifact is `cmd/reference_apic_export export-reference CONFIG`. MoonBit owns
the authoring recipe and calls the pinned SDK through a small CPython 3.12
embedding bridge. The resulting replay adapter uses native Warp/CUDA APIs;
the offline export still uses Python SDK objects. Both the authoring and
native replay images built successfully on 179. The bounded
`apic-export-20261024-h` run then exported all four real graphs successfully,
with exit 0 and no OOM. Its approximately 40 MiB bundle is at
`179:~/moonrobo/runs/apic-export-20261024-h/g1-2env-apic`; manifest SHA-256 is
`38d67d87cb0c9294fc7c9cb7635b6b9a88587f23a0036bdeb3cb6de2d1fb9b51`.
The following native replay audit passed all 20 operations on two worlds,
including isolated reset/context writes and repeated-refresh invariants,
under an 8 GiB cap with exit 0 and no OOM. Its maximum state change during
the eight steps was `2.90492542`. Numerical parity against the independent
eager SDK oracle has not passed all retained comparisons; see the repeat
analysis and separate learner execution below.

## Observed replay differences and native GPU learner execution

The independent SDK trace was executed twice with the same fixed tape,
configuration and source identity. The
[repeat analysis](../output/spark-runtime-20261024/native-apic/repeat-analysis-20261024-v1.json)
and [reproducible MoonBit comparison](../output/spark-runtime-20261024/native-apic/compare-apic-repeat-v1.mbtx)
bind the four input traces and the artifact hashes. SDK a/b differ by at
most `1.51395798e-5`, while native a/b differ by at most `6.43730164e-6`;
both within-path comparisons satisfy the original per-element rule
`abs(actual-reference) <= 1e-5 + 1e-5*abs(reference)`.

Native replay b versus SDK a fails that rule for the right hip pitch
velocity at step 6, world 1: difference `1.77025795e-5`, allowed
`1.65456921e-5`. The raw velocity and derived state report the same physical
component twice. Native a also fails against SDK a. Both native traces pass
against SDK b, but selecting that repeat would discard contrary evidence.
The original failure is preserved and **physical equivalence remains
unverified**. No tolerance was widened. Both paths first diverge in their
raw physical views at step 5, world 1; repeat variability alone does not
establish the cause of the cross-path difference.

Separately, the [179 native GPU learner gate](../output/spark-runtime-20261024/native-apic/runs/native-apic-learner-20261024-a/train/report.json)
completed at 05:34 Beijing time on 2026-10-24, using two environments,
Float32 CUDA tensors, native APIC GPU physics and one requested iteration.
It performed 36 physical transitions, 64 imagined transitions, one world
model update, one actor update and four critic updates, then saved a
checkpoint. The update loop reported 5,811 ms; container lifetime was about
26.9 s, including setup and checkpoint work. These are tiny execution-gate
timings, not a sustained throughput benchmark.

The actual preflight retained the 24 GiB physics reserve and 65% free-memory
guard, estimating 30,930,712,096 bytes under a 48 GiB container cap with no
additional swap. The [read-only memory monitor](../output/spark-runtime-20261024/native-apic/runs/native-apic-learner-memory-20261024-a/final-summary.json)
observed a kernel peak of 2,588,884,992 bytes across 26 readable samples,
with zero OOM counters; the container exited 0 with `OOMKilled=false`.
The cgroup disappeared before the final poll, so the monitor explicitly
does not certify the complete lifetime peak. The successful learner gate
does not override the numerical mismatch, justify a larger run, demonstrate
convergence, or establish full BONES training. Its `smc` orientation input
and disabled self-collision are disclosed deviations from the paper.

The saved generation also passed a [CPU-only readback audit](../output/spark-runtime-20261024/native-apic/native-apic-checkpoint-audit-20261024-a.log)
against its pre-save parameter, Adam and normalizer attestation
`cd20becad40b38bcd20c73cf834f3e67df67d7c548952453ffaa89be4255b94e`.
Both inputs to the existing comparison tool deliberately name that same
generation: this validates saved-state readback, not independent-run
agreement. The read-only container used 8 GiB, exited 0 without OOM-kill,
and performed no GPU or physical simulation work.

The exported GPU environment supports warm-reset/refill checkpoint resume,
not exact physical continuation: solver/contact state is not checkpointed.
The runner clears and refills replay/history after that reset. Distributed
resume remains unsupported.

The ordinary `scripts/export_g1_aligned_apic.mbtx` wrapper defaults to
`export-native-io`, which is a different hybrid route. Select its
`--python-reference` flag or call `export-reference` directly. The hybrid
requires additional MuJoCo descriptor, Python-disabled OpenUSD C++ and Warp
writer plugins, while still retaining CPython for the complete physical SDK
program. Its extra dependencies do not make it the minimum first export.
The reference authoring route and all Python implementations remain available.

## Two-host APIC learner gate, 2026-10-24

`native-apic-ddp-20261024-b` completed on 178 and 179 at about 06:25 Beijing
time using the existing genuine four-graph bundle, native APIC GPU physics
and the MoonBit Float32 CUDA learner. The [178 report](../output/spark-runtime-20261024/native-apic/ddp-b/178/runs/spark-native-apic-ddp-gate-native-apic-ddp-20261024-b/rank-0/train/rank-0/report.json)
and [179 report](../output/spark-runtime-20261024/native-apic/ddp-b/179/runs/spark-native-apic-ddp-gate-native-apic-ddp-20261024-b/rank-1/train/rank-1/report.json)
each record two environments, 36 physical transitions, 64 imagined
transitions, one model update, one actor update and four critic updates.
This is one synchronized optimizer iteration with different collection
seeds (179/180), not two independent training seeds. It uses the fixed
40-motion LAFAN1 manifest; the BONES corpus was not trained by this gate.
NCCL selected the expected ConnectX-7 HCAs and `NET/IB/0`, with `GDR 0` on
both hosts; see the [transport evidence](DGX_SPARK_CONNECTX7_RDMA.md#native-apic-gpu-physics-and-two-rank-learner-gate).

Both ranks used image
`sha256:d28f698d99e514b5c8dc5d682fa126507a27901ec016cb1f0795b83ac426bfca`,
native executable SHA-256
`da028b10821efe330bdf199db00e52799ab6c749635a5ca2c2bb3c5890ea84f0`,
and the original bundle manifest SHA-256 `38d67d87…fb9b51` recorded above.
The [launch record](../output/spark-runtime-20261024/native-apic/ddp-b/178/runs/spark-native-apic-ddp-gate-native-apic-ddp-20261024-b/rank-0/launch.json)
keeps the 48 GiB container cap, no extra swap, 65% admission threshold,
24 GiB physics reserve and finite deadlines. Both report the same
32,004,453,920-byte preflight estimate; that estimate is not a measured peak.

| Host/rank | Observed cumulative cgroup peak | Trainer/container exit | OOM counters / OOM-killed |
| --- | ---: | --- | --- |
| 178 / 0 | 3,176,099,840 bytes | 0 / 0 | 0 / false |
| 179 / 1 | 3,061,059,584 bytes | 0 / 0 | 0 / false |

The [178 result](../output/spark-runtime-20261024/native-apic/ddp-b/178/runs/spark-native-apic-ddp-gate-native-apic-ddp-20261024-b/rank-0/inside-result.json)
and [179 result](../output/spark-runtime-20261024/native-apic/ddp-b/179/runs/spark-native-apic-ddp-gate-native-apic-ddp-20261024-b/rank-1/inside-result.json)
explicitly limit those peaks to the final sample before helper exit.
They include container startup but cannot certify later activity through
container termination. No full-lifetime or per-library allocation peak is
inferred from them.

The preceding attempt a remains in the evidence set. Its [178 preflight failure](../output/spark-runtime-20261024/native-apic/ddp-a/178/runs/spark-native-apic-ddp-gate-native-apic-ddp-20261024-a/rank-0/trainer.stdout.log)
records 11,190,460,416 CUDA-free bytes and a 7,273,799,270-byte admission
budget, below the same 32,004,453,920-byte estimate. The [179 preparation log](../output/spark-runtime-20261024/native-apic/ddp-a/179/runs/spark-native-apic-ddp-gate-native-apic-ddp-20261024-a/rank-1/trainer.stdout.log)
records the propagated data-ready abort. Both exited 1 with no observed OOM
and `OOMKilled=false`. The subsequent [bounded file-cache advice](../output/spark-runtime-20261024/native-apic/ddp-b/178/cache-advice-178-converted-20261024-a.log)
covered 142,220 completed, published converted CSVs on 178, reading and
writing zero payload bytes. It requested file-specific cache reclamation;
it did not delete files or invoke global cache dropping. Attempt b retained
the same memory thresholds and estimate.

After b, a [read-only CPU audit](../output/spark-runtime-20261024/native-apic/ddp-b/178/native-apic-ddp-checkpoint-audit-20261024-b.log)
decoded rank 0's `generation-1-1792794335555` and rank 1's
`generation-1-1792794335571`, the latter transferred from 179. This compares
two distinct saved rank generations, unlike the earlier single-generation
readback audit. Both verify against their own held-state attestations;
identity, iteration and shared learner state compare equal, including all
three networks, Adam moments/options/steps and normalizers. The shared
digest is `850e22749fd10b718e5f1c24a5aa9ed498e8947bb93e6575af019ce8f2d94b1e`.
The [audit container result](../output/spark-runtime-20261024/native-apic/ddp-b/178/native-apic-ddp-checkpoint-audit-20261024-b.state.json)
records exit 0 and `OOMKilled=false`; no training or GPU execution was part
of this audit. Rank-local replay, RNG and physics were not compared.

This verifies a small two-host execution and checkpoint-consistency gate.
It does not resolve the retained SDK numerical mismatch, establish exact
solver or distributed resume, demonstrate convergence, measure sustained
bandwidth, or compare DDP performance with independent seeds. The existing
`smc` observation and self-collision deviations remain disclosed.

## Full BONES catalog single-rank gate, 2026-10-24

On 178, the [container result](../output/spark-runtime-20261024/native-bones-catalog/runs/native-bones-catalog-20261024-a/docker-final.json)
records exit 0 and `OOMKilled=false` for the 137,289 accepted, partially
filtered BONES clips. The [helper result](../output/spark-runtime-20261024/native-bones-catalog/runs/native-bones-catalog-20261024-a/inside-summary.json)
confirms all 137,289 clips loaded and the saved stream-v2 checkpoint catalog
count of 137,289. The loader verified 87,996,168,100 source bytes and
30,779,167,040 Float64 shard bytes; it created zero new shards and reported
zero cache-advice failures. The [training report](../output/spark-runtime-20261024/native-bones-catalog/runs/native-bones-catalog-20261024-a/train/report.json)
records one world update, one actor update, four critic updates, 36 physical
and 64 imagined transitions. The post-catalog 65% memory admission passed
without lowering the 24 GiB physics reserve.

The container ran from 23:24:59.513 to 23:37:04.253 UTC, about 12 minutes
4.74 seconds including full-catalog hashing, loading, the update and save.
The report's 5,993 ms `elapsed_milliseconds` covers only its internal training
segment. The [last cgroup snapshot](../output/spark-runtime-20261024/native-bones-catalog/runs/native-bones-catalog-20261024-a/cgroup-after.json)
observed a kernel peak of 3,273,281,536 bytes and zero OOM counters before
helper exit; it does not certify the complete container lifetime or CUDA peak.
The pinned image is
`sha256:d28f698d99e514b5c8dc5d682fa126507a27901ec016cb1f0795b83ac426bfca`;
trainer, config, manifest, N2 bundle and runtime hashes are in the helper
result. A subsequent [CPU-only single-generation audit](../output/spark-runtime-20261024/native-bones-catalog/runs/native-bones-catalog-20261024-a-readback/stdout.log)
reports `verification_passed=true` and
`generation.held_state_attestation_verified=true`, with shared digest
`d08bbd58f6811d1d21ae22c71cce33cb0daebfcf5a082f6407dd4bb3cd5ec33a`.
Its `comparison_performed=false` and `rank_local_state_compared=false` explicitly
exclude independent-run or rank-local comparison. The [readback container](../output/spark-runtime-20261024/native-bones-catalog/runs/native-bones-catalog-20261024-a-readback/docker-final.json)
used an 8 GiB, two-CPU, no-network/no-GPU envelope and exited 0 without OOM.
This is one sampled update over an available full catalog, neither a
full-catalog epoch nor convergence or exact reproduction of the paper's motion
set. Further scale details are in [Native BONES readiness](NATIVE_BONES_SCALE_READINESS.md).

## N4 real-graph export and selected-world gate, 2026-10-24

The first N4 export attempt is retained: in a network-disabled container the
official ground USD was unavailable, so [attempt a](../output/spark-runtime-20261024/native-apic/n4-validation/runs/apic-n4-20261024-a/export-evidence/summary.json)
failed at startup with exit 1, without OOM. It was an asset-access failure,
not a four-graph or numerical result. In attempt b, the
[real four-graph export](../output/spark-runtime-20261024/native-apic/n4-validation/runs/apic-n4-20261024-b/export-evidence/summary.json),
[independent SDK oracle](../output/spark-runtime-20261024/native-apic/n4-validation/runs/apic-n4-20261024-b/oracle-evidence/summary.json),
and [native GPU replay](../output/spark-runtime-20261024/native-apic/n4-validation/runs/apic-n4-20261024-b/replay-evidence/summary.json)
all exited 0. The [v2 replay report](../output/spark-runtime-20261024/native-apic/n4-validation/runs/apic-n4-20261024-b/replay-report-v2.json)
records genuine GPU operations without a fake adapter, 27 tape operations,
eight simulated steps and selected worlds 0, 2 and 3. Its executed trace
passes the retained component-wise oracle tolerance
`1e-5 + 1e-5*abs(reference)`; no global physical equivalence is claimed.
The earlier N2 SDK/native numerical discrepancy remains unresolved.

The N4 bundle manifest SHA-256 is
`2f9e0a8d8f33f21388c512603240ca82b89bc54e98a0e9d2a98bbf92fcaa0249`;
the SDK oracle SHA is
`61a102a292e807639356b035e7db04a8e8d03d8798d76e973435b8bef5b99984`
and the tape SHA is
`b29d73f38785a86bbb511e3b7e37039687a2f72ab77d27da49ba323709fa73ce`.
The verified native adapter SHA is
`6c5df912291754b37ac2c60a0b0c13253d2486e87c42ca20fb0ad19e910099e1`;
the pinned N4 config SHA is
`18f93c16d7ed0c9a35e1c4de5f2cf7a2ecfccb06d0090f5000b86a1293dd7d47`.
Observed cgroup kernel peaks were 2,500,571,136 bytes during export,
1,290,264,576 during oracle generation and 294,580,224 during native replay.
Each is a bounded observation before helper exit, not a certified full-lifetime
or GPU allocation peak.

## N8 real-graph export and selected-world gate, 2026-10-24

The [N8 export](../output/spark-runtime-20261024/native-apic/n8-validation/runs/apic-n8-20261024-a/export-evidence/summary.json),
[independent SDK oracle](../output/spark-runtime-20261024/native-apic/n8-validation/runs/apic-n8-20261024-a/oracle-evidence/summary.json)
and [native replay](../output/spark-runtime-20261024/native-apic/n8-validation/runs/apic-n8-20261024-a/replay-evidence/summary.json)
all exited 0 with no observed OOM. The [executed v2 trace](../output/spark-runtime-20261024/native-apic/n8-validation/runs/apic-n8-20261024-a/replay-report-v2.json)
used genuine GPU operations and no fake adapter. It passed all retained oracle
checks at `1e-5 + 1e-5*abs(reference)` over 27 operations, eight simulated
steps and selected worlds 0, 4 and 7. This is a fixed trace, not a global
physics-equivalence claim; the older N2 numerical gap remains unresolved.

The verified N8 bundle manifest SHA-256 is
`c69596c587dc544ffdd5ff11e6f65ed5c6b0b8c671e443a6760b7b5d4c5120f2`,
the tape SHA is
`5df4db1e645c1183e91031ae99cd78c3f539657d60e964853cafe76ab2156483`,
the SDK oracle SHA is
`1a943fefb192ccbc2e876b8f227bc33b6a6bb7d34a3970053bba256cdedab2e1`,
and the N8 config SHA is
`3a074a70152d82c44abc9e962d9659f844240017f8e6924e7bba68b9c368dbbc`.
The verified native adapter SHA remains
`6c5df912291754b37ac2c60a0b0c13253d2486e87c42ca20fb0ad19e910099e1`.
Observed kernel cgroup peaks were 2,506,366,976 bytes during export,
1,287,196,672 during oracle generation and 294,649,856 during replay.
Each is scoped to measurement before helper exit and does not certify
full-lifetime host or CUDA memory. The N4 combined learner gate below has
subsequently executed one update. N8 learner training, full-versus-split GPU
numeric comparison, combined BONES training and memory-saving benchmarks
remain outstanding. The [individual CPU validation scopes](NATIVE_BONES_SCALE_READINESS.md#真正论文规模仍需独立完成的工作)
do not change the existing admission guard.

## N128 real-graph export and selected-world gate, 2026-10-24

On 179, the [N128 four-graph export](../output/spark-runtime-20261024/native-apic/n128-validation/runs/apic-n128-20261024-a/export-evidence/summary.json),
[independent SDK oracle](../output/spark-runtime-20261024/native-apic/n128-validation/runs/apic-n128-20261024-a/oracle-evidence/summary.json)
and [native GPU replay](../output/spark-runtime-20261024/native-apic/n128-validation/runs/apic-n128-20261024-a/replay-evidence/summary.json)
each exited 0; the corresponding Docker records show `OOMKilled=false`.
The [executed v2 replay report](../output/spark-runtime-20261024/native-apic/n128-validation/runs/apic-n128-20261024-a/replay-report-v2.json)
records 27 operations, eight simulated steps per world and selected worlds
0, 64 and 127. Genuine GPU operations ran without a fake adapter; the selected
trace passed the retained component-wise SDK tolerance
`1e-5 + 1e-5*abs(reference)`. Its explicit
`known_sdk_numerical_gap_unresolved=true` preserves the earlier N2 mismatch;
these three selected worlds do not establish global physics equivalence.

The verified [N128 bundle manifest](../output/spark-runtime-20261024/native-apic/n128-validation/runs/apic-n128-20261024-a/g1-128env-apic/manifest.json)
SHA-256 is `bcca38b63ba4fe8f933a8c808ec94092630d30bccbbfae89fb4b41dddbf95774`;
the [oracle](../output/spark-runtime-20261024/native-apic/n128-validation/runs/apic-n128-20261024-a/sdk-oracle-v2.json)
and [tape](../output/spark-runtime-20261024/native-apic/n128-validation/runs/apic-n128-20261024-a/tape-v2.json)
SHA-256 values are `33948f9d9b73be0210d6af92038af6d448fea140ceea060819cbfaa9500c62f0`
and `efe16a98b14ee105b353b550471736ece39ccd028a1194050e7e35d0dcbaa768`.
The pinned [export config](../output/spark-runtime-20261024/native-apic/n128-validation/examples/learning/g1-apic-export-128env.json)
SHA-256 is `8de33bdb05f0bfdfc39b41f57e4cb921594440023c40e9145ac9d9510fce8d22`.
Export, oracle and replay summary snapshots observed kernel cgroup peaks of
2,523,426,816, 1,303,838,720 and 304,701,440 bytes, respectively, with no
OOM-kill. They were recorded before helper exit and do not certify full
container-lifetime or CUDA allocation peaks. This section records the N128
physics artifact and fixed trace; the separate small-catalog learner gate is
documented below.

## N4 bounded learner combination gate, 2026-10-24

On 179, the [training report](../output/spark-runtime-20261024/native-bounded-n4/runs/native-bounded-n4-training-20261024-a/train/report.json)
records one real CUDA/APIC iteration with 40 LAFAN1 motions, four physical
environments, logical world and actor batches of four, world/actor
microbatches of two, compact live replay and bounded reference gather. It
performed 72 physical and 128 imagined transitions, one world update, one
actor update and four critic updates, then wrote stream-v2 generation
`generation-1-1792799415522`. The pinned trainer SHA-256 is
`1dd7a5f95017e3865489dbb65cec490934a82c87acaac5da7aad11fe971c4c27`;
the genuine N4 artifact SHA is
`2f9e0a8d8f33f21388c512603240ca82b89bc54e98a0e9d2a98bbf92fcaa0249`.
The [fixed config](../output/spark-runtime-20261024/native-bounded-n4/examples/learning/g1-native-tensor-apic-n4-microbatch-gate.json)
and report retain logical versus microbatch values separately.

The [Docker result](../output/spark-runtime-20261024/native-bounded-n4/runs/native-bounded-n4-training-20261024-a/docker-final.json)
records exit 0, `OOMKilled=false`, a 48 GiB no-extra-swap limit and four CPUs.
The [external read-only monitor](../output/spark-runtime-20261024/native-bounded-n4/runs/native-bounded-n4-training-20261024-a-memory/final-summary.json)
observed kernel `memory.peak=2,598,105,088` bytes with zero OOM events; it does
not certify a complete-lifetime peak or CUDA allocation peak. A subsequent
[CPU-only single-generation readback](../output/spark-runtime-20261024/native-bounded-n4/runs/native-bounded-n4-training-20261024-a-readback/stdout.log)
reported `verification_passed=true` and
`generation.held_state_attestation_verified=true`, with shared digest
`f477ca3d98165bdfeed63f2da3c2548ac93b46840cc62d5f9db5e6cc17504da7`.
Its [container](../output/spark-runtime-20261024/native-bounded-n4/runs/native-bounded-n4-training-20261024-a-readback/docker-final.json)
used 8 GiB, two CPUs and no GPU, and exited 0 without OOM. The audit records
`comparison_performed=false` and `rank_local_state_compared=false`.

This verifies one combined execution and saved-state readback. This single-rank
gate by itself is not a full-versus-split GPU numerical comparison, a
memory-saving benchmark, a BONES catalog combination run, or convergence
result; the later [two-host N4 gate](DGX_SPARK_CONNECTX7_RDMA.md#bounded-n4-microbatch-two-host-gate)
has separate evidence. The retained N2 SDK/native numerical gap is unaffected.

## N128 LAFAN1 learner gate, 2026-10-24

On 179, the [N128 training report](../output/spark-runtime-20261024/native-n128-lafan/runs/native-n128-lafan-20261024-a/train/report.json)
records one real APIC GPU-physics and Float32 CUDA-learner iteration over the
fixed **40-motion LAFAN1** catalog. It used SMC99 observations, 128
environments, logical world/actor batches of 128 and microbatches of 16, with
compact replay and bounded gather. Its 8,448 physical transitions and 4,096
imagined transitions produced ten world-model, one actor and 20 critic update
operations, using 10,240 model-fit transition slots. It saved stream-v2
`generation-1-1792801245453` with catalog_count=40. The
[helper result](../output/spark-runtime-20261024/native-n128-lafan/runs/native-n128-lafan-20261024-a/inside-summary.json)
binds the trainer SHA
`1dd7a5f95017e3865489dbb65cec490934a82c87acaac5da7aad11fe971c4c27`,
the [N128 config](../output/spark-runtime-20261024/native-n128-lafan/examples/learning/g1-native-tensor-apic-n128-scale-gate.json)
SHA `6913ba684c3f07b0398665668e9c3b3773ecdc89accd4cf4cfa50522c1aa2643`
and the real N128 artifact SHA above. Both preflight and training exited 0;
its reported 42.019 seconds is the bounded helper's training run, not a
multi-iteration throughput measurement.

The [container result](../output/spark-runtime-20261024/native-n128-lafan/runs/native-n128-lafan-20261024-a/docker-final.json)
records exit 0 and `OOMKilled=false` under 64 GiB, four CPUs and no extra
swap; the unchanged 65% admission guard and 24 GiB physics reserve passed
initially and after catalog loading. The [read-only monitor](../output/spark-runtime-20261024/native-n128-lafan/runs/native-n128-lafan-20261024-a-memory/final-summary.json)
observed kernel `memory.peak=2,325,794,816` bytes and zero OOM event
increments before helper exit. It does not certify a complete container-life
or CUDA allocation peak. A separate [CPU-only archive readback](../output/spark-runtime-20261024/native-n128-lafan/runs/native-n128-lafan-readback-20261024-a/stdout.log)
reports `verification_passed=true` and
`generation.held_state_attestation_verified=true` with shared digest
`2d4897a5009f6781c9118ca9b199acd6223f315726ed12318680c4c47d4ae7ae`.
Its [container](../output/spark-runtime-20261024/native-n128-lafan/runs/native-n128-lafan-readback-20261024-a/docker-final.json)
exited 0 under 8 GiB and two CPUs without GPU or network. The audit did not
compare a second archive or rank-local state. This is a one-iteration N128
engineering gate on LAFAN1; the separate BONES full-catalog N128 result is
below. It is not the paper's 4,096-environment run, convergence, exact physics
resume or SDK numerical equivalence.

## N128 BONES full-catalog learner gate, 2026-10-24

On 178, the [BONES N128 helper result](../output/spark-runtime-20261024/native-bones-n128/runs/native-bones-n128-20261024-a/inside-summary.json)
records successful preflight and training over all 137,289 accepted clips in
the **partial** BONES filter set. The [final loader progress](../output/spark-runtime-20261024/native-bones-n128/runs/native-bones-n128-20261024-a/trainer.stdout.log)
records 137,289 source files and shards verified, totaling 87,996,168,100
source bytes and 30,779,167,040 shard bytes; no new shards were built and
file-specific cache advice reported zero failures. The
[training report](../output/spark-runtime-20261024/native-bones-n128/runs/native-bones-n128-20261024-a/train/report.json)
records one sampled iteration with real N128 APIC GPU physics and the Float32
CUDA learner: 8,448 physical transitions, 4,096 imagined transitions, ten
world-model updates, one actor update, 20 critic updates and 10,240 model-fit
transition slots. It saved stream-v2 `generation-1-1792801872635` with
catalog_count=137,289. The pinned config SHA is
`abf1faf223cdb464da4ef0d6b4ee22c0d43e94bbf8f1bac1195959f42accb7ff`;
the partial manifest SHA is
`64c21768fd7f2fad74d06153b1ada1faa958520abb8b234baa29d455572eb383`.

The [Docker result](../output/spark-runtime-20261024/native-bones-n128/runs/native-bones-n128-20261024-a/docker-final.json)
records exit 0, `OOMKilled=false`, a 64 GiB/no-extra-swap cap and four CPUs.
Its roughly 11-minute-25-second wall interval includes full-catalog hashing
and loading; it is not a training-only throughput measurement. The
[read-only memory monitor](../output/spark-runtime-20261024/native-bones-n128/runs/native-bones-n128-20261024-a-memory/final-summary.json)
observed `memory.peak=2,678,452,224` bytes and zero OOM increments before
helper exit. The 65% admission guard and 24 GiB physics reserve remained
active; this observation is not a full container-lifetime or CUDA peak. An
independent [CPU single-archive readback](../output/spark-runtime-20261024/native-bones-n128/runs/native-bones-n128-readback-20261024-a/stdout.log)
passed schema, file and held-state checks with shared digest
`8ae0d48ce07045fa95f02ed71bc891eb160227b9493a59ffd7e5bea85e9a7618`.
It did not compare a second generation or rank-local state. This gate is one
sampled update over an available full catalog, not an epoch, the paper-exact
129,514-motion set, convergence or exact APIC resume.

The separate [full-vs-split GPU numerical comparison](../output/spark-runtime-20261024/native-microbatch-numeric/runs/native-microbatch-numeric-20261024-a/microbatch/comparison.json)
**failed** its fixed `atol=2e-6`, `rtol=2e-4` criterion. Initial input/state
identity was exact; of 234,377,294 compared values, 27 exceeded tolerance,
all in critic-0 `kind0` weights after two actor update phases (11 then 16).
World phases and actor probes had no out-of-tolerance values. The cause is
under investigation; the result does not establish full-vs-split numerical
equivalence or memory savings.

## Bounded writer and solver diagnostics, 2026-10-24

The [SDK diagnostic](../output/spark-runtime-20261024/native-apic/runs/apic-sdk-diagnostic-20261024-a/sdk-diagnostic.json)
and [native diagnostic](../output/spark-runtime-20261024/native-apic/runs/apic-replay-diagnostic-20261024-a/diagnostic-report.json)
both completed the same 20-operation, eight-step tape on 179 with exit 0.
The [derived analysis](../output/spark-runtime-20261024/native-apic/diagnostic-analysis-20261024-v2.json)
and [bounded MoonBit analysis script](../output/spark-runtime-20261024/native-apic/analyze-apic-diagnostic-v1.mbtx)
record the six retained trace hashes and all 15 pairwise comparisons. They
reuse the original bundle and the unchanged component-wise tolerance
`1e-5 + 1e-5*abs(reference)`; no earlier failed trace is replaced.

The eight SDK probes compare the original scene writer with the lowered
implicit writer before advancing physics. All 56 array checks are exactly
equal. Each probe first poisons the three real 2-by-29 backend control arrays
with finite values different from every original output slot: 1,392 output
slots across eight probes are independently overwritten and verified. User
commands, staging inputs, physical readback and the available solver arrays
remain unchanged between writers; original controls are restored and read
back before the original SDK physics step. This rules out an observed missing
or numerically different write in the tested stateless implicit fixture.
It is not a test of arbitrary actuator types or hidden native graph outputs.

Native readback passes all 38 exact input checks with zero error, covering
both worlds' step targets, reset masks and selected reset rows. Unselected
reset rows are unused scratch storage and are not asserted equal. The 340
physical comparison checks for the new diagnostic pair also pass, with a
maximum absolute difference of `1.56164169e-5`. The distinction between
unchanged input and unchanged output is retained: the old native bundle has
no named backend-control or solver-internal diagnostic views.

| Retained comparison | Maximum absolute difference | Original component-wise rule |
| --- | ---: | --- |
| Native a versus untouched SDK a | `1.85966492e-5` | Fails |
| Native b versus untouched SDK a | `1.77025795e-5` | Fails |
| Diagnostic native versus diagnostic SDK | `1.56164169e-5` | Passes |
| Diagnostic SDK versus untouched SDK a | `1.93119049e-5` | Fails |
| Diagnostic SDK versus untouched SDK b | `2.21729279e-5` | Fails |
| Diagnostic native versus untouched SDK a | `2.33650208e-5` | Fails |
| Diagnostic native versus untouched SDK b | `1.12056732e-5` | Passes |

The instrumented SDK retains the same source/asset/bridge identity but performs
extra control writes and host readbacks. The diagnostic native adapter is a
new build adding readback access. These are additional observations, not
identical-schedule repeats. In particular, the diagnostic SDK's differences
from the untouched SDK traces cannot be attributed solely to run-to-run
nondeterminism or used to discard their failures. Both original within-path
repeat comparisons still pass their original checks. **Physical equivalence
remains unverified**, including when the new diagnostic pair passes.

Every retained comparison first differs in raw physical views at step 5,
world 1. The SDK now supplies real control-boundary `nacon`, `nefc`,
`solver_niter`, `qacc`, `qacc_warmstart`, `qfrc_constraint`, `qpos` and `qvel`.
At the step-4 boundary, `nacon=0`, `nefc=[0,0]` and `solver_niter=[1,1]`.
At step 5, these become `8`, `[0,32]` and `[1,2]`, respectively: the observed
divergence coincides with active constraints in world 1. This narrows the
investigation beyond the tested input/reset/writer mappings, but does not
prove an atomic-reduction cause. Native solver arrays and the four individual
0.005-second substep boundaries remain unavailable in this bundle; neither
solver warm-start parity nor the first differing internal operation is known.
The 71-component robot state is not a solver-state checkpoint.

The read-only memory monitors observed kernel peaks of `1,530,707,968` bytes
for the SDK diagnostic and `463,663,104` bytes for native replay, with zero
observed OOM counters and `OOMKilled=false`. Both cgroups disappeared before
the final poll, so neither summary certifies the complete lifetime peak.
This analysis itself reads bounded local files only and performs no GPU,
remote, training or robot-hardware operations.

## Source provenance and import identity

The existing remote `IsaacLab` source archive deliberately omitted `.git`.
The image's installed Newton wheel also lives outside a clean Git checkout.
Neither satisfies the producer's checks: both exact `git rev-parse HEAD` and
`git diff --quiet HEAD --` must pass, and canonical imported module paths must
be inside the verified roots. Writing a commit string into a fabricated Git
directory would not establish the source identity.

The local `target/isaaclab-source` contains a genuine clean shallow checkout.
The earlier offline dependency package contains a verified Newton bare mirror.
[`prepare_apic_sdk_sources.mbtx`](../scripts/prepare_apic_sdk_sources.mbtx)
uses local Git transport, with network protocols and lazy object fetch disabled,
to create fresh shallow checkouts containing authentic Git objects. It checks
commit, tree, complete cleanliness, absence of unprepared submodules and
`git fsck`, then archives the checkouts including their actual `.git` metadata.
It never synthesizes a commit or changes the original repository.

| Source | Commit | Tree |
| --- | --- | --- |
| IsaacLab | `46d6cc3d7b115906fad12efd372fbf69f4e3d3ed` | `09dbeafdd81fe301d8dfbafd8206cc8e3c4ff0df` |
| Newton | `71eeba16a717d4dcf0b9dd7056a7b6f863054dc3` | `ad1a81948b2a9e80c1a318c83f915a40ccd72860` |

Actual local preparation passed. The output is
`output/apic-sdk-checkouts-20261024-a/sdk-checkouts.tar.gz`, SHA-256
`a8f28d54661892e8ce9f5ef37b1af2990a89986530f15a108e9343d9e3fc7d25`;
the adjacent `provenance.json` records the source paths and checks. The Isaac
`uv.lock` remains
`44534d4d3c84575686e1f31f192a5ab3c21612c6f8db6da43fa1b56a2b79535e`.
To prepare another fresh package:

```bash
moon run --target native scripts/prepare_apic_sdk_sources.mbtx \
  /Users/kq/Workspace/moonrobo/target/isaaclab-source \
  /Users/kq/Workspace/moonrobo/output/isaaclab-offline-git-20261024-v2/offline-git/newton.git \
  /Users/kq/Workspace/moonrobo/output/apic-sdk-checkouts-NEW
```

## CPU-only authoring bridge build

[`Dockerfile.spark-apic-authoring`](../docker/Dockerfile.spark-apic-authoring)
derives from the validated local tag `moonrobo-isaaclab:46d6cc3-kitless-rdma`,
whose exact image ID is checked before and after the build:
`sha256:989985f4b65447e4452fcfeeec70cfa3f48eb52637f8f96e41a736f11ab308cd`.
Docker `FROM` accepts an image reference, not an image-config ID; using the
bare `sha256:...` here incorrectly attempts a registry pull. The helper uses
the verified local tag with `--pull=false` and records both tag and ID.
Only its build stage installs g++, CMake, Make and Python 3.12 development headers,
then builds the existing reference C++ bridge against the same system Python
3.12 ABI used by the pinned venv. No SDK import or GPU action occurs during
the build. OS build-package versions and source/plugin hashes are retained;
this does not change `uv.lock` or resolve a new Python package graph.

The pinned base's `Dockerfile.kitless` requests `libpython3.12`; Ubuntu 24.04
provides it through the installed `libpython3.12t64` package. A version query
against the virtual name can return empty, so the derived build requires the
real provider's installed status and version. It selects `python3.12-dev` and
`libpython3.12-dev` at the exact versions of the base interpreter and shared
runtime, then checks that installation did not change their versions or
binary hashes. Missing repository copies of those exact headers stop the
build. The final image checks the same package versions and SHA-256 values
for `/usr/bin/python3.12` and
`/usr/lib/aarch64-linux-gnu/libpython3.12.so.1.0`, then checks every bridge
relocation with `ldd -r`. Runtime package versions, hashes and linkage output
are retained under `/opt/moonrobo/apic-authoring/`. No `LD_LIBRARY_PATH`
override or replacement libpython is introduced.

The final image retains the original IsaacLab and installed Newton module
trees in `/opt/moonrobo/original-sdk/`, plus a compressed archive and its
SHA-256. It replaces their old import locations with symlinks to the verified
checkouts under `/opt/moonrobo/sdk/`. This is necessary because the embedding
bridge puts `site_packages` first: setting `PYTHONPATH` alone may still import
the installed Newton wheel. The existing editable IsaacLab paths continue to
resolve through `/workspace/isaaclab` to the genuine clean checkout. Git's
system safe-directory list grants only those two root-owned image paths so
the ordinary training account can inspect them; it does not grant `*` or
relax clean-source checks.

After copying the prepared archive, its provenance and the three new source
files to the host, run the build helper there. For example, with actual paths:

```bash
moon run --target native scripts/build_spark_apic_authoring.mbtx \
  /home/wlc004s/moonrobo \
  /home/wlc004s/moonrobo/apic-sdk-checkouts-20261024-a \
  /home/wlc004s/moonrobo/apic-authoring-build-20261024-a \
  20261024-a
```

The helper verifies the archive hash and existing base-image ID, refuses an
existing context or output tag, and builds
`moonrobo-isaaclab:46d6cc3-kitless-apic-20261024-a` with 8 GiB build memory,
equal memory/swap cap, two-CPU quota and one compiler job. The MoonBit helper
requires `moonbitlang/async@0.22.5`. Logs and final image identity remain in
the fresh context. The actual authoring image build passed on 179, including
the runtime-library identity and linkage checks, with image ID
`sha256:3f0487da0faaf353f14c43c8a135efad70c8a988e7735bba6b991fef0e50899c`.
The final build uses the installed `libpython3.12t64` provider, explicitly
installs Make, and changes out of `/workspace/isaaclab` before preserving and
replacing that source directory. Use a fresh context/tag for any rebuild.

The plugin path is
`/opt/moonrobo/apic-authoring/libmoonrobo_apic_authoring.so`. Build the MoonBit
`cmd/reference_apic_export` native executable with matching pinned MuJoCo
3.15.0 headers in `CPATH`, as for the native learner, without running it.
The bridge needs no CUDA toolkit or NVCC at compile time; actual SDK capture
later needs the GPU and the installed Warp compiler/runtime dependencies.

## Exact two-environment recipe and remaining execution gates

[`g1-apic-export-2env.json`](../examples/learning/g1-apic-export-2env.json)
selects the pinned interpreter and verified source roots, the already converted
USD with all eight adjacent payloads, `usd_variants={"Physics":"mujoco"}`,
device 0, two worlds
and `self_collisions=false`. Its fresh output is `/gate/g1-2env-apic`.
The actual staged USD has a `Physics` variant set with `mujoco`, `physics`
and `physx` alternatives and no default selection. Its MuJoCo variant must
be selected explicitly, matching the preserved Python robot configuration.
An empty variant map was incorrect for this asset: the SDK could not find
the expected robot articulation. Do not change the asset to hide that error.
The source MJCF identity is the actuator-equipped
`scene-no-self-collision.xml`, SHA-256
`34cf0cf3c5fa5452fc24d33d9f31fb4a4435f3050366041e1dc853b39bdd20ee`,
which the native learner must also pass as `--scene`. The raw G1 MJCF used
for the earlier USD conversion remains separately preserved; its lack of
actuators makes it unsuitable as the native learner's control scene. The
manifest's MJCF hash binds the selected kinematic/control input and must not
be represented as a new USD conversion receipt.

The fixed producer configures implicit joint actuators from the shared G1
motor table, `njmax=500`, `nconmax=128`, pyramidal contacts, implicit-fast
integration, four 0.005-second substeps and a 0.02-second control interval.
It verifies actual joint ordering, default pose, single-state manager behavior,
the supported actuator path and imported SDK versions before capture. The required
outputs are `step.wrp`, `reset.wrp`, `context.wrp`, `refresh.wrp`, their real
module/mesh payloads and `manifest.json`; single-kernel native fragments are
not substitutes. Unknown persistent opaque memory or unsupported capture
must remain a failure, not be replaced with a synthetic graph.

Each GPU invocation remains separately bounded by the controller:
read-only repository/assets, a fresh writable `/gate`, the exact authoring
image and executable, a 16 GiB initial cgroup cap and a finite timeout. Start
with the two-world recipe only and inspect available CUDA memory immediately
before running. A build or `runtime_validated=false` manifest is not physical
validation. Preserve any capture failure before deciding whether an SDK
assumption needs a source correction.

The first bounded attempt reported an invalid USD default prim. Holding the
opened `UsdStage` alive through validation fixed that failure: MoonBit's
last-use release had removed the owning Stage while a weak Prim handle
remained. The next attempt reached actual SDK scene initialization and
exposed the missing `Physics=mujoco` selection described above. The corrected
variant configuration reached the real solver. Its diagnostic confirmed
single state, four substeps, decimation one, update interval one, CUDA solver
and `solver_dt=0.005`; `_is_all_graphable()` was false.

That result follows the pinned SDK's plain implicit-actuator path. Its
`prepare_native_actuators` returns before activating the native adapter when
all groups are implicit, and `_is_all_graphable` requires that activation.
The ordinary manager then runs `_simulate_physics_only` after the scene has
written actuator commands. The producer now accepts this separate path only
after checking 29 exact `ImplicitActuator` objects with one joint each, zero
fixed tendons, no eager execution groups or native groups, the real fused
implicit executor, no manager adapter, inactive native-actuator flags, and
empty pre/post actuator callback lists. It does not change any SDK flags.
The captured step remains target assignment, complete scene command submission
(including its Warp implicit-actuator kernel), then the original
`_simulate_physics_only()`. The SDK's post-step callbacks and sensor updates
remain inside that operation; nonempty post-step callbacks are permitted and
their count is recorded. Capture order remains step, reset, context, refresh.

The manifest records the selected `step_method` and the checked
`all_implicit_capture` fields. This path declares both
`uncaptured_manager_simulate_full=false` and `includes_actuator_adapter=false`.
The consumer accepts it only with the complete proof and rejects missing or
contradictory fields. Older full-path manifests retain their existing strict
contract. Local native compilation and eight consumer tests passed, including
legacy decoding, roundtrip of the implicit path with a post-step callback,
and rejection of skipped actuator work.

The next two bounded attempts reached capture and identified a genuine Warp
1.17 APIC limitation at `step -> scene.write_data_to_sim`: its
`NewtonActuatorControl.submit_commands` identity-order branch calls `.assign`
on the actual strided control arrays. `.assign` calls `wp.copy`, whose native
non-contiguous CUDA helper is not recorded by APIC. The official alternative
already exists in the same SDK:
`ordering_kernels.launch_reorder_joint_targets_user_to_backend` launches a
recorded Warp kernel and accepts those original strided views. The producer
now calls that kernel with the actual `_joint_backend_to_user_map()`; for
identity order, the SDK returns its real `_ALL_JOINT_INDICES` array. It checks
all six source/destination arrays are actual N-by-29 float32 Warp arrays and
the map has 29 int32 elements. It neither clones output buffers nor changes
the SDK's joint-ordering flags.

The explicit MoonBit composition preserves the pinned scene writer order and
calls every other scene asset's original writer. For the validated robot it
retains the original wrench-composer handling and official wrench kernels,
actuator `compute`, target kernel, conditional coordinate scatter and dirty
tendon submission in their original order. Only the three `.assign` copies
are replaced. The manifest truthfully sets
`scene_write_data_to_sim_included=false` and requires a complete
`command_submission` contract naming the official kernel and retained
operations. Consumer tests reject any omitted operation or contradictory
original-writer claim. A subsequent bounded run passed the step capture;
local compilation or contract tests alone did not establish that result.

The following bounded attempt passed the step capture and stopped in the
root-pose reset writer with `Tensor has no attribute ptr`. The provided pose
and environment mask were Warp arrays; the pinned API instead passed its
`ProxyArray` output directly to `wp.launch`. Ordinary Warp launch understands
the proxy's CUDA array interface, but the APIC pointer walker reads the
original object's `ptr`. ProxyArray forwards that unknown attribute to its
Torch view. The root COM velocity writer exposes the same issue. The producer
now invokes the identical official root-mask kernels with their actual
`.warp` output owners, retaining mask resolution, shape assertions,
nonfloating-root model notification and `_reset_pose`/`_reset_velocity`
invalidation. Joint writers, selected-world solver reset, forward update and
capture order remain intact. The manifest adds descriptive reset-binding
provenance without changing the existing consumer schema. Run h then passed
reset, context and refresh capture and saved the complete genuine bundle.

## Independent eager SDK oracle

The explicit `trace-sdk` subcommand executes the deterministic two-world
audit tape through the original SDK without any APIC capture or graph replay:

```bash
reference_apic_export trace-sdk CONFIG.json TAPE.json BUNDLE/manifest.json ORACLE.json
```

The focused `cmd/reference_apic_export_legacy` executable accepts the same
`trace-sdk` arguments and avoids linking the unrelated experimental producer
packages during native compilation. The full command remains available.

The initial implementation accepts only the actual emitted 20-operation,
8-step v1 tape, SHA-256
`cb4ffbf27aac69d5b539484f85d94273252f1496d5df9796b8c9f4564a1db860`.
It requires a fresh output file, exactly two worlds, and matching bundle
assets, variant selections, collision mode and verified SDK revisions/import
paths. `step` calls original `InteractiveScene.write_data_to_sim` and
`SimulationContext.step`; reset calls the original public mask writers,
including their ProxyArray outputs, outside capture. It never calls the
new target-copy composition or root-reset lowering. Context writes use the
actual SDK model arrays and original solver notification/forward operations.
The trace records Tier-1 root/joint arrays, model COM/friction values and the
71-component state after every operation, bound to the exact manifest and
tape hashes. This independently tests the APIC substitutions rather than
using their implementation to manufacture expected results. The command
requires the same bounded GPU deployment controls as export; compilation
does not execute it, and an oracle file is produced only after real SDK work.

After genuine export, the runtime adapter must be built from
`src/learning_aligned/native/aot_solver.cpp` using actual CUDA 13 driver
headers and matching Warp 1.17 native headers/library. The original CMake
route remains available: it requires `MOONROBO_WARP_APIC=ON`, a discoverable
CUDA toolkit/driver link library and matching MuJoCo inputs for its additional
USD target. The new APIC-only route below avoids those unrelated build
requirements. GPU replay may still need Warp's native NVRTC/cache dependencies
but does not load the authoring bridge or CPython.

Finally run artifact/hash inspection, actual four-graph loading, masked-reset
isolation, context-write/readback and short physical differentials before
feeding the native CUDA learner. Match `num_envs=2`, MJCF hash, collision
setting, device and four-substep contract. These checks establish a different
boundary from the already passing CUDA learner with CPU MuJoCo physics.

## Standalone native replay build

The validated RDMA image was inspected on 179 and contains these actual files
under `/opt/isaaclab-venv/lib/python3.12/site-packages/`:

- `nvidia/cu13/include/cuda.h` from locked `nvidia-cuda-runtime==13.0.96`;
- `warp/native/apic.h` and the Warp 1.17 native headers;
- `warp/bin/warp.so` from locked `warp-lang==1.17.0`.

The runtime wheel contains libcudart but no CUDA driver linker stub. The
standalone [CMake target](../src/learning_aligned/native/apic_runtime/CMakeLists.txt)
compiles the same adapter with an optional, typed
[CUDA Driver loader](../src/learning_aligned/native/apic_runtime/cuda_driver_dynamic.h).
Every one of its 15 driver function pointers uses `decltype` from the real
`cuda.h`; symbol names expand the SDK's versioned aliases before lookup.
It loads the host's injected `libcuda.so.1` on first `mr_apic_open`, without
copying a host driver into the image or manufacturing headers/link stubs.
The original direct-link build path is unchanged. Missing driver/symbols
become explicit runtime-open errors.

The CUDA header SHA-256 is checked against
`64025f81a9d6d2b10e9e11654f3523e5b046d01b883f0b9ca474e463274b80d4`.
This was independently obtained from the official NVIDIA aarch64 wheel in
the unchanged `uv.lock` (wheel SHA-256
`ef9bcbe90493a2b9d810e43d249adb3d02e98dd30200d86607d8d02687c43f55`).
Compilation also requires `CUDA_VERSION=13000`, Warp version `1.17.0` and
APIC format `15`. The runtime continues to call `wp_init("1.17.0")`.

[`Dockerfile.spark-apic-runtime`](../docker/Dockerfile.spark-apic-runtime)
adds a CPU-only compiler stage, links the existing Warp binary and `libdl`,
records hashes/package versions/ELF dependencies, and copies only the adapter
and receipts into a fresh final image based on the unchanged RDMA image.
The wheel binary is named `warp.so` and has no SONAME; the dedicated CMake
target uses GNU ld's exact-file `-l:warp.so` form and the pinned Warp directory
as RUNPATH. It neither renames the binary nor introduces a `libwarp.so` alias.
The final stage rechecks the source dependency hashes and `ldd -r`, rejecting
missing symbols/libraries or a Python dependency. No SDK import, CUDA context
creation or graph replay runs during the build.

Use the [MoonBit build helper](../scripts/build_spark_apic_runtime.mbtx), for
example after staging its four build source files and the helper itself:

```bash
moon run --target native scripts/build_spark_apic_runtime.mbtx \
  /home/wlc004s/moonrobo \
  /home/wlc004s/moonrobo/apic-runtime-build-20261024-a \
  20261024-a
```

It verifies the RDMA tag's exact image ID before and after build, uses
`--pull=false`, an 8 GiB build memory/swap cap, two-CPU quota, one compiler
job and a 20-minute client deadline. A client timeout does not itself prove
the daemon build has stopped; retain the logs and inspect the bounded build
before retrying. A fresh context and output tag are mandatory. It leaves
the tensor and authoring images untouched. The output adapter is
`/opt/moonrobo/apic-runtime/libmoonrobo_aligned_apic.so`; all dependency hashes
must still match if the adapter is later moved to the native learner image.

Local checks passed for the helper and C++ syntax against the real locked
CUDA header and upstream Warp 1.17 headers, including expanded `_v2` driver
symbol names. The actual Linux adapter build subsequently passed on 179,
including final dependency-hash and relocation checks, producing image ID
`sha256:73afa4db4f1fa29d88c4cdba8eff94e6c914f2892b0fc969c88f6364b1202a34`.
That established compilation/linkage against the pinned native libraries.
After adding the narrow audit readback ABI, the subsequent native audit
actually loaded all four saved graphs and passed the bounded 20-operation
replay described above. The original build ID is not the newer audit image's
identity; retain each run's exact runtime-image receipt. Full training with
native GPU physics and independent SDK numerical parity are separate gates.
