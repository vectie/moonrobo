# SuperMimic 严格对照修正记录

2026-10-23。本次依据本地论文 `output/pdf/supermimic-2610.28480v1.pdf` 的 §3、附录 A/C/D/F，以及 `../smc/supermimic` 的实际源码继续修正。此前两轮 CPU smoke 只证明链路可执行，不能用 40/40 失败判定 GAE 或世界模型公式错误。本次执行上游原始函数进行数值对照，确认了配置、物理步长和随机化协议上的偏差，并修正实现。

## 已确认的问题与修正

| 问题 | 修正 | 验证 |
| --- | --- | --- |
| 默认 102 维扩展观测被混入论文配置 | 默认改为表 A.1 的 `paper` 93 维；`smc` 99 维和 `observable` 102 维需要明确选择 | 原始 `smc` 的 99 维观测及噪声逐值对照；三种模式独立保留 |
| CPU 使用 2 ms × 10 子步，与论文及 `smc` 的 5 ms × 4 不同 | CPU 默认改为 5 ms × 4，报告和 checkpoint identity 记录实际协议；GPU 拒绝不支持的步长 | 真实 MuJoCo 时间推进和执行器常数测试 |
| CPU 每次 reset 重采摩擦/COM，与 `smc` 每环境固定不同 | 显式区分 `episode` 和 `environment`；关节标定仍每次重置采样；CPU/GPU 共用配置语义 | 真实 CPU 物理参数与 GPU setter 协议测试；GPU 物理尚未执行 |
| 旧短测没有执行 `smc` 的 500 轮模型预热 | 新增独立 `smc` 配置和含 500 轮预热的 CPU 协议检查 | 前 500 轮只有模型更新，第 501 轮才开始 actor/critic；恢复测试跨越预热边界 |
| TF32 开关未在 runner 设置 | 明确设置 CUDA matmul/cuDNN TF32；论文配置不用 bf16，`smc` 配置启用 bf16 | 配置检查；本地 CPU 不能验证 CUDA 精度与性能 |
| 奖励和 critic 特征逐想象步重复 FK | 按 `smc` 对整个想象轨迹批量计算 | 8 步模型、32 步 actor/GAE critic 更新和 Adam 状态与上游逐值相同 |
| 动作插值额外预归一化四元数、采样计算顺序不同 | 恢复 `smc` 的原始插值和回报采样计算顺序 | 3 条完整真实动作的状态/速度逐值相同；固定种子采样区间相同 |

500 轮预热是 `smc` 的实现选择。论文 Algorithm A.1 写明模型和策略每轮更新，因此论文配置保持 `wm_only_iters=0`。两种协议没有合并成一个“完全一致”的配置。

## 当前三个配置

| 配置 | 观测 | 摩擦/COM | 自碰撞 | 精度 | 模型预热 | 用途 |
| --- | ---: | --- | --- | --- | ---: | --- |
| [g1-aligned-scale.json](../examples/learning/g1-aligned-scale.json) | 93 | 每 episode | 开 | FP32，CUDA 允许 TF32 | 0 | 论文方法与规模配置 |
| [g1-smc-scale.json](../examples/learning/g1-smc-scale.json) | 99 | 每 environment | 关 | bf16，CUDA 允许 TF32 | 500 | 相邻 `smc` 实现配置 |
| [g1-smc-cpu-protocol.json](../examples/learning/g1-smc-cpu-protocol.json) | 99 | 每 environment | 关 | FP32 | 500 | 小网络、小 batch 的 CPU 流程验证 |

三个配置均采用 8 步模型拟合、32 步想象、10 帧历史/预览和 5 ms × 4 物理子步。前两个使用论文网络规模与 4096 个环境；这些大规模计算尚未执行。论文没有给出全部实现细节，解析 heads、局部状态增量和软终止的具体形式仍参考 `smc`，不能将配置名称理解成官方代码复刻证明。

`observable` 额外的局部位置误差仍可用于独立消融。它能区分世界位置偏差，但引入定位输入；不属于论文表 A.1 的传感器观测。切回 `paper` 是严格遵循观测定义，并不证明原来的不可观测性疑问已从理论上消除。

## 数值对照证据

本轮 50 项 `test_aligned*.py` 测试通过，另有 4 项直接运行 `smc` 原始训练函数的差分测试通过。训练测试使用小网络和 CPU；论文规模结构使用 meta device 检查参数形状。详细学习证据见 [学习主干数值对照](G1_SUPERMIMIC_LEARNING_PARITY.md)。

- 8 步模型拟合、32 步 actor/GAE critic 的权重、梯度与优化器状态：指定相同输入/随机数下 `rtol=0, atol=0`。
- 14 身体 FK float32 对照逐值相同；奖励、critic 特征、奖励状态梯度的最大绝对差分别约 `4.95e-11`、`8.53e-10`、`1.83e-10`。
- 40 条真实 CSV 的哈希、形状和有限数值全部检查，共 264,705 原始帧、441,140 个 50 Hz 帧；3 条完整真实动作的状态/速度与原始 loader 逐值相同，预览最大差 `1.20e-7`。
- 真实 MuJoCo 连续训练 3 轮与 2 轮保存后恢复 1 轮的网络、Adam、replay、历史、随机数和计数逐值相同；第一轮模型预热，随后两轮实际更新策略。
- MoonData 的 12 项登记测试通过，缩小预算的协议检查仍登记为 `physics-simulation-method-smoke`。

保留的有意差异：近零/近竖直旋转数值修正；重复完成的采样 bin 使用均值而非末次覆盖；排除没有后继帧的终点；replay 恢复安全补采；非整除 critic batch 处理余数。合法 replay 起点的直接均匀抽样与上游拒绝抽样消耗不同随机数，因此上述局部逐值一致不是整次训练同 seed 一致的声明。GPU 测试使用模拟对象，不是 Newton/CUDA 执行证据。

## 新 CPU 协议运行

输出目录：`target/learning/g1-smc-protocol-check/`。采用 40 条 LAFAN1、2 个 CPU 环境、小网络，种子 0，训练含重置/观测/动作扰动。评测关闭噪声与域随机化，摩擦为 1，从各动作首帧执行至完成或相对参考终止。

| 指标 | 实测 |
| --- | ---: |
| 总迭代 / 仅模型预热迭代 | 510 / 500 |
| 物理训练转移 | 2,678 |
| 模型更新 / 拟合窗口转移槽位 | 1,020 / 65,280 |
| actor 更新 / 想象转移 | 10 / 1,280 |
| critic 更新 | 200 |
| world model / policy / critic 参数量 | 21,830 / 124,541 / 60,673 |
| 全协议评测动作 / 提前终止失败 | 40 / 40 |
| 归一化回报：逐动作均值 / 帧数加权 | 0.0016513354 / 0.0015723307 |
| 完整动作完成 / 严格 RMSE 通过 | 0 / 0 |
| 评测物理转移 | 1,764 |

训练数值有限，actor 尾值启用，流程和断点逻辑正常；尚未得到有效跟踪策略。十次小 batch actor 更新不能检验 `smc` 的收敛结果。相较旧短测，网络观测、步长、碰撞、随机化和预算同时改变，因此两个微小回报不能作为单因素提升或退化证据。

训练报告 SHA-256：`ab132a65485758cc70330630873f57d9f59928951345e5d2c0fb95eae9a18d4f`。
评测报告 SHA-256：`1068f98808d12890a9d396e45508cef671190400051f98a0a3f13575c1bb9755`。
Checkpoint SHA-256：`a47699d7fdda55f829d83fde443522e25f39ed0711a26856d085c321193b72f3`。

原生 replay 导出保留 53 段 episode、2,000 条训练转移，生成 276 个长度 8、stride 8 的训练窗口并通过 MoonBit reader 验证。2,678 是累计采集数，2,000 是容量为 1,000×2 的 ring buffer 最终保留数；两者没有混计。导出数据 SHA-256 为 `366e2bb5d59689d941af8238e97f5b1ece9730a630c107541648a594128d5561`。

已登记到现有 `target/learning/experiment-book/moondata`，ID 为 `supermimic-smc-protocol-check`，见 [登记回执](../output/research/g1-smc-protocol-registration.json)。重复导入/读取一致，完整存储校验 `passed`、`finding_count=0`。五个 payload 保存训练、评测、checkpoint、原生 dataset 和导出记录；没有虚构配对 baseline。`moon info` 完成，0 errors；本次未引入公共 API 变化，相关 MoonBit 包和脚本已格式化。

旧 `supermimic-aligned-smoke` 的 2 ms、102 维、两轮报告及哈希保持不变；它是历史实验，不代表当前配置。

## DGX Spark 与剩余执行工作

DGX Spark 可以作为世界模型与 actor/critic 的训练设备，也可运行 `smc` 和本仓库的 GPU 适配路径。NVIDIA 当前 Isaac Lab 3.0 明确支持 Linux aarch64 / DGX Spark，要求 CUDA 13 及匹配的 PyTorch；默认 Newton 后端无需完整 Isaac Sim 或 RTX 渲染。[官方安装要求](https://docs.nvidia.com/isaaclab/isaac-lab/installation)。

Spark 有 128 GB 统一内存、273 GB/s 内存带宽；公布的 1 PFLOP 是稀疏 FP4 指标，不能当作本任务 TF32/bf16 的训练吞吐。[官方硬件规格](https://docs.nvidia.com/dgx/dgx-spark/hardware.html)。模型权重本身较小，实际峰值取决于 4096 并行物理环境、replay 和 32 步反向传播保存的中间量。先用完整网络、缩小环境和 batch 的独立配置测一次物理采集、模型更新、actor/critic 更新及峰值内存，再确定规模和时间预算。

本仓库仍锁定与 `smc` 相同的 Isaac Lab commit，未在实际 Spark 上验证该旧依赖组合，也未自动升级到当前发行版。详见 [GPU 运行说明](G1_ALIGNED_GPU.md)。BONES-SEED 全库、GPU 物理/精度执行、相同训练预算的收敛对比和真实机器人部署仍未完成；不能报告论文成绩已复现。
