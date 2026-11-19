# 碰撞开启的 N2 论文方向方法门禁

本门禁是独立于旧 SMC99／关闭自碰撞工件的一次小规模方法验证，已通过固定序列物理对照、一轮原精度训练及一轮显式 TF32 训练。首轮使用固定的 40 条 LAFAN1 G1 重定向动作；原数据 manifest 的 SHA-256 为 `760c59585d792da74e9437f12dced4d216afd5d17411cf4bfa507ed51e6bc60f`。通过一轮训练只表明物理、学习、保存链路可执行，不能说明策略收敛、完整论文复现或 BONES-SEED 论文精确筛选集合。

## 隔离的场景与物理审计

新场景必须由真实 `self_collisions=true` 配置单独编译，不能只把旧 JSON 的布尔值改成 `true`：USD 转换器在关闭自碰撞时会写入 body-pair 过滤。父流程已在 179 上隔离生成以下资产；实际文件应从已验证的主机复制到运行主机，不修改旧路径。

| 资产 | 容器路径 | SHA-256 |
| --- | --- | --- |
| MuJoCo 场景 | `/workspace/moonrobo/data/g1_description-paper-self-collision/scene.xml` | `b9f8b0e0cbfa4a82c125ac330b38e1a8bf4c825252caf2c3d0dffe678ca5f7af` |
| USD | `/workspace/moonrobo/data/g1_usd-paper-self-collision/g1_29dof/g1_29dof.usda` | `7bba6e39dd3da53e5d0b8fa1466c2551f953066bb213d84decdb576eae159c1b` |

这份真实 USD 约 33 MiB。两个 helper 对该**单个静态 USD 输入**使用 64 MiB 文件长度上限及 64 KiB 分块 SHA-256；其他文件上限、cgroup 内存限制、物理数值容差和训练准入规则均未放宽。

导出配置为 [g1-apic-export-paper-n2.json](../examples/learning/g1-apic-export-paper-n2.json)，SHA-256 `b83c1957a45bd8d525d3ef0a0d8e48848343810e699b5c52e3129e9c656a323c`。这份原生转换的 USD 是展平的，默认 prim 没有 `Physics` variant set，因此 `usd_variants` 明确设为 `{}`；producer 会验证任何**实际请求**的 variant，不能把旧 USD 的 `Physics=mujoco` 配置冒充为新资产属性。容器内 helper 为 [run_spark_apic_paper_n2_gate.mbtx](../scripts/run_spark_apic_paper_n2_gate.mbtx)。它分三次调用 `export`、`oracle`、`replay`，各自在新 `/gate` 子目录保留命令、输入 SHA、cgroup 前后快照、进程退出码及结果。导出前要求 16 GiB、零 swap、最多四 CPU；宿主 launcher 还必须验证镜像 ID。helper 本身不启动容器，也不修改旧工件。

每次传入独立的 `PINS.json`，包含绝对路径的 producer／audit 可执行文件、实际二进制 SHA、镜像 ID、桥接库 SHA、上述场景和 USD SHA。`export` 使用原 SDK 作者镜像 ID `sha256:3f0487da0faaf353f14c43c8a135efad70c8a988e7735bba6b991fef0e50899c`、authoring bridge SHA `7bf09deb614960d820de6cdbbe127613d31c72da2d6af460b0e6bf943b150b52`。执行完读取 `/gate/export-evidence/exported-manifest-pin.json`，将实际四图 manifest SHA 加入后两步 pins。`oracle` 和 `replay` 均使用未修改的 N2 v1 tape，SHA `cb4ffbf27aac69d5b539484f85d94273252f1496d5df9796b8c9f4564a1db860`，在容器中置于 `/gate/tape-v1.json`。`replay` 改用实际 audit 可执行文件及 native runtime bridge SHA `6c5df912291754b37ac2c60a0b0c13253d2486e87c42ca20fb0ad19e910099e1`，再加入独立 SDK oracle 的实际 SHA。native audit 的 `--self-collisions true` 显式传给物理加载器，报告也写入选值；缺省 `false` 仅用于旧命令兼容。

若 N2 对照仍有数值失败，应保留原始 20 操作／8 步 tape 和原有容差并记录失败；不能为获得通过而换种子、扩大容差或沿用关闭碰撞工件。新碰撞开启工件的生成和数值对照并不能证明论文作者采用了同一物理自碰撞设置：论文公开的是删除自碰撞**奖励惩罚项**，未据此披露作者全部仿真配置。

## 单 rank 方法训练

[g1-native-tensor-paper-n2-method-gate.json](../examples/learning/g1-native-tensor-paper-n2-method-gate.json) 固定 Paper93、N2/B2、三层 2048 世界模型、8 步模型窗口、32 步想象、10 帧历史／预览、每轮 10 次世界模型更新、5×4 critic 更新、`wm_only_iters=0`、完整 batch 路径 `microbatch=0`、按 episode 更新物理 context、自碰撞开启、Float32。它依然采用当前实现的根部期望编码；该处与论文文字之间的歧义及具体 TF32 内核选择仍须单独核验。后文的独立 TF32 门禁已经验证库级精度设置。

训练 helper [run_spark_native_paper_n2_gate.mbtx](../scripts/run_spark_native_paper_n2_gate.mbtx) 的参数依次是 `TRAINER_ABSOLUTE_PATH TRAINER_SHA CONFIG_SHA TRUE_SCENE_SHA TRUE_USD_SHA TRUE_BUNDLE_MANIFEST_SHA`。当前配置 SHA 为 `e5be4369cac9c789059310fcc9ee86e624263591e243dceaf17732653ac338c5`；最后一项固定为本次碰撞开启导出的实际 manifest SHA `67f0e93f0a27527583bcc86c94b9f9334ce9824c505ab240ed664d41628822a0`。helper 指向隔离目录 `/workspace/moonrobo/runs/apic-paper-n2-20261024-c/g1-paper-n2-self-collision-apic/manifest.json`。它要求新 `/gate`、只读 `/workspace/moonrobo`、可写 `/motion-cache`、48 GiB／零 swap／四 CPU，先 120 秒 preflight，再最多 1200 秒训练，并验证原有 65% 准入和 24 GiB 物理预留。训练一轮后检查报告中的 10 次 world、1 次 actor、20 次 critic 更新、64 个想象转移、160 个模型拟合槽位，以及 stream-v2 保存的 40 条 catalog 数量。宿主 launcher 必须额外施加覆盖 helper 全生命周期的有界 watchdog 并验证镜像 ID；helper 记录的 cgroup peak 是**其退出前的观测值**，不是完整生命周期峰值认证。

截至本次修订，新 N2 export 有两份保留的失败证据：第一次在 producer 启动前被 helper 的 16 MiB USD 文件长度上限拒绝；第二次在 64 MiB cap 下通过所有输入 SHA，但 producer 在 GPU 前拒绝不存在的 `Physics` variant set，进程退出 1、无 OOM，观测 cgroup peak `146096128` 字节。修正后隔离的 `-c` 四图导出、SDK oracle 和 native replay 均实际退出 0，Docker 记录均为 `OOMKilled=false`。四图 [manifest](../output/spark-runtime-20261024/native-paper-n2/runs/apic-paper-n2-20261024-c/g1-paper-n2-self-collision-apic/manifest.json) SHA 为 `67f0e93f0a27527583bcc86c94b9f9334ce9824c505ab240ed664d41628822a0`，明确记录 N2、自碰撞开启、空 USD variant 映射及四图；[SDK oracle](../output/spark-runtime-20261024/native-paper-n2/runs/apic-paper-n2-20261024-c/sdk-oracle-paper-n2.json) SHA 为 `e9a4131834ec693645e917ad80190a994a27eb698350b460eeac552d63262663`。

[native replay 报告](../output/spark-runtime-20261024/native-paper-n2/runs/apic-paper-n2-20261024-c/replay-report-paper-n2.json)记录 `success=true`、`oracle_equal=true`、`oracle_comparison_performed=true`。原 N2 v1 tape 的 20 个操作包含 8 次步进；340 项 oracle 对照全部通过，绝对／相对容差仍为 `1e-5`，156 项本体一致性检查也全部通过。三个阶段观测到的 cgroup peak 分别为导出 `2697801728`、oracle `1384783872`、replay `425734144` 字节，均为 helper 退出前观测，不是完整生命周期峰值。此结果只覆盖这份新**碰撞开启**工件及固定序列，不能推出所有状态的物理等价，也没有修复或重新证明旧**碰撞关闭** N2 工件已知差异。

方法训练首次尝试因缺少 `/motion-cache` 挂载，在 preflight 前被 helper 拒绝，未进行 GPU 训练；该失败记录已保留。正确挂载后的独立 `-b` 尝试通过 preflight 和一轮训练，Docker 退出码为 0、`OOMKilled=false`。[训练报告](../output/spark-runtime-20261024/native-paper-n2/runs/native-paper-n2-method-20261024-b/train/report.json)的身份绑定 40 条 LAFAN1 manifest、新碰撞开启场景及四图 manifest，配置为 Paper93、N2/B2、episode context、完整 batch（microbatch 均为 0）。全局计数为 36 个物理转移、64 个想象转移、10 次世界模型更新、1 次 actor 更新、20 次 critic 更新及 160 个模型拟合槽位；[helper 摘要](../output/spark-runtime-20261024/native-paper-n2/runs/native-paper-n2-method-20261024-b/inside-summary.json)核对 stream-v2 保存的 catalog 数量为 40。实际 cgroup 为 48 GiB、零 swap、四 CPU，OOM 计数为 0，退出前观测峰值 `2306777088` 字节；两次 65% 准入计划均保留 24 GiB 物理预留。这一峰值不是完整生命周期或更大 N 的内存基准。

独立的[CPU 只读 checkpoint 读回](../output/spark-runtime-20261024/native-paper-n2/runs/native-paper-n2-method-20261024-b/readback.json)退出 0，`verification_passed=true`、`held_state_attestation_verified=true`，共享状态摘要为 `d8e9b869eb83b327374ea8586104766b216f46f87cf762160f81c3c96e1e6539`；`comparison_performed=false`、`rank_local_state_compared=false`，因此不能称为跨 rank 或续训数值等价验证。一轮工程门禁不构成策略收敛、完整 BONES-SEED 训练、论文精确配置或 Noetix E1 迁移验证；旧碰撞关闭 N2 数值差异也仍为独立问题。

## 显式 TF32 训练与九阶段遥测

2026-10-24 09:45（北京时间），179 的独立 `native-paper-tf32-method-20261024-a` 运行通过。新配置 [g1-native-tensor-paper-n2-tf32-method-gate.json](../examples/learning/g1-native-tensor-paper-n2-tf32-method-gate.json) 只在上面的固定 N2 方法配置上增加 `allow_tf32=true` 和独立 profile 标签；旧配置、旧插件及旧结果均保留。新 CLI 在任何 tensor 或 NCCL 控制张量之前设置 CUDA matmul、cuDNN convolution、cuDNN RNN 的 FP32 精度策略，并把请求、读取结果与环境覆盖许可绑定到运行身份、报告和 checkpoint；缺省不调用可选扩展。三项均读取为 `TF32`、`LibraryMayUse`。这证明库设置生效，不能证明每个算子实际选择了 TF32 内核。

受信构建 trainer SHA 为 `70dafce2a90274c3b1bc110d6049bbb36fb995f6b6e0e08e4ed1a42ca9d583f6`，helper SHA 为 `08115824373a0c7f03bc37cfba7939e0ceb635054bc31511bd61ba3a20311253`，插件 SHA 为 `6ea1b0e0292a7ab97cd2aad0d4c9fde54745974d4cc9a5914b08949a0913475a`。原 runtime 镜像 `9d517324…cac3b`、新碰撞场景及四图身份不变。容器 `6c9c7f2a…b116a3` 使用 48 GiB／零 swap／四 CPU，独立最长 1350 秒 watchdog；实际约 30 秒退出 0，`OOMKilled=false`。保留 65% 准入及 24 GiB 物理预留。

[helper 摘要](../output/spark-runtime-20261024/native-paper-tf32/runs/native-paper-tf32-method-20261024-a/inside-summary.json)核验 36 个物理转移、64 个想象转移、10 次 world、1 次 actor、20 次 critic 更新、160 个模型拟合槽位和 40 条 catalog。[训练报告](../output/spark-runtime-20261024/native-paper-tf32/runs/native-paper-tf32-method-20261024-a/train/report.json)保存九阶段 CUDA 遥测：窗口 allocated peak `282415104` 字节、reserved peak `316669952` 字节，边界最低 CUDA free `69675134976` 字节；helper 退出前 cgroup 观测峰值 `2305785856` 字节。allocator、设备空闲、cgroup 是不同口径，不能相加，也不能外推大规模峰值或当作完整生命周期认证。同步遥测影响计时，本次不报告加速比。

generation 为 `generation-1-1792806347752`。独立 8 GiB／零 swap／两 CPU、无 GPU 的[只读读回](../output/spark-runtime-20261024/native-paper-tf32/runs/native-paper-tf32-method-20261024-a/checkpoint-readback.json)实际验证网络、Adam 和归一化摘要，`verification_passed=true`、`held_state_attestation_verified=true`，共享摘要 `775308bb07ee856b60eed8ba6b16905b1de469c9dd1365a4ce0091a19881d1c1`；仍未进行跨 rank 对比或续训等价验证。仅元数据证据归档 SHA 为 `8ab6558efcfc282c8e1335bf652316c8d737c901cdd78881cff3373e1bc016e3`，本机不复制大型权重或 motion cache。
