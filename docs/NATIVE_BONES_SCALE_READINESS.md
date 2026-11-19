# Native BONES 与 APIC 扩容准备情况

核对日期：2026-10-24。本文区分已完成的源码改动、真实执行证据及仍待验证的规模/数值问题。全 BONES 目录的 N=2 与 N=128 单 rank 各一轮门禁已完成；内存阈值和现有规模上限未放宽。

**已完成的范围是全目录加载、抽样、单次迭代、stream-v2 保存及单份 archive 的只读校验**：N2 与 N128 门禁都对 137,289 条已接受 BONES 动作完成 source/shard SHA 校验，加载后 65% 内存预检通过。N2 一次迭代包含 36 个真实物理转移、64 个想象转移、1 次 world、1 次 actor、4 次 critic 更新；N128 对应 8,448、4,096、10、1、20。两次保存的目录数均为 137,289。这不是全库 epoch、收敛或论文准确动作集验证；读回也不是两次独立运行或 rank-local 状态比较。

## 已有证据与不能混用的结论

| 项目 | 证据及边界 |
| --- | --- |
| 数据准备 | 最终 manifest 为 90,208,329 bytes，SHA-256 `64c21768fd7f2fad74d06153b1ada1faa958520abb8b234baa29d455572eb383`。接受 137,289、拒绝 4,931；178/179 的 142,220 份决定记录均扫描完成，missing=0、partial=0。 |
| 接受集聚合 | 120 Hz 源帧 121,458,621；原始 CSV 50,243,634,836 bytes；转换后的训练 CSV 87,996,168,100 bytes。这是 manifest 字段及 split 顺序的结构核验，本次摘要没有重新读 CSV 或重算物理。 |
| 原生训练 | 既有 40 条 LAFAN1 的小配置之外，已完成 BONES 137,289 条目录的 N2 与 N128 单 rank 各一轮门禁。它们仅抽样一小部分动作，不是全库 epoch 或收敛。 |
| checkpoint | BONES N2 与 N128 门禁各写入 stream-v2 generation，catalog_count=137,289；各自的 CPU 只读单份 archive 校验通过，验证 schema、文件及保存前 held-state attestation，均 `comparison_performed=false`、`rank_local_state_compared=false`。CPU MuJoCo 小配置的保存/恢复核验以及 live replay slab 本地小测试已通过；不能推导 APIC 精确续跑或 DDP 续跑已支持。 |
| SDK 数值对照 | 保留的 native/SDK 交叉比较仍有原容差失败；诊断中也出现 SDK 重复间差异。输入及 writer 的独立检查通过，尚不能把差异归因于某个求解器步骤，`physics_equivalence=false`。 |
| 论文数据集 | 当前是公开可确定过滤规则的 partial 集合，缺作者名字过滤清单及 floating-feet 条件。不是论文的 129,514 条准确集合，也不能仅凭数量称为更好的数据集。 |

证据：[178 聚合摘要](../output/spark-runtime-20261024/bones-filter-final/178/bones-filter-manifest-audit-20261024-b.json)、[178 receipt 扫描](../output/spark-runtime-20261024/bones-filter-final/178/bones-filter-progress-20261024-final.json)、[179 receipt 扫描](../output/spark-runtime-20261024/bones-filter-final/179/bones-filter-received-progress-20261024-final.json)、[APIC 执行与数值差异](DGX_SPARK_APIC_EXPORT_PLAN.md)、[最新诊断比较](../output/spark-runtime-20261024/native-apic/diagnostic-analysis-20261024-v2.json)、[论文过滤定义及缺项](BONES_SEED_PAPER_FILTERS.md)。

### 全目录门禁的实际结果

[容器结果](../output/spark-runtime-20261024/native-bones-catalog/runs/native-bones-catalog-20261024-a/docker-final.json)记录 178 上 `exit=0`、`OOMKilled=false`，从 2026-10-23 23:24:59.513Z 至 23:37:04.253Z，约 **12 分 04.74 秒**，包括全库 SHA 读取、加载、预检、训练与保存。[逐片进度末项](../output/spark-runtime-20261024/native-bones-catalog/runs/native-bones-catalog-20261024-a/trainer.stdout.log)记录 `source_verified_files=137289`、`source_verified_bytes=87996168100`、`shard_verified_files=137289`、`shard_verified_bytes=30779167040`，新建 shard=0、advice 失败=0。`advised_files=274578` 仅表示对源文件和 shard 发出成功的逐文件提示，不等于页实际回收。[训练报告](../output/spark-runtime-20261024/native-bones-catalog/runs/native-bones-catalog-20261024-a/train/report.json)中的 `elapsed_milliseconds=5993` 是训练内部片段，**不是**全流程耗时。

[helper 小结](../output/spark-runtime-20261024/native-bones-catalog/runs/native-bones-catalog-20261024-a/inside-summary.json)核对了 manifest 与保存的 catalog_count 均为 137,289，以及全局 36/64/1/1/4 工作计数；[加载后预检](../output/spark-runtime-20261024/native-bones-catalog/runs/native-bones-catalog-20261024-a/train/report.json)记录 host free 49,831,104,512、CUDA free 101,580,754,944、65% budget 32,390,217,932、规划峰值 30,930,712,096 bytes，判定通过。[cgroup 最后快照](../output/spark-runtime-20261024/native-bones-catalog/runs/native-bones-catalog-20261024-a/cgroup-after.json)记录内核 `memory.peak=3,273,281,536` bytes、OOM/OOM-kill 计数 0；它是在 helper 退出前观察到的峰值，**不是**完整容器生命周期或 GPU 显存峰值。训练 binary SHA `a445f96e4b4099224e57979c3852eed2b7409444c21b57c35fbb5c79f3715082`、配置 SHA `61675fc65e01510793b7637f1f6b475c74d3e67b01437d6f9006e47c635f8e92`、N2 artifact SHA `38d67d87cb0c9294fc7c9cb7635b6b9a88587f23a0036bdeb3cb6de2d1fb9b51` 均见该小结；镜像为 `sha256:d28f698d99e514b5c8dc5d682fa126507a27901ec016cb1f0795b83ac426bfca`。

[BONES 单份 checkpoint 读回](../output/spark-runtime-20261024/native-bones-catalog/runs/native-bones-catalog-20261024-a-readback/stdout.log)在 CPU、只读、无训练模式下记录 `verification_passed=true`、`generation.held_state_attestation_verified=true`，shared digest `d08bbd58f6811d1d21ae22c71cce33cb0daebfcf5a082f6407dd4bb3cd5ec33a`；同时明确 `comparison_performed=false`、`rank_local_state_compared=false`。[容器结果](../output/spark-runtime-20261024/native-bones-catalog/runs/native-bones-catalog-20261024-a-readback/docker-final.json)为 8 GiB、2 CPU、无网络/GPU 执行、exit 0、`OOMKilled=false`。这验证单 generation 的 archive/schema/held-state 读回，不验证跨 rank 相等、物理精确恢复或后续训练结果。

## 全 BONES 目录在 N=2 下的静态核验

### 缓存可以复用，但必须显式指定且允许加锁

过滤工具本身调用同一个 `load_motion_manifest(storage="mmap", cache_dir=cache)`，见 [filter/cmd/main.mbt](../src/learning_aligned/filter/cmd/main.mbt):334。训练入口同样选择该 loader，见 [GPU cmd/main.mbt](../src/learning_aligned_gpu/cmd/main.mbt):97。

缓存键为 `SHA256("moonrobo.motion-shard.f64le.v1:" + converted_csv_sha256 + ":" + source_fps)`，见 [motion_stream.mbt](../src/learning_aligned/motion_stream.mbt):110。键没有包含 manifest、split、全库帧偏移或 `compute_body_features`。partial manifest 保留接受条目的 CSV SHA/FPS；剔除其他动作只改变全局索引，不改变单片缓存内容。因此 178 过滤阶段已生成的全 142,220 片缓存可复用于接受子集，不需要再建一套 137,289 片缓存。

现有 [BONES N=2 配置](../examples/learning/g1-native-tensor-bones-catalog-gate.json) 已显式指定 `motion_cache_dir=/motion-cache` 和 `motion_cache_advice=true`。未指定缓存目录时默认写入新输出的 `reference-cache`，会产生额外磁盘副本。即使缓存命中，每片仍打开 `.f64.lock` 为 `ReadWrite/OpenOrCreate` 并独占加锁，见 [motion_stream.mbt](../src/learning_aligned/motion_stream.mbt)。因此数据 CSV、代码及 APIC bundle 可只读挂载；**缓存目录需单独可写挂载，输出另行可写**。不要同时让过滤进程或另一个训练进程修改这些 shard。

命中时仍校验转换 CSV 全文件 SHA、缓存元数据、`frames*608` 大小及 f64 全文件 SHA，见 [motion_stream.mbt](../src/learning_aligned/motion_stream.mbt):135。缓存存在不等于跳过内容校验，也不代表启动只读几十 MiB。

### 目录与 checkpoint 上限

| 限制 | 此集合的静态结论 |
| --- | --- |
| manifest ≤256 MiB、clips ≤200,000 | 90,208,329 bytes、137,289 条，均满足。检查在 [memory.mbt](../src/learning_aligned_gpu/cmd/memory.mbt):188、204。 |
| manifest 语义 | loader 检查 catalog 格式、XYZW、G1 29 关节布局、共同 FPS、split 和内容 SHA；不拒绝 `paper_exact_motion_set=false`。见 [motion_io.mbt](../src/learning_aligned/motion_io.mbt):164、191。这不把 partial 变成 paper-exact。 |
| 累计帧索引 ≤Int32.max | 使用当前 120→50 Hz 公式，接受集 resampled 总帧 F 的保守上界为 50,687,844，远低于 2,147,483,647。不是逐片实测精确值。 |
| stream-v2 catalog ≤64 MiB | 保守上界 39,405,351 bytes，约 37.58 MiB。下述推导无需假设平均文件名长度。 |
| stream-v2 所有 sidecar + state ≤512 MiB | N=2、replay64、history10、SMC99 维下，保守上界约 66,768,007 bytes（63.68 MiB）；三份 Adam archive 各自仍有 512 MiB 上限。 |

帧数推导：逐片 `n_i=floor((source_frames_i-1)/120/0.02)+1`，代码见 [motion_stream.mbt](../src/learning_aligned/motion_stream.mbt):162。这里用总源帧和 clip 数推界，没有把总帧一次性重采样冒充逐片精确结果。每片 bin 数为 `(n_i-2)/50+1`，因此 B≤1,145,554；三份 sampler 数值侧车分别 Float64、Float64、Int32，总和 `20*B`≤22,911,080 bytes，见 [sampling_checkpoint.mbt](../src/learning_aligned/sampling_checkpoint.mbt):29。

目录上界推导：最终 manifest 由同一个 MoonBit JSON serializer 写出，每个接受 ID 至少分别出现在 `clips[].id`、`splits.train`、`splits.evaluation` 三处；摘要已确认顺序和内容相同。令 manifest bytes 为 M，ID 编码总长至多 `floor(M/3)`。checkpoint 目录每片额外保守计 66 bytes 的带引号 SHA、2 bytes 分隔符，再加 256 bytes 固定字段，得到 `floor(90,208,329/3)+137,289*68+256=39,405,351`。这是上界，不是实际 `catalog.json` 长度；其实现及最终 64 MiB 检查见 [runtime/checkpoint_v2.mbt](../src/learning_aligned_gpu/runtime/checkpoint_v2.mbt):34。

总 payload 上界按目录、`20*B` sampler、128 个 replay transition（234 个 Float64 + 2 个 Int32 + 2 个 U8）、history/lengths、2×33 个 context 值，以及完整 4 MiB state metadata 预算求和。实际一轮 replay 可能不足容量。512 MiB 检查是**整个 sidecar 集合连同 state 的总和**，不是每个侧车都允许另外占满 512 MiB，见 [checkpoint_stream.mbt](../src/learning_aligned_gpu/cmd/checkpoint_stream.mbt):237。

仍未知的值：接受集精确 F/B、精确 catalog 编码字节、独立 loader-only 峰值/耗时和完整生命周期 CPU/GPU 峰值。上述门禁实测了成功加载、校验字节和容器内核的截至 helper 退出峰值，不能把总体约 12 分钟解释为独立 loader 时间。可在 summary 脚本中增加逐片算术聚合取得 F/B/catalog 字节，不必重读 CSV 或用 GPU。

### 内存门槛保持原样

既有单 rank N2 配置的 planning peak 是 **30,930,712,096 bytes（28.8065 GiB）**，其中 APIC 固定 reserve 为 24 GiB、reference/catalog/construction 为 4 GiB；stream-v2 不降低该旧预算。65% 门槛要求 `min(host/cgroup available, CUDA free)` 至少约 **44.3177 GiB**。48 GiB 是容器上限，不等于当前可用内存。公式见 [memory.mbt](../src/learning_aligned_gpu/cmd/memory.mbt):116。

本次完整缓存命中实际校验了 87,996,168,100 bytes 转换 CSV 与 30,779,167,040 bytes f64 shard。loader 使用有界窗口，不把全部帧留在堆上，但这些读取会形成 OS 文件缓存。当前 cgroup available 按 `memory.max-memory.current` 等约束计算，不把这些页自动认作空闲。显式 Linux `motion_cache_advice=true` 路径通过同一文件描述符以最多 64 KiB 块读取并校验源 CSV 与 f64 shard；仅在 SHA 匹配后逐文件请求 `posix_fadvise(DONTNEED)`，默认关闭，且不会删除文件或清除全局缓存。该请求不保证实际页回收；本次 274,578 个文件提示成功，unsupported/failed 都为 0，见 [storage 说明](../src/learning_aligned/storage/README.md)及上方实测进度。

训练在目录加载后、learner/APIC 场景分配前再次预检，见 [main.mbt](../src/learning_aligned_gpu/cmd/main.mbt)。本次全目录加载后预检以原有 24 GiB reserve 和 65% 门槛通过；仍不应调低门槛或伪造 free 值。OS 页回收效果及完整生命周期峰值没有由成功预检证明。

## 已执行的 N2 全目录门禁合同

1. 使用已建立的 [BONES N=2 配置](../examples/learning/g1-native-tensor-bones-catalog-gate.json)，保持 N2、H32、世界模型窗口8、history10、goal10、batch2、replay64、Float32、1 次 world/actor 和4次 critic 更新，并开启缓存 advice。这里的窗口8是模型拟合窗口，不是 goal_frames。使用全新输出目录和单 rank；本次未做 BONES DDP。
2. 固定现有真实 N2 工件 SHA `38d67d87cb0c9294fc7c9cb7635b6b9a88587f23a0036bdeb3cb6de2d1fb9b51`、运行时镜像/库/scene；manifest 指向 `private/bones-seed/aligned-g1-v1/manifest.paper-partial.json`，选 train split。先验证上述最终 SHA。
3. 容器维持 `--memory=48g --memory-swap=48g`、四 CPU、原 CUDA 设备；本机同一 GPU 不并行其他门禁。源码/CSV/bundle只读，旧缓存和新输出分别可写；保留活着的 cgroup 内部采样及退出证据。
4. 先调用 `preflight`；随后调用 `train --iterations 1 --checkpoint-format stream-v2`。训练调用自身会在加载全目录后重新预检。全量验证比 40 条小门禁慢，采用明确的有限整体 watchdog（准备预算最高 6 小时，再给一轮更新/保存 15 分钟），未完成即保留超时证据，不无限重试。
5. 核对 manifest SHA、137,289 catalog_count、固定窗口参考后端、actual memory guard、更新计数、stream-v2 指针及保存前 shared-state digest、容器 exit/OOM counters。本次记录为 physical=36、imagined=64、world=1、actor=1、critic=4；这不保证别的种子同样只采 36 步。单份 archive 的只读 schema/held-state 校验随后通过，但恢复后物理轨迹和 rank-local 对照仍未验收。

命令形态如下，路径参数在目标主机上先绑定真实文件；不要把占位符当成可直接执行的路径：

```text
aligned-gpu preflight --tensor-library TENSOR_SO --library MUJOCO_SO
  --scene G1_SCENE --manifest FINAL_PARTIAL_MANIFEST --config N2_BONES_CONFIG
  --physics-library APIC_SO --physics-artifact EXISTING_N2_MANIFEST
  --output FRESH_OUTPUT --checkpoint-format stream-v2

aligned-gpu train --tensor-library TENSOR_SO --library MUJOCO_SO
  --scene G1_SCENE --manifest FINAL_PARTIAL_MANIFEST --config N2_BONES_CONFIG
  --physics-library APIC_SO --physics-artifact EXISTING_N2_MANIFEST
  --output FRESH_OUTPUT --iterations 1 --checkpoint-format stream-v2
```

专用 [BONES 门禁 helper](../scripts/run_spark_native_bones_gate.mbtx) 在容器内核对训练 binary/config、数据及真实 N2 工件的固定身份、48 GiB 无 swap/四 CPU cgroup，再分别以 120 秒和 22,500 秒 watchdog 调用 preflight 与单 rank 一轮训练；保存 stdout、stderr、cgroup 前后快照及小结。它使用 `/workspace/moonrobo` 只读、`/motion-cache` 可写、`/gate` 为全新可写目录。本次 helper 和训练都 exit 0；helper 自身的结束检查不等于全生命周期内存峰值或上文后续完成的单份 archive 读回。现有 `run_spark_native_apic_ddp_gate.mbtx` 则绑定 40 条 LAFAN1 和两 rank，不能冒充本门禁。

## N>2 固定 GPU 门禁与剩余验证

**N2 工件不能通过修改配置复用于 N4。** 运行时要求 artifact.num_envs 等于配置 N，见 [runtime_bridge.mbt](../src/learning_aligned_gpu/cmd/runtime_bridge.mbt):202。需要为每个候选 N 重新真实导出 step/reset/context/refresh 四图并记录身份。

原有 N2 tape、ABI 和门禁仍保留；v2 路径支持 N4/N8 的 selected-world 有界 readback、对应 SDK 独立 oracle 及分块 audit。N4 与 N8 都已用真实四图工件执行 SDK oracle 与 native GPU selected trace，各有固定 27 个操作、8 个时间步；N4 选 world 0/2/3，N8 选 world 0/4/7，均在原 `1e-5 + 1e-5*abs(reference)` 规则下通过。**这只证明各自固定 trace；N2 已保留的容差失败未解决，不可据此声称全局物理等价。** 细节见 [N4](DGX_SPARK_APIC_EXPORT_PLAN.md#n4-real-graph-export-and-selected-world-gate-2026-10-24)和 [N8](DGX_SPARK_APIC_EXPORT_PLAN.md#n8-real-graph-export-and-selected-world-gate-2026-10-24)证据。

随后 179 上的 [N4 组合训练报告](../output/spark-runtime-20261024/native-bounded-n4/runs/native-bounded-n4-training-20261024-a/train/report.json)以 40 条 LAFAN1、真实 N4 APIC、Float32 CUDA learner 完成一轮：logical world/actor batch 均为 4，`wm_microbatch=pi_microbatch=2`，并启用 compact replay 与 bounded gather；全局计数为 72 physical、128 imagined、1 world、1 actor、4 critic 更新。它写入 stream-v2 `generation-1-1792799415522`。[Docker 结果](../output/spark-runtime-20261024/native-bounded-n4/runs/native-bounded-n4-training-20261024-a/docker-final.json)为 48 GiB、4 CPU、exit 0、`OOMKilled=false`；[外部只读监测](../output/spark-runtime-20261024/native-bounded-n4/runs/native-bounded-n4-training-20261024-a-memory/final-summary.json)观察到内核峰值 2,598,105,088 bytes、OOM 计数 0，**不是**完整生命周期或 CUDA 显存峰值。[单份 CPU 读回](../output/spark-runtime-20261024/native-bounded-n4/runs/native-bounded-n4-training-20261024-a-readback/stdout.log)在 8 GiB、2 CPU、无 GPU 容器内 exit 0，`held_state_attestation_verified=true`，但 `comparison_performed=false`。固定 [N4 组合配置](../output/spark-runtime-20261024/native-bounded-n4/examples/learning/g1-native-tensor-apic-n4-microbatch-gate.json)与 trainer SHA `1dd7a5f95017e3865489dbb65cec490934a82c87acaac5da7aad11fe971c4c27` 由报告绑定。这证明组合路径可执行一轮，不是 full-vs-split GPU 数值对照、节省内存的基准，也不是 BONES 组合训练或新 DDP 门禁。

随后 178/179 的 [N4 组合 DDP 门禁](DGX_SPARK_CONNECTX7_RDMA.md#bounded-n4-microbatch-two-host-gate)也完成一轮，仍使用 40 条 LAFAN1，而非 BONES 全库。两 rank 各 N4、logical world/actor batch 4、microbatch 2，启用 compact replay、bounded gather，分别完成 72 physical、128 imagined、1 world、1 actor、4 critic 更新，保存各自的 stream-v2 generation。[178 报告](../output/spark-runtime-20261024/native-bounded-ddp/178/runs/spark-native-bounded-ddp-gate-native-bounded-ddp-20261024-a/rank-0/train/rank-0/report.json)与 [179 报告](../output/spark-runtime-20261024/native-bounded-ddp/179/runs/spark-native-bounded-ddp-gate-native-bounded-ddp-20261024-a/rank-1/train/rank-1/report.json)的跨 rank 工作合计为 144 physical、256 imagined、2/2/8 次更新操作，仍只是**一次同步迭代**。两容器 exit 0、`OOMKilled=false`，NCCL 实际选择 `NET/IB/0`、`GDR 0`；[178](../output/spark-runtime-20261024/native-bounded-ddp/178/runs/spark-native-bounded-ddp-gate-native-bounded-ddp-20261024-a/rank-0/inside-result.json)与 [179](../output/spark-runtime-20261024/native-bounded-ddp/179/runs/spark-native-bounded-ddp-gate-native-bounded-ddp-20261024-a/rank-1/inside-result.json)容器内核峰值分别为 3,096,698,880、3,092,754,432 bytes，仅覆盖 helper 退出前的累计观测，不是完整生命周期或显存峰值。[独立 CPU archive 读回](../output/spark-runtime-20261024/native-bounded-ddp/178/runs/native-bounded-ddp-readback-20261024-a/stdout.log)确认 `shared_state_equal=true`、两边 `held_state_attestation_verified=true`，共享摘要 `983506230cbe4ce76350e1f51bf7da6b89f8935f8680c13af5068e040ac18505`；未对照 rank-local replay、RNG 或物理状态。这是组合 DDP 的小规模工程通过，不证明数值等价、内存节约、带宽或收敛。

179 上的 [N128 LAFAN1 训练报告](../output/spark-runtime-20261024/native-n128-lafan/runs/native-n128-lafan-20261024-a/train/report.json)再验证了较大固定配置：真实 N128 APIC GPU 物理、SMC99、Float32 CUDA learner、logical world/actor batch 128、microbatch 16、compact replay、bounded gather，在 40 条 LAFAN1 上完成一轮。计数为 8,448 physical、4,096 imagined、10 world、1 actor、20 critic 更新及 10,240 model-fit slots；保存 stream-v2 `generation-1-1792801245453`，catalog_count=40。[容器结果](../output/spark-runtime-20261024/native-n128-lafan/runs/native-n128-lafan-20261024-a/docker-final.json)为 64 GiB、4 CPU、exit 0、`OOMKilled=false`；[只读监测](../output/spark-runtime-20261024/native-n128-lafan/runs/native-n128-lafan-20261024-a-memory/final-summary.json)记录截至 helper 退出的内核峰值 2,325,794,816 bytes，OOM 增量为 0，并非完整生命周期或 CUDA 峰值。65% 准入与 24 GiB 物理 reserve 均未放宽；[单份 CPU 读回](../output/spark-runtime-20261024/native-n128-lafan/runs/native-n128-lafan-readback-20261024-a/stdout.log)记录 `verification_passed=true`、`held_state_attestation_verified=true` 和 shared digest `2d4897a5009f6781c9118ca9b199acd6223f315726ed12318680c4c47d4ae7ae`，但 `comparison_performed=false`。真实 N128 四图与 selected-world SDK trace 的范围见 [APIC 证据](DGX_SPARK_APIC_EXPORT_PLAN.md#n128-real-graph-export-and-selected-world-gate-2026-10-24)。LAFAN1 的 N128 成功不是论文 4096 环境规模或收敛证据。

### BONES N128 全目录门禁

178 上随后完成了 [BONES N128 全目录门禁](../output/spark-runtime-20261024/native-bones-n128/runs/native-bones-n128-20261024-a/inside-summary.json)：137,289 条 partial-filter 动作均完成 source/shard SHA 校验，分别读取 87,996,168,100 和 30,779,167,040 bytes，新建 shard=0、advice 失败=0，见[最终逐片进度](../output/spark-runtime-20261024/native-bones-n128/runs/native-bones-n128-20261024-a/trainer.stdout.log)。[训练报告](../output/spark-runtime-20261024/native-bones-n128/runs/native-bones-n128-20261024-a/train/report.json)记录真实 N128 APIC GPU 物理、Float32 CUDA learner、microbatch 16，完成 8,448 physical、4,096 imagined、10 world、1 actor、20 critic 更新和 10,240 model-fit slots；stream-v2 `generation-1-1792801872635` 保存 catalog_count=137,289。preflight 与 trainer 均 exit 0，加载后 65% guard 在原 24 GiB reserve 下通过。[Docker 结果](../output/spark-runtime-20261024/native-bones-n128/runs/native-bones-n128-20261024-a/docker-final.json)记录 64 GiB、4 CPU、无额外 swap、exit 0、`OOMKilled=false`；从 00:19:51.394Z 至 00:31:16.195Z 约 11 分 24.8 秒，主要包含全库校验与加载，不能当作纯训练速度。[只读监测](../output/spark-runtime-20261024/native-bones-n128/runs/native-bones-n128-20261024-a-memory/final-summary.json)在 helper 退出前观察内核峰值 2,678,452,224 bytes、OOM 增量 0；非完整生命周期或 CUDA 峰值。[独立 CPU 单份读回](../output/spark-runtime-20261024/native-bones-n128/runs/native-bones-n128-readback-20261024-a/stdout.log)确认 `verification_passed=true`、`held_state_attestation_verified=true`，shared digest `8ae0d48ce07045fa95f02ed71bc891eb160227b9493a59ffd7e5bea85e9a7618`，但 `comparison_performed=false`。这是一轮在全目录上抽样，不是全库 epoch、论文准确 129,514 集、收敛或续跑验证。

另一个独立 [full-vs-split GPU 数值比较](../output/spark-runtime-20261024/native-microbatch-numeric/runs/native-microbatch-numeric-20261024-a/microbatch/comparison.json) **未通过**：相同输入和初始状态下比较 234,377,294 个值，固定 `atol=2e-6`、`rtol=2e-4`，有 27 个值超差，均为两次 actor 更新后 critic-0 的 `kind0` 权重（11+16）；world 阶段和 actor probe 没有超差。此证据尚未定位根因，不能声称 microbatch 与 full batch 数值等价，也不能由该点采样推断节约内存。

当前各部分的状态和下一项验证：

| 负责范围 | 已实现及已有验证 | 后续验证 |
| --- | --- | --- |
| APIC bundle loader：[manifest.mbt](../src/learning_aligned/gpu_native/manifest.mbt)、[bundle_io.mbt](../src/learning_aligned/gpu_native/bundle_io.mbt)、[resources.mbt](../src/learning_aligned/gpu_native/resources.mbt) | 文件清单、单文件和总字节有界；64 KiB 流式 SHA；真实 N4/N8/N128 四图已加载并给出共享区/四图资源下界。 | scratch、mesh、JIT/module、分配器的实际资源仍待测。 |
| Native audit：[audit.mbt](../src/learning_aligned/gpu_native/audit.mbt)、[aot_solver.cpp](../src/learning_aligned/native/aot_solver.cpp) | N4 world 0/2/3、N8 world 0/4/7 与 N128 world 0/64/127 的真实 27 操作/8 步 GPU selected trace 均通过；保留 N2 v1。 | 其他动作/条件及 N2 差异成因。 |
| SDK producer/oracle：[oracle.mbt](../src/learning_aligned/producer/oracle.mbt) 及 export | 真实 N4/N8/N128 四图导出、独立 SDK oracle 与各自固定 trace 比较通过。 | 不能把三条固定 trace 推为普遍等价。 |
| CLI/launcher | 现有 128 上限、24 GiB reserve 和 65% guard 保留；BONES N2/N128 各一轮及单份 archive 读回已在 178 完成；LAFAN1 N4 组合 learner 单机一轮、两机 DDP 同步一轮与双份 shared-state 读回，以及 LAFAN1 N128 单机一轮及单份读回已完成。full-vs-split GPU 数值门禁已执行，27 个 critic 权重超差，判定失败。 | 定位并修复该数值差异；BONES 组合 DDP、N8 learner、rank-local/物理续跑语义及完整内存对照仍待执行。 |

现有 N2 manifest 的332个 shared region 合计654,497 bytes，四图对应共享副本仅给出一个下界；不包括 CUDA 图/模块、求解器 scratch、网格和分配器。不能据此把24GiB reserve调成几MiB。保持当前SMC模式和配置公式，仅 N/batch 从2改4时 planning peak 为30,968,476,672 bytes（约28.8416GiB）；N8为31,044,005,824 bytes（约28.9120GiB）。这是静态预算，不是新工件实测峰值或启动许可。

## 真正论文规模仍需独立完成的工作

现有限制包括 N/actor batch/world batch≤128、replay≤256、总 replay/staging≤16,777,216 values、reference gather≤131,072 frames，见 [configuration.mbt](../src/learning_aligned_gpu/cmd/configuration.mbt) 和 [runtime/batches.mbt](../src/learning_aligned_gpu/runtime/batches.mbt)。stream-v2 配套 lazy primitive slab live replay 与隔离恢复；reference gather 的主机准备已按最多 256 个样本分块、唯一帧读取与紧限额 scalar fallback；world/actor 可选 microbatch 保持原 logical batch。三项各有 CPU 窄验证，组合后已完成真实 N4 单机/两机、LAFAN1 N128 与 BONES N128 单机 CUDA/APIC 各一轮；**full-vs-split 的 GPU 数值门禁已执行但未通过，完整峰值、BONES 组合 DDP 与节省内存效果仍未验证**。这些改动没有放宽规模准入或保守内存门槛，详见 [checkpoint](../src/learning_aligned_gpu/runtime/CHECKPOINT_V2.md)、[gather](../src/learning_aligned_gpu/runtime/REFERENCE_GATHER.md)、[microbatch](../src/learning_aligned_gpu/MICROBATCH.md) 说明。

以仓库4096环境、replay1000、H32的规模配置作静态比较：replay有958,464,000个Double值，原始F64本身约7.14GiB；原对象/JSON 路径的旧保守 envelope 曾达500GiB，但不能再把该旧估计当成当前 slab 的实测峰值。33×4096=135,168参考帧仍超当前上限；Paper93维、critic5epochs下 policy batch 暂存约125,468,672 values也超上限。**不能通过直接升上限解决。** 已实现的 bounded gather 和可选 microbatch 没有更改完整输出形状、现有上限或 memory-plan 公式；N4/N128 门禁只证实相应配置可执行一轮。full-vs-split GPU 数值比较已发现 critic 权重超差，下一步需定位差异并分别验证 loss 归一化、GAE、critic 顺序及 DDP 平均/裁剪时序。

全库已有可扩展性成本也应实测：每个 reset 的 bin 概率和抽样目前扫描 B，host 读片仍使用单一 64 KiB 窗口；新 gather 在每个样本块内合并重复参考帧，但跨块/跨 clip 仍可能重复打开文件。DDP 每次同步 returns/average 约 16×B bytes、以 65,536 项切块。先记录 I/O、bin 数、prepare/collect/update 耗时，再考虑固定字节/FD 上限的 LRU；不要把整个动作库搬进 RAM 或 GPU。

方法、预算和物理等价需要分别验收：目前成功门禁采用SMC额外朝向观测、关闭自碰撞、按environment抽context；strict paper配置使用Paper观测、自碰撞和episode context，需要匹配工件与独立评测。完整目录的一轮运行只证明工程通路；不证明论文训练预算、收敛、未见动作泛化或Noetix E1可部署。APIC checkpoint仍是warm reset/refill，DDP resume仍拒绝，二进制保存成功不改变这些语义。

本轮 Linux 生产构建、全 BONES N2/N128 各一轮及单份读回、N4/N8/N128 固定 GPU trace，以及 LAFAN1 N4 组合 CUDA/APIC 单机和两机 DDP 各一轮、LAFAN1 N128 单机一轮与相应读回均已完成。两机 N4 archive 的共享 learner 状态相等；rank-local 状态尚未对照。full-vs-split GPU 数值门禁已有 27 个超差值，尚未通过。这些门禁仍不代表完整论文复现、内存节约或全局物理等价。
