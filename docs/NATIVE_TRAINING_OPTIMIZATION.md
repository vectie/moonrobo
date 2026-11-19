# Native paper training optimization, 2026-10-24

Status: all five implementation tracks are present behind explicit options.
Geometry and critic normalization have completed independent training ABBA runs;
gradient buckets have completed two-rank communication-only ABBA measurements.
Critic graph CUDA correctness gates pass, but its completed single-node training
ABBA shows no stable throughput benefit and the option remains off. Native
LayerNorm fails the fixed CUDA numerical gate. No candidate is automatically
promoted, and all Python and native reference paths remain available for
comparison. The measured graph route captures only critic forward/backward;
world-model and actor graph capture are outside this result.

The authorized order is: (1) timing breakdown, repeated-computation removal and
native LayerNorm in parallel; (2) bounded graph replay; (3) cross-parameter
communication buckets, followed by overlap only if readiness/event dependencies
are implemented and measured. Python and the native reference paths stay intact.

## Frozen reference and comparison scope

The historical N256, self-collision-on, LAFAN40 reference uses logical WM2048 /
actor4096, WM microbatch2048 / actor microbatch512, Paper93 observations,
FP32 with explicit TF32 permission, 8-step world fitting and 32-step imagination.
Iterations 2–10 averaged 0.540 s collection, 1.809 s world updates and 4.555 s
actor/critic: 6.904 s total excluding initialization and checkpoint publication.
Evidence: `output/spark-runtime-20261024/paper-wm2048-pi512-evidence-20261024-a`.
The measured trainer SHA256 is
`0be35444d53f44f01194c54eefa5facedcdb48f380d04cbc7e3501df92481853`.

New comparisons must freeze one new executable/plugin build and use its original
and candidate paths. The historical result is contextual, not the control for a
different build. N256 is a reduced physical sampling scale, not paper N4096.

## Work ownership and switches

| Work | Agent | Default / candidate |
| --- | --- | --- |
| Bounded CPU/CUDA timing and NVTX | perf_timing | off / `--execution-profile` |
| Batch-local geometry reuse | perf_reuse | `reuse_geometry=false` / true |
| Fixed-stat critic normalization reuse | perf_reuse | `reuse_critic_normalization=false` / true |
| Native affine LayerNorm | perf_layernorm | `layer_norm_mode=expanded` / native |
| Immutable paired launch/report tools | perf_pair_runner | ABBA order, separate fresh processes |
| Critic forward/backward graph replay | perf_layernorm, reviewed by perf_timing | `critic_cuda_graph=false` / true |
| Cross-parameter gradient buckets | perf_stage2_audit | `gradient_bucket_bytes=0` / 1..64 MiB |
| Configuration, admission, builds, GPU scheduling | root | one coordinated GPU workload per node |

These are execution options. They must not change reward/action/termination,
GAE, tail values, gradient clipping, optimizer step count, data selection, random
draw order, precision, update-to-data ratio or learning-rate schedule. Paper
baseline world-model-only iterations remain explicitly zero; SMC's 500 is a
separate implementation choice, not a paper requirement.

## Measurement and numerical gates

1. Test each candidate independently at fixed inputs, parameters, replay and RNG.
   Compare forward values, gradients, updated parameters, Adam moments/steps and
   running normalization. Retain failures and predeclared tolerances.
2. Add CPU submission spans and CUDA events without synchronizing every marker.
   Report nested spans as inclusive, incomplete/dropped samples explicitly and
   the fact that event elapsed time includes stream dependencies. Profiling runs
   are separate from throughput runs.
3. Run alternating baseline/candidate pairs in fresh processes from the same
   deterministic setup. Exclude warmup from steady-state timing; separately
   report startup, checkpoint, wall time, median/p90 and memory high-water marks.
4. Preserve every config, source/build identity, command, log, exit/OOM status and
   raw timing record. A failed or incomplete pair cannot count as a speedup.
5. Promote a candidate only after correctness and an end-to-end improvement that
   exceeds measurement variation. More utilized memory or GPU activity alone
   does not establish a gain. Later learning-quality evaluation remains distinct
   from execution equivalence and short throughput measurements.

## Memory and deployment limits

Keep default admission at 65%; the existing explicit 80% paper profile still
uses the minimum of host/cgroup/CUDA available memory and at least 16 GiB reserve.
UMA host and GPU memory are not additive. Preserve the physics and reference
floors and account for overlapping cache, graph-pool and staging lifetimes.
N256 paired training uses the existing 100 GiB container cap, zero container
swap and 12 CPU limit; builds have their own smaller caps. No unbounded probing,
automatic retry with larger limits, global cache eviction or concurrent benchmark
jobs. Boundary telemetry is a guard, not a mathematical OOM guarantee.

LayerNorm and graph replay must be opt-in and fail clearly if an optional plugin
capability is unavailable. Keep finite-gradient validation before any optimizer
mutation. First graph trials leave the optimizer, validation, sampling and
checkpointing outside capture. Initial communication buckets do not claim
backward/communication overlap.

## Recorded results

Original sibling SMC Python training has now been run separately on Spark 179,
without source changes: 600 iterations at N256, original BF16/torch.compile,
WM2048/actor4096 and 500 world-only warmup iterations. Full training iterations
521–600 average **1.055826 s/iteration**, with 92.36% mean sampled GPU activity;
the process exits 0 without OOM. The rough ratio against native geometry reuse
is 6.26x, but precision, observations, self-collision, physics/data execution,
actor microbatching and warmup differ. This is not a controlled language-only
comparison or convergence evidence. [Original SMC benchmark and retained logs](../output/spark-runtime-20261024/smc-original-benchmark-20261024-b/README.md).

First-stage evidence: [record and logs](../output/spark-runtime-20261024/optimization-stage1-20261024-a/README.md).
The unprofiled geometry ABBA contains four independent ten-iteration runs,
excluding iteration 1 from steady-state statistics. The same frozen build takes
7.0003 s/iteration on the original route and 6.6097 s with geometry reuse: a
5.58% time reduction (1.0591x speed ratio). Both paired comparisons improve.
The actor/critic phase decreases from 4.6195 to 4.2357 s. Separate actual CUDA
fixtures compare same-plan gradients, parameters, Adam and normalizers; the
timing summarizer deliberately does not certify whole-checkpoint equivalence.
N256/LAFAN40 throughput is not paper-scale convergence or unseen-motion evidence.

The independent critic-normalization series b also contains four complete
ten-iteration runs, with iteration 1 excluded. The original route averages
7.0119 s/iteration and the candidate 6.9206 s, a 1.30% time reduction; actor/critic
averages 4.6352 versus 4.5415 s. However, its two paired speed ratios are
0.99925x and 1.02729x: one pair is slightly slower. This small, variable gain does
not justify a default change. The same separate CUDA reuse fixtures include
normalization reuse, but do not certify all ABBA checkpoint tensors. The
normalization and geometry comparisons enable one switch each; their gains must
not be multiplied or treated as a measured combined configuration.
[Normalization summary](../output/spark-runtime-20261024/optimization-stage1-20261024-a/critic-normalization-summary.json).

Both completed first-stage training series exit successfully without Docker OOM kills.
The resource-enriched geometry summary preserves the original timing records
and adds 36 cgroup observations per run; the normalization summary uses the same
resource accounting. Observed swap and cumulative memory-limit/OOM event counters
are zero. The largest observed kernel `memory.peak` is approximately 2.292 GiB,
and minimum observed CUDA free memory is 73.46 GiB for geometry and 72.54 GiB for
normalization. These are observation-window facts: full container-lifetime peak
remains unknown, and cgroup and CUDA allocator figures must not be added as UMA
usage. The 100 GiB/zero-swap cap, 80% admission and 16 GiB minimum reserve remain.
[Geometry resource summary](../output/spark-runtime-20261024/optimization-stage1-20261024-a/geometry-summary-resources.json).

The diagnostic profile contains 45,756 complete spans, with no dropped or
unfinished spans. Actor sample preparation averages 1.503 s/iteration and the
subsequent actor/critic update 3.224 s. These are diagnostic measurements;
inclusive CUDA intervals are not GPU kernel-active time. The later NVTX3 plugin
probe passes on CUDA, but no Nsight capture has yet validated the NVTX timeline.

Native LayerNorm remains rejected by the fixed CUDA numerical gate: the first
near-constant FP32 3x4 fixture differs at forward element 0, before backward or
Adam comparison (0.0730718002 versus 0.0730461031, tolerance 0.0000166092).
The tolerance is unchanged and Expanded remains the default. This failure does
not establish a speed benefit or validate the later 2048-wide fixture.

Critic graph replay passes the actual CUDA primitive gate, the isolated native
capture-invalidating failure gate, and four-iteration learner comparisons for
full/split execution with normalization reuse on/off. The latter verifies 20
critic Adam steps per iteration, GAE/permutations, parameters, gradients and
normalizers. Two incorrect test assumptions were diagnosed and retained: a
readback rejected by ATen did not invalidate CUDA capture; world gradients are
intentionally absent after actor updates. Neither required changing production
training math. [Graph validation](../output/spark-runtime-20261024/native-critic-graph-cpu-20261024-a/validation.json).
These are separate correctness fixtures, not certification of every tensor in
the throughput runs' final checkpoints.

Graph series d now completes the full unprofiled A-B-B-A comparison on the same
N256 single-node training setup: four fresh ten-iteration processes, each
excluding iteration 1 from steady-state timing. The only candidate switch is
`critic_cuda_graph=true`; geometry reuse, normalization reuse and gradient
buckets are not combined with it. Graph preparation, warm-up, capture, replay
and teardown remain inside the measured training path, while initialization
and checkpoint publication remain outside the reported iteration time.

| Graph series d | Eager route | Critic forward/backward graph |
| --- | ---: | ---: |
| Mean whole iteration | 6.9696 s | 6.9826 s |
| Median whole iteration | 6.9425 s | 6.9460 s |
| p90 whole iteration | 7.155 s | 7.205 s |
| Mean actor/critic phase | 4.5936 s | 4.6146 s |
| CUDA allocator allocated window peak | 3,382,561,280 B | 3,534,817,792 B |
| CUDA allocator reserved window peak | 5,085,593,600 B | 9,130,999,808 B |

The candidate mean is **13 ms (0.1865%) slower**. Its paired speed ratios are
0.98213x and 1.01438x, with mean 0.99826x: this does not establish a stable
end-to-end benefit, so `critic_cuda_graph=false` remains the default. Each
candidate records **10 captures and 200 replays**, verifying that the requested
route actually executed. This result is neither a replay-only kernel benchmark
nor a conclusion about world/actor graph capture, DDP or convergence. It cannot
be multiplied by the independently measured geometry or communication gains.
[Complete graph series d summary](../output/spark-runtime-20261024/optimization-stage2-20261024-b/optimization-critic-graph-stage2-d/summary.json),
[retained raw evidence](../output/spark-runtime-20261024/optimization-stage2-20261024-b/optimization-graph-stage2-d-evidence.tar.gz).

All four series-d processes exit 0 with `oom_killed=false`, under the unchanged
100 GiB/zero-swap/12-CPU container policy, 80% admission and 16 GiB minimum reserve.
The 36 retained cgroup observations per run show zero swap and cumulative
memory-limit/OOM events; the largest observed kernel `memory.peak` is
2,475,032,576 B (2.305 GiB). Minimum observed CUDA free memory is 70.158 GiB.
The candidate's sampled private graph-pool reservation is 190,840,832 B (182 MiB),
below the 1 GiB post-capture acceptance bound. That bound is not a hard allocator
cap during capture; the larger overall allocator reservation above is retained
as evidence. These observations do not certify complete container-lifetime or
whole-machine UMA peaks. The generic timing summary retains
`numerical_equivalence_verified=false`; the separately passing CUDA gates do
not silently turn that into whole-checkpoint equivalence.

Earlier graph series a, b and c remain incomplete after protective admission
rejections, including one fresh training startup whose separate preflight had
passed. No failed sample or selected successful subset enters series d's
comparison. Their raw records and unchanged-threshold decisions are retained in
[the A/B/C archive](../output/spark-runtime-20261024/optimization-stage2-20261024-b/optimization-graph-attempts-abc-evidence.tar.gz).
The bounded per-file checkpoint and stopped-container compute-cache handling
retains files and build/configuration identities; it does not establish a
training-speed gain by itself or justify relaxing admission.

The first normalization ABBA, series a, was rejected as a whole after run 2 failed
memory admission before training: the projected 68,841,500,784-byte peak exceeded
the then-available 68,717,907,968-byte budget. Run 3 was not launched. No OOM
occurred and the first two successful runs were not selected for a speed claim.
The complete fresh series b above supplies the reported normalization result.
[Rejected-series evidence](../output/spark-runtime-20261024/optimization-stage1-20261024-a/optimization-criticnorm-rejected-evidence.tar.gz).

A bounded helper advised the OS about cached pages of 72 registered payload
files from six completed runs, while retaining all files. It held training locks,
required idle Docker, and neither cleared global caches nor raised the budget.
The audit records zero payload bytes read/written and zero deleted files; it
checks committed metadata rather than recomputing payload hashes and does not
guarantee actual cache reclamation.
[Cache-advice audit](../output/spark-runtime-20261024/optimization-stage1-20261024-a/optimization-cache-advice-a.json).

The first two-rank bucket gate stopped during RDMA memory registration because
Docker's default locked-memory limit was too small; the failed evidence is
retained. The retry uses an explicit 1 GiB memlock limit within an 8 GiB,
zero-swap, four-CPU container on each node. Both ranks pass the correctness gate,
including three optimizer steps, bucket boundaries, dtype changes, rank-specific
missing gradients and nonfinite rejection; observed maximum absolute difference
from the legacy route is zero at the unchanged tolerance. These are bounded
fixtures, not an equivalence certificate for arbitrary training runs.

The completed communication benchmark uses the native paper network parameter
shapes and a schedule of 10 world, one policy and 20 critic reductions, without
running the training forward/backward or optimizer. A 16 MiB bucket reduces
collective calls per schedule from 280 to 53. After three warm-up schedules per
route, ten ABBA blocks provide 20 samples per route. Each matched sample takes
the maximum host completion time across both ranks as the critical path:

| Communication-only schedule | Legacy route | 16 MiB buckets |
| --- | ---: | ---: |
| Mean | 533.546 ms | 142.452 ms |
| Median | 598.362 ms | 143.386 ms |
| p90 | 614.772 ms | 145.969 ms |

The ten paired ratios have median 4.0002x and range 2.6319x–4.2782x. This is a
communication-only result, **not an end-to-end distributed-training speedup**;
neither computation/communication overlap nor a multi-node learning-quality gain
has been established. Both rank processes exit 0 without OOM kills; post-process
cgroup observations report zero swap/OOM events and kernel peaks of
1,015,549,952 and 1,015,205,888 bytes.
[Bucket summary and build identities](../output/spark-runtime-20261024/optimization-stage2-20261024-b/bucket-summary.json).

The generic aggregator retains `transport_proven=false` because it does not
interpret NCCL logs. Separate inspection of both logs shows active send/receive
channels via `NET/IB` over the 10.0.0.1/10.0.0.2 RoCE interfaces, and explicitly
reports GPU Direct RDMA disabled (`GDR 0`). Thus the measured path uses the
ConnectX interconnect with host staging, not proven direct GPU RDMA. The logs
also retain the missing `mlx5dv_reg_dmabuf_mr` symbol diagnostic.
[Rank 0 NCCL log](../output/spark-runtime-20261024/optimization-stage2-20261024-b/bucket-rank0/nccl.log),
[rank 1 NCCL log](../output/spark-runtime-20261024/optimization-stage2-20261024-b/bucket-rank1/nccl.log).
