# Logical 4096 optimization admission audit — 2026-10-24

The six-optimization G configuration requires **82,444,543,888 B** of remaining
memory under the current initial admission estimate. The separate G profile is
the **baseline**, so it requires **79,001,329,552 B**, not the candidate-profile
threshold of 82,780,088,208 B. These are conservative admission estimates, not
measured allocation maxima or guarantees against OOM.

No GPU task, cache advice, source change to the planner, or training build was
performed for this audit. The small offline calculator is
[audit_native4096_memory.mbtx](../scripts/audit_native4096_memory.mbtx). It checks
the accepted E logical4096 report, the accepted F2 candidate512 report and the
new G candidate configuration; it also verifies that each threshold admits the
estimate and one byte less refuses it.

## Inputs and preserved limits

The G pair uses N256, logical actor4096 with actor micro512, world2048 with no
world microbatch, horizon32, model window8, history10 and preview10. Both sides
use FP32, expanded LayerNorm, TF32 permission, serial optimizer save workspace,
the same trainer/plugin and data pins. CUDA graphs and gradient buckets are off.
The six candidate flags are geometry reuse, batched body orientation, resident
references, checked Adam norm, deferred scalar metrics and world staging.

The planner still requires:

```text
R = min(actual host/cgroup remaining, actual cudaMemGetInfo free)
budget = min(floor(0.8 * R), R - 16 GiB)
required R = max(ceil(peak / 0.8), peak + 16 GiB)
```

The launcher still uses a 100 GiB cgroup, zero container swap and 12 CPU. Its
one-second guard stops below host MemAvailable24GiB or MemFree12GiB, above
cgroup current84GiB, or on swap/OOM/limit events. Startup requires
MemAvailable64GiB and MemFree40GiB. These sampled guards do not observe every
transient allocation. Host, CUDA and allocator numbers overlap on Spark UMA and
must not be added.

## Exact reserves

The production formulas are in
[optimizations.mbt](../src/learning_aligned_gpu/cmd/optimizations.mbt).
[with_execution_reserve](../src/learning_native_admission/execution_reserve.mbt)
adds the sum to every phase without discounting the original envelope.

| Candidate component | Bytes |
| --- | ---: |
| World staging: `32*205*2048*8 + 65536` | 107,544,576 |
| Geometry reuse: `2*64*18*4*32*512` | 150,994,944 |
| Batched orientation: `64MiB + 128*4*64*32*512` | 603,979,776 |
| Resident reference construction and working storage | 2,915,190,784 |
| Deferred scalar metrics | 1,048,576 |
| Checked Adam norm additional reserve | 0 |
| **Total additional reserve** | **3,778,758,656** |

The resident table cap is 1376MiB = 1,442,840,576 B. Its reserve is larger:
`2*cap + 32*256*(71+73*10) + 65536*267 + (40*33+8)*4096 + 40*256`.
This retains table/chunk coexistence and bounded host working storage. It is
approximately 2.92 decimal GB, not a newly increased 3GiB table cap. The world
reserve remains below its explicit 128MiB cap. The tables themselves still
reject data exceeding their runtime cap.

| Scenario | Peak estimate, B | Required remaining, B |
| --- | ---: | ---: |
| Baseline4096 initial | 61,485,916,048 | 78,665,785,232 |
| Six-optimization4096 initial | 65,264,674,704 | 82,444,543,888 |
| Baseline4096 profile initial | 61,821,460,368 | 79,001,329,552 |
| Six-optimization4096 profile initial | 65,600,219,024 | 82,780,088,208 |
| Baseline4096 after catalog, actual8842 bins | 57,862,086,328 | 75,041,955,512 |
| Six-optimization4096 after catalog, actual8842 bins | 61,640,844,984 | 78,820,714,168 |

All listed peaks remain the optimizer archive save phase. Shortening a profile
to 24 rounds does not remove its final checkpoint or full-capacity planning
envelope. The profile adds `64MiB + 65536*4096 = 335,544,320 B` to every phase.
The phase-plan field `required_remaining_bytes` retains a historical 65%
diagnostic; the selected 80% decision is authoritative.

At the parent-reported 13:06UTC host MemFree79,620,468,736 B, the candidate
initial threshold is higher by 2,824,075,152 B; candidate plus profile is higher
by 3,159,619,472 B. MemFree is only a conservative planning proxy here. Fresh
host/cgroup and CUDA readings, including startup allocations, still decide.

## Profile coverage

The accepted shared512 baseline profile recorded 28,248 spans, with 11,304
upload and 11,304 validation spans. Moving to4096/micro512 adds, for each of
four actor updates, fourteen extra staging blocks with70 reference/history
uploads and32 noise uploads, each with two spans. It also adds seven actor
microbatches with eleven spans each. Thus:

```text
28248 + 4*14*(70+32)*2 + 4*7*11 = 39980 spans
upload_count = validate_count = 11304 + 4*14*102 = 17016
```

This fits65536 without raising the plugin cap. It assumes the same64warmup and
60regular collection steps over24iterations, and no extra readiness collection.
Acceptance must still check zero dropped/open/cancelled spans, all complete CUDA
events, actor forward/reward/tail/backward/critic_features32 each, robot/ref FK96
each, actor Adam4, critic prepare4 and critic forward/backward/Adam80 each.
The profile is an inclusive-stream diagnostic, not an unprofiled throughput
measurement. Candidate profiling has different label counts and must not reuse
the baseline coverage contract.

## Unknown sampler capacity: current limitation

The initial planner assumes43,149,672 bins until the motion catalog has loaded;
the pinned40-clip catalog has8842. This accounts for3,623,829,720 B of the initial
save-phase excess. No existing configuration safely lowers that count:
`max_reference_gather_frames` bounds individual reads, not total catalog size;
the resident cache cap is checked later and is disabled in the baseline.
`CatalogClip` has no frame count, while shard metadata requires validation before
being trusted.

After this audit, the parent authorized an explicit sampler-bin capacity. The
source implementation is complete and its narrow CPU regression passed21/21.
The original G binary remains frozen; the new route requires a newly built and
pinned executable and the same explicit capacity on both pair members.

`max_motion_sampler_bins: 9000` is accepted only for paper4096 with mmap storage.
An absent field preserves the old unknown-catalog estimate and loader behavior.
The planner initially charges9000 bins. The streamed loader verifies each shard,
then checks the next clip's complete bin count against the remaining capacity
**before** extending starts/ends/bin arrays. It refuses excess data rather than
truncating or changing sampling. Post-catalog admission rejects an actual count
above the configured capacity. An explicit cap on eager loading is refused.

| Revised cap9000 scenario | Peak estimate, B | Required remaining, B |
| --- | ---: | ---: |
| Baseline initial | 57,862,099,600 | 75,041,968,784 |
| Six-optimization initial | 61,640,858,256 | 78,820,727,440 |
| Baseline profile initial | 58,197,643,920 | 75,377,513,104 |
| Six-optimization profile initial | 61,976,402,576 | 79,156,271,760 |

The cap charges13,272 B above the actual8842-bin save-phase estimate. All previous
admission percentages, free reserves, archive limits and runtime guards remain.
These new estimates are not hardware acceptance results. The historical audit
script intentionally rejects a cap-bearing G config to avoid silently applying
its old assumptions to a new binary.

The regression covers absent/default, strict integer/range/storage/profile
validation, exact-cap acceptance, one-bin and cross-clip overflow, cold and
reopened shard paths, unchanged complete states/goals/bins, and rejection of an
actual post-catalog count above the cap. The generated public API gains only an
optional `load_motion_manifest(max_sampler_bins)` parameter. CPU evidence:
`/tmp/moonrobo-motion-sampler-cap-regression.log`; `moon info` completed with zero
errors and `moon fmt` completed. No GPU run was started by this audit agent.

## Completed output cache audit

Two completed image export files were inspected read-only: the project-private
`isaaclab-46d6cc3-arm64-images.tar` and `apic-runtime-audit-a-image.tar`, sized
10,779,234,816 B and10,779,388,928 B. Both were canonical regular files owned by
uid1000 with one hard link. Neither appears in G's265 pins or trainer arguments;
the loaded Docker image is independent of the tar file's page cache. Docker had
no running containers, no docker/tar/dd/scp/rsync process was visible, and ordinary
user `fuser` reported no visible user of either file. This is not a privileged
proof over every system process.

The parent subsequently reported both file-specific `sync --data`/read-only
`dd iflag=nocache,nofollow count=0` hints returned0 and preserved stat identity,
but produced no measured free-memory improvement: host MemFree was
79,620,468,736 B before and79,580,758,016 B after, a decrease of39,710,720 B.
Both archive stat records were unchanged. The hints must not be counted as
reclaimed capacity or described as restoring capacity. No payload was read for
a new checksum, deleted or modified.
Only completed project-owned output is eligible for any further targeted hint;
shared inputs, motion data/cache, active private compiler caches and system-wide
drop-caches remain outside this audit.

## Frozen G2 wiring review

An independent read-only review found no blocking wiring issue in G2's sampler
cap, noise staging or actor normalization snapshot. The reviewed workspace
copies of twelve files matched the contents of the frozen
`smc-native-aligned-20261024-g2/source.tar.gz`, SHA256
`953abe66f60ada4aa22f3da0f6afc8c55dbbc19a3d5c2f9d87bed3b8f2edee8d`:
cmd noise/configuration/optimization/main/memory/inference, runtime
train/batches/noise, actor snapshot, motion manifest and streamed loader.
This is a source review; it does not replace the separate CUDA correctness gates.

- The9000 cap flows from parsed settings to initial planning, the manifest
  loader and actual-count post-catalog re-admission. Evaluation explicitly
  removes this training-only cap from its temporary settings.
- `noise_staging_batch` defaults false/None; `actor_norm_snapshot` defaults
  false in both CLI settings and `ExecutionOptimizations::default`. The six-flag
  G2 comparison leaves both false on both sides. A separate incremental pair
  enables only these two on top of the same six-flag configuration.
- Noise capacity is checked by settings and runner construction, then again
  before policy sampling consumes RNG. Runtime receives the selected cap and
  passes it into `sample_policy_batch`. It stages one imagined time step at a
  time, with generation/validation in the original256-sample blocks. H32 output
  tensors remain covered by the unchanged original envelope; the added host
  working set is not multiplied by32. The old per-block upload/concat branch
  remains the None route.
- A normalization snapshot is created once per logical actor update and shared
  by its eight microbatches. It retains existing means and computes four std
  vectors with the same expression, keeping subtraction/division and world
  output multiplication/addition in their original order. No statistics update
  occurs inside that actor rollout. It does not cache across learner updates,
  capture tail-critic statistics, or alter GAE/Adam cadence. The false branch
  calls the original policy forward/world delta functions.
- Noise staging reserves13,244,416 B at4096×99, below its explicit16MiB cap.
  The snapshot adds65,536 B, including4128 B of std payload and handle/allocator
  allowance. Both are charged in every phase, with no baseline discount.
  Noise configuration participates in runtime distributed setup identity;
  the snapshot flag participates in learner execution identity.

| G2 cap9000 configuration | Peak estimate, B | Required remaining, B |
| --- | ---: | ---: |
| Six flags, two new flags false | 61,640,858,256 | 78,820,727,440 |
| Six flags plus both new flags | 61,654,168,208 | 78,834,037,392 |
| Six flags plus both new flags and65536-span profile | 61,989,712,528 | 79,169,581,712 |

The new pair wrapper fixes the cap, both memory caps, microbatch shape, trainer,
plugin and data pins across pair members. It also records that deferred scalar
metrics adds no new execution branch to the already-batched actor microbatch
path: a six-switch comparison cannot establish six individually active or
individually measured speedups. The separate baseline profile must keep its
existing label-count contract; enabling either new feature changes that contract.
No frozen source, remote task or cache was changed during this follow-up review.

## 估计与观测口径复核

2026-10-25的补充只读复核保留前述历史章节。下面以已经冻结的G2六项配置为例：
N256、logical4096/micro512、sampler cap9000、serial optimizer save workspace，
noise staging和normalization snapshot均关闭。依据是原始
[G2-a run1准入拒绝记录](../output/spark-runtime-20261024/smc-native-4096-optimization-20261024-g/six-abba/run-1/preflight.stdout.log)，
不是根据较低的观测峰值反推新阈值。该记录的保守峰值为**61,640,858,256 B**，
峰值阶段是`save_optimizer_archives`，组成如下：

| 保存阶段规划组成 | Bytes |
| --- | ---: |
| physics scene working floor | 25,769,803,776 |
| device working cache envelope | 20,308,787,200 |
| reference catalog/construction retained | 4,294,967,296 |
| 串行保存workspace | 4,294,967,296 |
| 三份archive的file cache | 1,610,612,736 |
| 六项执行路径额外reserve | 3,778,758,656 |
| 其余参数、history、sampler、APIC元数据及满容量replay等 | 1,582,961,296 |
| **合计** | **61,640,858,256** |

实际准入使用`Decision`中的80%和16GiB余量共同约束。仅80%条件需要
**77,051,072,820 B**，峰值加16GiB需要**78,820,727,440 B**，故后者限制更紧。
原日志中phase-plan的65%历史诊断字段不是本次选用阈值。

这些大项多数包含工程保守余量，不是同时活跃tensor的逐一实测清单。
[结构工作集公式](../src/learning_native_admission/plan.mbt:151)和
[缓存生命周期公式](../src/learning_native_admission/plan.mbt:223)在本配置下给出
actor结构工作集10,020,175,872 B，再计算
`2 × 10,020,175,872 + 256 MiB = 20,308,787,200 B`。
乘二用于保守覆盖CUDA caching allocator跨阶段保留，不表示程序同时保留两份actor反向图。
实际chunk依次反向并释放；脱离梯度的完整critic数据另有生命周期。

同一actor结构估式将critic hidden宽度计入每个H步；当前
[actor实现](../src/learning_aligned_gpu/actor_microbatch.mbt:151)在每个chunk只调用一次
critic尾值。仅此公式子项的H次与一次差额为
`512 × (32−1) × (256+128) × 32 = 195,035,136 B`。
这是一项可审查的估式差额，**不是已实测可回收的内存，也不能直接从准入峰值扣除**；
其余图、allocator、缓存倍数和生命周期仍需各自验证。
固定24GiB physics、4GiB reference，以及
[保存的6倍＋1GiB](../src/learning_native_admission/plan.mbt:314)都是工程余量；
串行保存仍保留三个512MiB archive的file cache。
[六项reserve](../src/learning_aligned_gpu/cmd/optimizations.mbt:58)作为额外存储加入所有阶段，
没有减去原有envelope或把基线缓冲视为已回收。

正式six结果的CUDA allocated/reserved窗口峰值约**4.812/7.764GB**，是另一种口径。
[遥测定义](../src/learning_aligned_gpu/cmd/telemetry.mbt:323)从GPU初始化/restore之后开始，
覆盖训练和checkpoint发布，但不含报告序列化与环境teardown；只统计当前allocator/pool，
不包含其外分配。cgroup、CUDA allocator、CUDA free和宿主机UMA计数重叠，不能相加，
也不能用4.812GB或7.764GB替代上述完整生命周期规划。
[完整ABBA summary](../output/spark-runtime-20261024/smc-native-aligned-20261024-g2-specs/six-g2-b-summary.json)
每成员60轮的physical transitions为54,784，即N256下214行物理采样；此时replay尚未达到
规划中的1000行容量。短程观测没有覆盖满容量长期训练，因此不能据此证明全容量峰值。

本复核**没有修改planner、guard、batch或容量上限**，也不授权自动增大batch或降低保护。
原始SMC compiled/eager4096对照已完成；另行批准的native micro512/256仍是执行粒度诊断，
其数值等价与推广标志保持false，未完成组不在本节生成性能结论。
