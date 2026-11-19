# Native batch throughput, 2026-10-24

128 was the previously validated engineering batch, not a hardware limit.
`wm_batch` / `pi_batch` count samples per optimizer update; `wm_microbatch` /
`pi_microbatch` only split that update's calculation. The 16-row execution
setting was retained from the memory gate and had not been optimized for
throughput. Environment count is a third, independent setting.

The original explicit configuration is
[`g1-native-tensor-paper-n256-b2048-b4096.json`](../examples/learning/g1-native-tensor-paper-n256-b2048-b4096.json):
WM logical batch 2048, policy logical batch 4096, both microbatch 256,
256 physical environments, replay1000 and unchanged 8/32-step unrolls.
It pins the newly exported collision-on artifact. Its fixed N256 native/SDK
physical replay passed at 10:43 Beijing time on 2026-10-24, as detailed below;
that physics gate does not itself execute the larger-batch trainer. This is a
ten-iteration throughput gate with `wm_only_iters=0` and one final checkpoint;
it is not a convergence run
or a claim that N4096 already works. The eventual long-run schedule must
set the long-run checkpoint cadence explicitly. The paper baseline keeps
`wm_only_iters=0`; SMC's 500 world-only iterations are a separate implementation
choice, not a paper requirement.

## Measured B128 comparison

179 ran all four cases sequentially using the same frozen trainer, tensor
library, N128 collision-off physics, 40 LAFAN1 clips, seed179, FP32 with TF32
permission, and 12 CPU cores. Each fresh process ran five iterations, with a
checkpoint after iteration five. These are SMC99 performance experiments,
not Paper93 method equivalence. Times below average iterations 2–5; initialization,
warmup and checkpoint are excluded. Every container exited zero with
`OOMKilled=false`; each had a 64 GiB cgroup, zero swap, and unchanged 65% admission.

| Computational chunk | Ten WM updates | Actor plus 20 critic updates | Combined updates | PyTorch reserved peak |
| ---: | ---: | ---: | ---: | ---: |
| 16 | 3.354 s | 2.361 s | 5.715 s | 482 MiB |
| 32 | 1.732 s | 1.258 s | 2.990 s | 544 MiB |
| 64 | 0.926 s | 0.665 s | 1.590 s | 656 MiB |
| Full 128 | 0.519 s | 0.380 s | 0.898 s | 880 MiB |

Full128 was approximately 6.36 times faster in combined update time than
micro16. The full128 allocated peak was 819,329,536 bytes. Neither allocator
counter includes all external physics allocations. Collection stayed near
0.25 s per iteration, warmup near 7.8 s, and checkpoint near 5.1 s. These are
short, single-seed synchronized wall-time measurements, not pure kernel times
or a guarantee of long-run performance or memory safety.

NVIDIA utilization samples remain around 50–57% in the compared update phases;
they do not establish SM or Tensor Core occupancy. Full128 phases are short
relative to the 200 ms polling and vendor utilization averaging windows.
The substantial throughput gain does not mean the GPU is saturated.

Evidence: [phase report](../output/spark-runtime-20261024/batch-sweep-evidence-20261024-a/phase-report.json),
[raw NVIDIA samples](../output/spark-runtime-20261024/batch-sweep-evidence-20261024-a/gpu-samples.csv),
[phase sample aggregation](../output/spark-runtime-20261024/batch-sweep-evidence-20261024-a/gpu-summary.json).
Each case directory retains config, exact Docker launch/final state, stdout,
stderr and complete trainer report. The metadata-only evidence archive SHA256
is `793a7768888612da70b348692679709e1094a2938f2781ea3d9a2bb1359cbc44`.
Frozen trainer SHA256 is
`d7ca2586838ef8864d4137843c6584a314abb2e7a479adb161e707b9d270d234`;
tensor library is
`6ea1b0e0292a7ab97cd2aad0d4c9fde54745974d4cc9a5914b08949a0913475a`.

## N256 collision-on physics gate

Node 179 completed the N256 export and SDK oracle in attempt `b`, then passed
native replay in attempt `c` with **675 SDK comparison checks plus 380
self-checks, zero failures**. All 256 environments simulated eight control
steps (2,048 world steps); the fixed 27-operation tape scored only worlds
`[0,128,255]`. The largest recorded absolute error was
`3.469446951953614e-18` for an SDK comparison and
`4.5776367230132564e-7` for a self-check. These mixed-field maxima are not
single position errors. SDK tolerances remain `atol=rtol=1e-5`.

The c container ran UTC `02:43:35.344519377`–`02:43:56.829650328`, exited zero
and reported `OOMKilled=false`. Its observed cgroup peak before helper exit
was 480,014,336 bytes; this excludes a claim of certified lifetime peak or
CUDA allocator measurement. Export/oracle/replay each retained 64 GiB cgroups,
zero swap, four CPU cores and the unchanged admission rules.

Attempt b's failed replay remains preserved: it stopped at JSON integer
decoding, before numerical comparison. Attempt c repaired that audit decoding
path while keeping the manifest, tape, oracle, runtime library and comparison
tolerances unchanged. This successful selected trace clears that specific
physics prerequisite for the larger-batch trial; it does not establish global
physical equivalence, N4096 operation, training convergence or a throughput
measurement at logical batches 2048/4096.

Evidence: [replay report](../output/spark-runtime-20261024/paper-n256-evidence-20261024-c/replay-report-paper-n256.json),
[Docker final state](../output/spark-runtime-20261024/paper-n256-evidence-20261024-c/replay-docker-final.json),
[helper summary](../output/spark-runtime-20261024/paper-n256-evidence-20261024-c/replay-evidence/summary.json),
and [full gate record with retained failures and hashes](../scripts/APIC_PAPER_N256_GATE.md).
The c metadata-only archive SHA256 is
`6dc3cb6fcf7f0296ffde90558182ce28f98279d251d3a048cb334e1312063719`.

## Larger batches and synchronization

The actual phase planner now has a retained
[2048/4096 calculation](../output/spark-runtime-20261024/paper-batch-capacity-20261024-a/README.md).
With N256 and microbatch256 it requires approximately 89.62 GiB actual free
under unknown sampler/APIC upper bounds, or 83.19 GiB for the known LAFAN
sampler while still retaining APIC upper bounds. N4096/micro256 requires
105.83 GiB under unknown bounds. These conservative estimates include restore
and publication phases; they are not measured GPU allocations. Admission still
uses 65% of the minimum of current host/cgroup remaining and CUDA free on UMA.

Fresh training now explicitly budgets the three training and two saving phases;
resume retains both restore phases as well. The pinned APIC metadata is validated
under its bounded CPU decode guard before whole-run admission. With the actual
N256 artifact, fresh startup still using the unknown sampler bound requires
91,383,896,394 bytes at the default 65%; after loading the actual LAFAN sampler it
requires 85,808,773,748 bytes. Saving headroom and the 24 GiB physics floor remain.
The earlier calculation above is retained as the original all-phase upper bound.

The user's subsequent request to use more memory has an explicit opt-in config:
[`g1-native-tensor-paper-n256-b2048-b4096-util80.json`](../examples/learning/g1-native-tensor-paper-n256-b2048-b4096-util80.json).
It keeps the same batches and sets `memory_admission_percent=80`. Its budget is
`min(actual_remaining * 80 / 100, actual_remaining - 16 GiB)`, where actual
remaining is still the minimum of host/cgroup and CUDA free. The default remains
65%. The selected decision separately reports its actual requirement and the
65% baseline; the initial opt-in requirement is 76,579,401,840 bytes.

Opt-in training requires memory telemetry, a finite container memory cap and
zero container swap. Each recorded training/checkpoint phase checks CUDA free,
host MemAvailable and cgroup headroom against 16 GiB and stops subsequent phases
if a check fails. This is stage-boundary observation, not continuous protection
against an allocation peak or a guarantee against OOM. Microbatches are never
selected automatically. Actual GPU results for this opt-in follow below.

Microbatch code separately batches detached scalar metrics for readback,
preserving CPU summation and optimizer order. That change is absent from the
frozen four-case comparison and has CPU tests; it must not be credited for the
measured speedup above. The prior CUDA full/split numerical mismatch remains
recorded in [MICROBATCH_GATE.md](../src/learning_aligned_gpu/MICROBATCH_GATE.md).
All original Python, gate configurations and frozen artifacts remain available.

## Measured Paper93 logical batches 2048 / 4096

Node179 completed two fresh ten-iteration runs with the same frozen trainer,
N256 collision-on artifact, 40 LAFAN1 clips, seed179, FP32 storage with TF32
permission, ten world updates and twenty critic updates per iteration. Only
the world/policy microbatch changed. Both containers had a 100 GiB memory cap,
zero swap, twelve CPU cores and the explicit 80% plus 16 GiB admission policy.
Each completed its final checkpoint, exited zero and reported `OOMKilled=false`.
This differs from the earlier B128/SMC99 experiment and is a separate comparison.

| Microbatch | Ten WM updates | Actor plus 20 critic updates | Combined updates | Torch allocated peak | Torch reserved peak | Minimum sampled CUDA free |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 256 | 3.887 s | 6.348 s | 10.235 s | 2.177 GiB | 3.734 GiB | 77.44 GiB |
| 512 | 2.429 s | 4.515 s | 6.944 s | 3.144 GiB | 4.744 GiB | 75.99 GiB |

Times average iterations 2–10, excluding initialization, warmup and checkpoint.
Micro512 increased equal-work update throughput by approximately 47.4% and
reduced update time by 32.2%. It is the latest measured candidate:
[`g1-native-tensor-paper-n256-b2048-b4096-util80-micro512.json`](../examples/learning/g1-native-tensor-paper-n256-b2048-b4096-util80-micro512.json).
It remains a ten-iteration throughput configuration, not a long training schedule.

Phase-aligned NVIDIA GPU utilization means rose from 57.12% to 62.87% for world
updates, and from 49.43% to 51.17% for actor plus critic. These vendor samples
are not SM/Tensor Core occupancy measurements. The GPU is not yet saturated.
The raw CSV used `csv,nounits`; the summarizer explicitly selects `--nounits`
without changing that source file. Missing memory clocks remain missing.

The external watcher observed cgroup peaks of 2,704,048,128 and 2,503,872,512
bytes respectively, with no observed cgroup OOM events. Each final post-exit
sample records the removed cgroup as unavailable. Cgroup, Torch allocator and
CUDA-free readings have different scopes; they must not be added or treated as
a certified total lifetime peak. The results leave substantial unused memory.

Micro1024 was **preflight only and rejected**, not a failed training or an OOM.
Its conservative initial phase estimate was 84,760,391,792 bytes, requiring
105,950,489,740 actual free bytes under the opt-in policy. Actual CUDA free was
89,579,614,208 bytes, yielding a budget of 71,663,691,366 bytes. There is no
micro1024 training report. Smaller-run observations do not justify bypassing
this refusal; the structural memory accounting needs review first.

Evidence: [phase report](../output/spark-runtime-20261024/paper-batch-sweep-evidence-20261024-a/phase-report.json),
[GPU phase summary](../output/spark-runtime-20261024/paper-batch-sweep-evidence-20261024-a/gpu-summary.json),
[raw GPU samples](../output/spark-runtime-20261024/paper-batch-sweep-evidence-20261024-a/gpu-samples.csv),
[micro256 memory watcher](../output/spark-runtime-20261024/paper-batch-memory-watch-20261024-a/native-paper-batch-micro256-watch-20261024-a/final-summary.json),
[micro512 memory watcher](../output/spark-runtime-20261024/paper-batch-memory-watch-20261024-a/native-paper-batch-micro512-watch-20261024-a/final-summary.json).
The sweep metadata archive SHA256 is
`1bd24a156e9b4e18fb91d4c9357105d9c7f1248c8f917f6a08da26ad4c2ee44f`;
the memory-watch archive is
`754217b6d52b27dac69ba47a86734e622749beeb2f3d6ce00a97138a1624cbe3`.
Frozen trainer `native-paper-batch-20261024-d/trainer` SHA256 is
`0be35444d53f44f01194c54eefa5facedcdb48f380d04cbc7e3501df92481853`.
The same TF32 tensor library as above was used. These runs include the detached
metric readback optimization; only their microbatch differs within this comparison.
They do not resolve the separate CUDA full/split numerical mismatch, establish
convergence, validate N4096, or prove memory safety for long runs/full BONES data.

## Independent world batch expansion

Keeping actor microbatch512, node179 next completed world microbatch2048 (the
full logical world batch). Only `wm_microbatch` changed from the previous 512/512
case. Exact program, tensor/physics libraries, artifact, scene, motion identity,
TF32 policy, logical batches and container limits were checked for equality.
The same frozen `d` trainer was used; this run does not include the subsequent
bounded-host-start decoding change.

| World / actor execution chunk | Ten world updates | Actor plus critic | Combined updates |
| ---: | ---: | ---: | ---: |
| 512 / 512 | 2.429 s | 4.515 s | 6.944 s |
| 2048 / 512 | 1.809 s | 4.555 s | 6.364 s |

Over iterations 2–10, world time decreased 25.54%, combined time decreased 8.36%
(approximately 9.1% more equal-work update throughput), and actor/critic time
increased 0.88% in this single short comparison. World NVIDIA utilization mean
was 68.95% over 81 samples; actor/critic was 52.59% over 205 samples. These readings
do not prove SM occupancy or numerical equivalence between batch executions.

The run completed ten iterations and a checkpoint, UTC 03:38:15.115419588 to
03:40:08.961127436 on 2026-10-24, Exit 0 and `OOMKilled=false`. Allocator peaks were
3,373,926,912 allocated and 5,085,593,600 reserved bytes; minimum sampled CUDA
free was 81,156,648,960 bytes (75.58 GiB). The watcher observed a 2,516,660,224-byte
cgroup peak and zero OOM event counters. Its first successful poll was about
9.7 seconds after container start; full-lifetime peak coverage is not certified.
Memory remains substantially underused; this is not an 80% observed occupancy.

Latest measured configuration:
[`g1-native-tensor-paper-n256-b2048-b4096-util80-wm2048-pi512.json`](../examples/learning/g1-native-tensor-paper-n256-b2048-b4096-util80-wm2048-pi512.json).
Evidence: [phase report](../output/spark-runtime-20261024/paper-wm2048-pi512-evidence-20261024-a/phase-report.json),
[GPU summary](../output/spark-runtime-20261024/paper-wm2048-pi512-evidence-20261024-a/gpu-summary.json),
[identity/configuration comparison](../output/spark-runtime-20261024/paper-wm2048-pi512-evidence-20261024-a/comparison.json).
Metadata archive SHA256:
`a76bb4f3dd3864b8c6a8cba87c6e1bbe01e37d746ab669ac9a2fe0a41cf75d75`.
Configuration SHA256:
`7d31dfb69ba5719644953ede747f4751e054ef78cff2b106e856db2f575ee99f`.

## Host staging improvement prepared separately

Actor sampling now selects all logical indices first and decodes at most 256
starts per synchronous upload callback. With B4096/history10 this reduces
simultaneously live compatibility Transitions from 45,056 to 2,816; the full
selected I32 index payload is 16 KiB. CPU tests compare sampled fields, tensor
bits and RNG continuation at block boundaries. Full logical device inputs,
references, critic permutations and the original 128 KiB/object allowance remain.

The [combined source and validation record](../output/spark-runtime-20261024/native-paper-actor-block-admission-20261024-a/README.md)
must be deployed together: applying its reduced planner count to the old runtime
would underestimate memory. Frozen Linux executable `e` builds successfully but
has not trained on GPU. The largest save-phase estimate is unchanged, so this
local object reduction does not itself admit actor micro1024. Unknown sampler,
GPU graph/cache and serialization lifetime accounting remain separate work;
see the [implementation-level graph ledger](NATIVE_GRAPH_MEMORY_ACCOUNTING.md).
