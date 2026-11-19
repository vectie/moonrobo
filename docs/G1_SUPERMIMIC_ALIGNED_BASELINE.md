# SuperMimic 方法对齐基线

本轮新增 `providers/motion_learning/aligned/`，把论文的学习问题和训练主干作为独立基线实现。已取得并加载 40 条真实 LAFAN1 G1 重定向动作，跑通 CPU 物理采集、8 步模型拟合、32 步策略想象、GAE critic 更新和所有 40 条动作的完整协议评测。两轮 smoke 的 40 条动作全部终止失败，证明的是端到端链路可执行，尚未获得有效跟踪策略。

后续严格对照已修正默认观测、CPU 物理步长、随机化周期和配置混用，并完成 500 轮模型预热后的 10 次策略更新。当前配置和新结果以 [严格对照修正记录](G1_STRICT_REFERENCE_AUDIT.md) 为准；下文两轮 noisy smoke 的原始数字和 SHA 保留为历史证据。

旧的九条程序化参考、参考姿态残差动作、冻结踝部反馈和无尾值实验仍按其原始定义解释。新基线的代码实现、CPU 端到端验证、完整训练效果以及 GPU 性能证据分开报告。

依据是本地论文 `output/pdf/supermimic-2610.28480v1.pdf` 的 §3、§4 指标定义、附录 A/C/D/F，以及相邻 `../smc/supermimic/` 源码。使用 `smc` 的 MIT 授权代码作为实现参考，代码保留在本仓库，运行不依赖相邻仓库。论文主实验使用 MuJoCo Warp；`smc` 使用 Isaac Lab 3 的 kit-less Newton/MuJoCo-Warp 后端，并非 PhysX。本仓库的 CPU MuJoCo 适配器和该 GPU 后端应分别标识。

## 差距与实现位置

| 差距 | 新基线的定义与实现 | 证据边界 |
| --- | --- | --- |
| 数据 | `motion.py` 读取 G1 重定向轨迹、统一到 50 Hz、导出根部/关节与 14 个身体的姿态和速度，并保留动作来源；真实动作目录与程序化测试参考分开 | 数据导入通过不等于 BONES-SEED 129,514 条过滤集合已经取得，也不等于未见动作泛化 |
| 共同主干 | 世界模型自回归 8 步拟合、32 步想象、10 帧观测历史、10 帧未来参考 | 小规模 smoke 可以验证执行顺序和梯度；训练预算、并行规模另行记录 |
| 策略目标 | `learning.py` 实现想象奖励累积、软存活权重及末端 critic bootstrap；世界模型和 critic 的参数在 actor backward 时冻结，保留对其输入的梯度 | 默认恢复尾值；旧无 critic 消融的结论不能替代新方法结果 |
| Critic | 同一想象轨迹上的 GAE/λ-return，末端值启动逆序递推；目标一次计算并 detach，随后多轮更新 critic | 实际物理回报不作为新基线的 critic 监督目标；默认 γ=0.99、λ=0.95、5 epochs×4 minibatches |
| 奖励 | `mdp.py` 包含身体位置、朝向、线速度、角速度，根部位置、朝向以及动作差分、软关节限位项 | 奖励尺度/权重与表 A.2 对齐；身体参考 XY/yaw 重锚定和局部增量表示沿用 `smc`，属于具体实现选择 |
| 动作 | `robot.py` 和物理适配器采用 `q_sp=q_default+Δq_calibration+α*a`，按关节电机参数确定低增益 PD、力矩上限及动作缩放 | 动作不再以当前参考关节角为中心；真实硬件执行尚需另行验收 |
| 终止 | `mdp.py` 使用相对参考高度误差 >0.25 m、重力方向 Z 分量差 >0.8；想象中使用 sigmoid 软化的存活概率 | 精确低姿态/侧躺参考不会仅因绝对高度或绝对倾斜被终止；sigmoid 温度是显式实现参数 |
| 采样 | `sampling.py` 以动作时间区间维护回报，混合均匀、当前困难度和历史困难度采样；物理 reset 使用该采样器 | Replay 起点本身仍按有效转移采样，这是论文/`smc` 的训练主干；不能将“按区间重置”描述为“actor 各动作均衡” |
| 模型与可观测性 | `networks.py` 默认世界模型 2048×3、策略编码器/解码器 2048/1024/512/256、32 维 latent、critic 256/128；`mdp.py` 显式区分 paper93、smc99、observable102 | observable102 额外输入相对参考朝向和局部根部位置误差，消除世界位置/朝向目标的瞬时信息缺口；这是需要状态估计的扩展，不冒称表 A.1 的 93 维传感器配置 |
| 评测、预算与恢复 | `evaluation.py` 从每条动作首帧执行完整时长，报告归一化回报和训练终止失败数；旧逐项 RMSE 独立列出；runner 单独统计物理步、想象步和更新次数，并保存完整恢复状态 | 完成一次短训练和所有动作评测仅能证明链路可执行；不能证明论文回报、零失败、GPU 吞吐或样本效率 |

## 奖励和观测的具体语义

每个 20 ms 控制步最多获得 `0.1` 跟踪奖励：四项身体跟踪各权重 1，根部位置/朝向各权重 0.5，最后乘以 `dt=0.02`。位置标准差为 0.3 m、朝向 0.4 rad、身体线速度 1.0 m/s、角速度 3.14 rad/s。动作变化的平方和乘以 −0.1，软关节限位越界量乘以 −2。去除自碰撞**惩罚项**不意味着关闭物理自碰撞。

默认 `paper` 模式保留表 A.1 的 93 维输入；`smc` 模式增添 6 维相对参考根部朝向；实验性 `observable` 进一步增添 3 维机器人局部坐标下的根部位置误差，共 102 维。102 维模式通过显式相对输入区分世界根部位置偏差，需要能估计该量的定位链路；这不是论文默认输入，现有 IMU、关节位置和历史本身并未证明能够恢复绝对 XY。

世界模型的状态为 71 维，使用根部位置/四元数、根部世界线/角速度、29 关节角和速度。这个排列与旧实验的原始状态排列不同，不可直接互换旧 checkpoint 或轨迹。模型回归局部坐标下的增量，再用旋转群积分得到下一状态；输入/输出归一化随模型一起保存。

## 完整动作评测

论文 §4 定义归一化回报为完整 episode 的未折扣奖励和除以最大可得奖励。附录 F.1 规定每条动作从第一帧执行，摩擦系数 1.0、关闭域随机化和观测噪声、使用确定性策略及物理；失败由训练时的终止条件判定。`smc/evaluate.py` 使用如下离散分母，本实现保持同一口径：

```text
R_normalized(clip) = sum(executed rewards) / ((reference_frame_count - 1) * 0.1)
```

提前失败仍使用完整动作分母。负回报不截成 0，因为动作和关节限位惩罚可能使总奖励为负。报告同时提供逐动作等权均值 `norm_return` 与按完整动作步数加权的 `norm_return_framew`，两者不能混写。`n_failed` 只统计训练终止；提前 timeout、动作遗漏单列并使 `benchmark_complete=false`。最后一步触发终止仍算失败。

额外的严格门槛为完整时长、无失败，以及关节 RMSE≤0.03 rad、身体位置 RMSE≤0.05 m、根部位置 RMSE≤0.05 m、根部朝向 RMSE≤0.1 rad。它使用未重锚定的世界位置误差，属于平台工程验收，不用于替换论文的失败指标。`per_clip` 保存分母、实际步数、回报、终止位置和这些额外误差，避免仅展示平均值。

评测调用接口：

```python
report = evaluate_policy(
    eval_env, learner.pi, hist=10, goal_frames=10,
    max_step_reward=0.1, strict_tracking=True,
)
```

`eval_env` 必须启用 `eval_mode=True, auto_reset=False`。顺序评测当前要求单环境；训练的 10 s timeout 在评测模式下关闭。评测不会更新策略的归一化统计，并在结束时恢复策略原有 train/eval 状态。

## 与 `smc` 的关系

保留其与论文接近的主干：解析 MDP heads、局部状态增量、完整动作分母、低增益关节控制和想象 GAE。解析 reward/observation/termination heads 在论文 §3.2 的方法范围内；想象终止的 sigmoid 形式来自 `smc`，并非论文指定的唯一实现。

显式记录的差异包括：93/99/102 维观测按配置选择；使用本仓库 MuJoCo 资产计算 FK；CPU MuJoCo 验证与 GPU 后端分别报告；小网络和小 batch 仅用于 smoke；混合精度选择不能默认等同于论文 TF32。论文与 `smc` 的预热、碰撞和随机化周期使用独立配置。`smc` 的 0.829、0/40 属于其 README 的作者报告，未经本地 checkpoint 复验，不能写成本平台结果。

数据覆盖遵循论文附录 F 的限制：在训练动作上评测，说明训练集合覆盖程度；只有明确分离的 held-out 动作才能支持未见动作泛化结论。40 条 LAFAN1 和 129,514 条 BONES-SEED 也不是同一个评测集。

## 计算量与验证记录

每份训练报告应同时保存物理转移数、世界模型拟合更新/窗口步数、actor 更新、想象转移数、critic 更新、评测物理步数和墙钟时间。世界模型展开和 actor 想象展开不混为同一个样本计数，CPU 短测墙钟时间不转换为论文 GPU 加速比。评测分别保存实际参与指标的 `evaluation_physical_steps` 和包含 GPU 冗余副本的 `evaluation_simulated_physical_steps`；额外 GPU 副本是计算开销，不算新评测试验。

2026-10-23 的最终匹配机器人 CPU smoke 记录在 `target/learning/g1-aligned-noisy-smoke/report.json` 和 `evaluation.json`，训练时包含重置姿态/速度扰动、观测噪声和动作噪声，评测时关闭噪声与域随机化。物理模型由数据集对应 URDF 编译，scene SHA-256 为 `5230533e1aea5593de5d57146412cb4ae62ca356eef2bbee63224a165d0ce699`，MuJoCo 3.3.7，开启自碰撞。CPU 适配器运行时将模型 timestep 设为 2 ms，因此每个 20 ms 控制步实际执行 10 个子步；场景编译 receipt 的 5 ms 和 GPU 后端的 4 个 5 ms 子步不能代替这个实际 CPU 设置。结果如下：

| 项目 | 实测结果 |
| --- | ---: |
| 训练迭代 | 2 |
| 真实训练转移 | 90 |
| 世界模型更新 / 拟合窗口转移槽位 | 4 / 256 |
| actor 更新 / 想象转移 | 2 / 256 |
| critic 更新 | 8 |
| world model / policy / critic 参数量 | 21,830 / 126,461 / 60,673 |
| 从首帧执行的动作 | 40/40 |
| 训练终止失败 | 40/40 |
| 归一化回报逐动作均值 | 0.0018538790 |
| 归一化回报帧数加权均值 | 0.0017664222 |
| 完整时长完成 / 严格 RMSE 合格 | 0 / 0 |
| 实际物理评测转移 | 1,756 |

`benchmark_complete=true` 表示全部请求动作均按完整协议执行至结束或训练终止，并不表示动作跟踪成功。每个提前终止的动作仍使用完整动作长度作为回报分母。此运行的训练阶段墙钟约 1.05 s，计时起点在模型和动作加载之后、包含环境初始化，且不含随后评测；它不能用于 GPU 吞吐或完整准备成本比较。初步 `g1-aligned-smoke` 运行缺少训练重置扰动，保留作过程记录，以上数据以最终 `g1-aligned-noisy-smoke` 为准。

最终训练报告 SHA-256 为 `000bc3021f6ec894f4adbfc3a730d7e09d85e1cccb08fae72c3c4843e4dd0786`；评测报告 SHA-256 为 `39746d97ce4d733b3c1bafbc4024244d0719848268c15542d80810458d221723`。它们绑定同一个 checkpoint SHA-256 `c895ce19ba63bebbb59f5f5f5fbf3693a1edce7ba21268c92139f1bfb0dd580f`。

数据 manifest 为 `target/learning/g1-aligned-data/manifest.json`，SHA-256 `760c59585d792da74e9437f12dced4d216afd5d17411cf4bfa507ed51e6bc60f`。固定来源修订为 `ce1572906efe6157840e8474d5a0d7aa87481e74`，40 条 CSV 共 264,705 个 30 Hz 原始帧、90,487,276 字节；运行实际加载 441,140 个 50 Hz 帧。训练/评测均为同一 40 条动作，held-out 集合为空。BONES-SEED 的获取、重定向、论文过滤集合和大规模训练仍未完成。

已完成的 9 项评测回归测试覆盖：提前失败保持完整分母、负回报、末帧终止、提前 timeout、动作集合遗漏/重复、严格 RMSE 与论文失败指标分离、不同动作的历史隔离、策略模式恢复、训练环境误用拒绝、部分动作选择不冒称全库，以及 GPU 冗余副本的计算量统计。另有 MDP/FK、GAE、buffer/sampler 和恢复测试；它们的运行与真实 GPU 物理验证须区分。GPU 依赖和本地验证边界见 [GPU 运行说明](G1_ALIGNED_GPU.md)。

真实 MuJoCo 恢复回归 `test_aligned_resume.py` 已通过：同一真实动作、含重置扰动，连续 3 轮与 2 轮保存后恢复 1 轮的网络、优化器、归一化统计、replay、历史、随机数和计数完全一致（张量 `rtol=0, atol=0`）。测试用较小网络隔离恢复行为，耗时约 4.66 s。这是一次 CPU 恢复证据，不覆盖 GPU Newton 求解器断点。

尚未关闭的科学与部署差距包括：BONES-SEED 全集合准备、论文规模 GPU 实际训练、与 `smc` 相同预算的收敛比较、GPU 运行/吞吐验证、未见动作泛化，以及真实机器人状态估计和执行验收。本次没有证据支持“所有差距已经消失”或“论文效果已复现”。

## 运行入口

`scripts/prepare_g1_aligned_data.mbtx` 按固定修订取得 G1 重定向数据和机器人描述，为每条动作保留文件哈希、来源、帧率和 split 声明。`MotionLib.from_manifest` 可校验同一格式的外部 G1 动作 catalog；原始人体 BONES 数据仍需先重定向到约定的 29 关节格式。

```sh
moon run --target native scripts/prepare_g1_aligned_data.mbtx \
  /Users/kq/Workspace/moonrobo/target/learning/g1-aligned-data
```

准备物理资产后，使用 `scripts/run_g1_aligned.mbtx` 启动同一 learner。参数中的输出目录应为新实验目录。默认解释器是仓库的 `target/learning-venv/bin/python`；若使用已准备的 GPU 环境，可在仓库路径后、训练参数前传入 `--python /path/to/gpu/python`。

```sh
moon run --target native scripts/run_g1_aligned.mbtx \
  /Users/kq/Workspace/moonrobo \
  --config examples/learning/g1-aligned-cpu-smoke.json \
  --motion-dir target/learning/g1-aligned-data/lafan1_g1 \
  --scene target/learning/g1-aligned-data/g1_description/scene.xml \
  --output target/learning/g1-aligned-smoke \
  --backend mujoco --evaluate
```

CPU smoke 配置为 2 个物理环境、2 个迭代、世界模型 64×3、策略 64×2、critic 64/32、每次 4 条 H=32 想象轨迹。它保留 8/32/10/10 的时序结构，但训练预算与论文相差很大。完整配置 `examples/learning/g1-aligned-scale.json` 提供论文规模网络、4096 环境、4096 条想象轨迹、世界模型每次 10×2048 个 8 步窗口、critic 5×4 更新和 UTD=0.4；配置文件的存在不表示这些计算已经执行。

恢复时添加 `--resume <checkpoint.pt>`；`--iterations` 是累计目标迭代数。CPU 检查点包含网络、优化器、归一化统计、真实 replay、随机数、控制历史、区间采样器和 MuJoCo 积分状态。GPU 适配器不能恢复完整 Newton 求解器状态时明确标记 `warm-reset-refill`：重置物理后重新收集足够长的 replay，再开始 8 步拟合，不沿用旧 buffer 与新物理状态拼接出的窗口。它不能被描述为逐位相同的断点续训。

## MoonData 登记

最终 noisy smoke 已登记到 `target/learning/experiment-book/moondata`，实验 ID 为 `supermimic-aligned-smoke`，登记回执为 [g1-aligned-registration.json](../output/research/g1-aligned-registration.json)。完整 MoonData 存储校验通过，`finding_count=0`；重复导入和从存储重新读取得到相同结果。原始训练、评测报告的 SHA-256 与上文一致，登记过程未改写它们。

该记录保存原始训练报告、40 条完整动作评测报告、完整 checkpoint、原生数值 dataset 和导出验证记录，共 5 个证据 payload。证据类型明确为 `physics-simulation-method-smoke`，硬件执行权限为 false。已有候选 schema 要求配对 baseline，并使用与本报告不同的指标，因此这里保留空 `candidates`，通过原始 payload 提供新指标与计数；没有伪造 baseline、训练成功或旧质量门槛结果。旧版候选物理轨迹视图不适用于此记录。

checkpoint replay 导出得到 3 段训练 episode、90 条物理转移；MoonBit 原生 reader 验证所有数值和边界，生成 12 个长度 8、stride 8 的完整窗口。导出显式将 aligned 71 维状态转换为编译后 MJCF 的 qpos/qvel，按关节地址重排，根部世界角速度旋转为 MuJoCo 的局部角速度；归一化动作转换为实际 PD 位置目标。观测和预览由保存状态重建为无噪声特征，不能称为原始带噪声观测录制。原始随机数、控制历史及网络恢复状态仍保存在 checkpoint；导出数据仅含保留的训练 replay，没有增加 held-out 动作或物理评测轨迹。

```sh
moon run --target native scripts/register_g1_aligned.mbtx \
  /Users/kq/Workspace/moonrobo \
  /Users/kq/Workspace/moonrobo/target/learning/g1-aligned-noisy-smoke \
  /Users/kq/Workspace/moonrobo/target/learning/g1-aligned-data/lafan1_g1 \
  /Users/kq/Workspace/moonrobo/target/learning/experiment-book/moondata \
  supermimic-aligned-smoke \
  /Users/kq/Workspace/moonrobo/output/research/g1-aligned-registration.json
```

适配没有修改 MoonBit 公共接口。登记包的 12 项测试通过；数值学习/状态转换的 7 项测试通过；动作数据/采样的 5 项测试通过，包括不构造全库 FK 缓存时预览特征逐值相同的检查。`MotionLib` 的轻量加载仅供导出，训练与评测默认仍计算完整身体 FK。

## 2026-10-24：原生实现的论文对照边界

本节核对 MoonBit 原生 CUDA learner、APIC 物理接口和当前配置。上文 Python CPU smoke、Python/`smc` 局部数值对照及恢复结果保留为历史证据，不能作为原生 CUDA 数值等价或 APIC 精确恢复的证明。最新原生运行与全量目录证据见 [原生 BONES 规模准备记录](NATIVE_BONES_SCALE_READINESS.md)：LAFAN1 与 BONES 的 N128 单轮门禁采用 SMC99、关闭物理自碰撞、按 environment 固定物理 context，以及 microbatch 16；执行和保存成功不等于严格论文配置或收敛。

### 根部奖励与目标编码尚有定义边界

[本地论文](../output/pdf/supermimic-2610.28480v1.pdf)第14页表 A.2 的根位置奖励为 `exp(-||p_root_des - p_root||² / 0.3²)`，根朝向奖励为 `exp(-||log(R_root_des R_rootᵀ)||² / 0.4²)`，两者权重均为 0.5。这是完整位置向量和完整 SO(3) 朝向的误差，不能改述为仅高度或仅倾斜。**表格及附录 A 没有明确 `des` 量的坐标系和预先重锚定规则**，因此不能仅凭公式断言作者实现必然直接比较绝对世界坐标。

我们与 `smc` 的具体选择则可从源码确认：[原生 GPU 奖励](../src/learning_aligned_gpu/geometry/context.mbt)直接用 `reference.p - state.p` 和完整根部朝向计算上述两项。身体位置/朝向另行按机器人 XY/yaw 重锚定；这不改变根部奖励的世界坐标比较，也不会给 actor 增加输入。

[观测实现](../src/learning_aligned/mdp.mbt)中，Paper93 只有表 A.1 的本体传感器和上一动作；SMC99 增添完整相对参考朝向的六维表示，因而包含 yaw 信息，**仍不包含根部 XY 误差**。Observable102 再加入机器人局部坐标下的三维根位置误差，是需要定位/状态估计支持的扩展，不能标为论文默认输入。

[参考 goal](../src/learning_aligned/motion.mbt)仅由当前和未来参考状态构造；它以当前参考的 heading 变换未来参考，不接收机器人根状态。[原生 collector](../src/learning_aligned_gpu/runtime/train.mbt)只将相应观测存入十帧 history；[GPU reset 协议](../src/learning_aligned/gpu_protocol/environment.mbt)将机器人置于参考附近并加噪，没有重锚定参考库或向 goal 注入根部偏差。因而未发现 history、FK 或物理运行时暗中补齐这一信息的路径；有限历史也不能普遍辨识所有时刻共同增加的未知 XY 平移。

本次只读核对运行了已有[最小观测回归](../src/learning_aligned/data_mdp_wbtest.mbt)，1/1 通过：机器人平移20 cm 后 Paper93、SMC99 观测逐项不变，Observable102 会变化。这是该输入定义的局部性质，不是对论文作者实现的反证，也不能把所有跟踪失败都归因于它。在获得论文目标编码/坐标约定的进一步依据前，应明确记录沿用 SMC 参考编码的假设；不能擅自加入 XY 或删去根部奖励后仍称严格原样复现。

### 已实现主干与尚未验证的原生部分

| 项目 | 当前原生实现及证据边界 |
| --- | --- |
| 动作 | [默认姿态加关节缩放动作](../src/learning_aligned/robot.mbt)为 `q_sp = q_default + calibration + alpha * action`；不再使用参考姿态残差或冻结踝部反馈。对应附录 A 的动作主干；完整执行器/求解器参数仍需分别记录来源。 |
| 奖励与终止 | 身体位置、朝向、线/角速度、根部跟踪、动作差分和软关节限位均存在；[相对参考终止](../src/learning_aligned/mdp.mbt)为高度差 >0.25 m 或重力 Z 分量差 >0.8。解析 heads 属于论文 §3.2 允许的方法范围；身体重锚定和 sigmoid 温度是 SMC 的具体实现选择。 |
| 策略与 critic | [原生 learner](../src/learning_aligned_gpu/learning.mbt)按 §3.3 式(2)累积软存活加权想象奖励和 critic 尾值；按式(3)对想象轨迹逆序生成固定、已 detach 的 GAE/λ-return 目标，再更新 critic。实际物理折扣回报没有替代该监督目标。局部世界模型增量、归一化误差权重及参考特征编码仍不能宣称由论文唯一规定。 |
| TF32 | [四模式 CUDA 探针](../src/learning_tensor/TF32.md)与[独立 N2 TF32 训练/CPU 读回](PAPER_N2_COLLISION_METHOD_GATE.md#显式-tf32-训练与九阶段遥测)均通过。CLI 在首个 tensor/NCCL 控制张量前设置三项 FP32 策略，并绑定请求、读取值和环境许可到身份与 checkpoint；缺省保留原行为。三项读取 TF32/LibraryMayUse 不等于已证明每个算子的实际内核分派；训练效果及速度未验证。旧冻结插件及数值对照保持原样。 |
| 物理自碰撞 | 论文第13页只明确删除自碰撞**奖励惩罚**，没有声明关闭物理碰撞。新建碰撞开启的 MJCF、展平 USD 和 N2 四图工件，绑定全部身份后，[真实 SDK 与原生固定序列对照](PAPER_N2_COLLISION_METHOD_GATE.md)通过，原 `1e-5` 容差未变。去除这项 SMC 明示偏离不等于已经知道作者完整求解器配置，也不证明其他动作或旧关闭碰撞工件数值等价。 |
| 微批数值 | [实际 CUDA full/split 数值门禁](../src/learning_aligned_gpu/MICROBATCH_GATE.md#actual-cuda-result-numerical-comparison-failed)固定容差下27个 critic 权重超差，仍判定未通过。后续记录了第一轮 actor 的20次实际 critic 更新，并逐项复现各自模式的原始最终状态；首次超差发生在第5次 Adam 更新，最终复现该轮11个超差权重。采样顺序和实际归一化输入索引一致，尚未确定具体底层算子的根因；不能因单轮训练成功或修改容差而改写原结论。 |
| 数据与预算 | 当前137,289条 BONES 接受集的来源和全目录加载可追溯，但不是论文129,514条准确过滤集合；[缺失过滤定义](BONES_SEED_PAPER_FILTERS.md)仍需明确。单轮 N128、batch128 和 replay256 也不是论文每 GPU 4096环境、世界模型 batch2048、actor batch4096、replay1000及完整训练预算。 |

### 已完成最小方法门禁与剩余差距

179 已完成单 rank、N2、world/actor batch2 的一轮方法门禁，保持论文网络宽度、8步模型窗口、32步想象及10帧历史/预览，显式设置 `wm_batches=10`、`critic_epochs=5`、`critic_minibatches=4`、`wm_only_iters=0`、`observation_mode=paper`、`context_resampling=episode`。world/actor 的 `microbatch=0` 保留未切分执行路径；这不解决目标编码的论文歧义。已有 [stage128 模板](../examples/learning/g1-native-tensor-stage128.json)只有 WM1/critic1，不能不改更新次数就当作上述配置。

碰撞开启的新 N2 工件先通过真实 SDK 固定序列和 native replay，随后连接 learner。[实际方法门禁](../output/spark-runtime-20261024/native-paper-n2/runs/native-paper-n2-method-20261024-b/inside-summary.json)完成36个物理转移、64个想象转移、10次 world、1次 actor、20次 critic 更新和160个模型拟合槽位；40条 LAFAN1 catalog 保存成功。[独立 CPU 读回](../output/spark-runtime-20261024/native-paper-n2/runs/native-paper-n2-method-20261024-b/readback.json)实际解码网络与 Adam 状态并验证共享状态摘要。此处没有执行完整动作评测或证明跟踪成功。

实际容器保留48 GiB外部上限、零 swap、65%准入和24 GiB物理预留；训练退出0、未见 OOM。helper 退出前观测 cgroup peak 为2,306,777,088字节，不是完整生命周期或 CUDA allocator 峰值。首次缺少 `/motion-cache` 挂载的输入校验失败，以及两次资产导出前检查失败均保留，未覆盖原记录。随后独立 TF32 N2 单轮、九阶段遥测及 CPU 读回也通过：allocated 窗口峰值282,415,104字节、reserved峰值316,669,952字节，cgroup退出前观测峰值2,305,785,856字节。该步骤仍是缩小预算的方法门禁；准确数据过滤、目标坐标定义、微批数值差异、完整预算和收敛继续分别验收。

### N128 内存窗口的实测边界

178 上另用40条 LAFAN1、N128/B128/microbatch16 的工程配置完成一轮[九阶段内存记录](../scripts/RUN_SPARK_NATIVE_N128_TELEMETRY_GATE.md)。初始化、采样、10次模型更新、策略与20次 critic 更新、checkpoint 均覆盖，独立 CPU 读回通过。这个配置仍是 SMC99、关闭自碰撞和 environment context；不能和上面的 Paper93 方法门禁混为同一实验。

测量窗口内 LibTorch allocator 的 allocated peak 为341,745,664字节、reserved peak 为434,110,464字节，边界采样的最低 CUDA free 为86,754,131,968字节。allocator 统计不包含全部 APIC、驱动及其他库占用，不能与设备已用量或 cgroup 指标相加，也不能据此降低24 GiB预留或直接外推4096环境。显式同步会改变计时，本次不提供吞吐比较。测量功能本身没有放宽准入或保存限制。

### 显式论文容量配置，尚未运行 4096 环境

新增 [capacity profile](../src/learning_native_capacity/README.md) 与 [phase admission](../src/learning_native_admission/README.md) 将旧小规模模式和 `paper-4096` 分开。后者要求 Isaac/APIC CUDA、`stream-v2`、显式物理工件 SHA；每 rank 上限为 N4096、world batch2048、actor batch4096、replay1000。回放的234个F64、两个I32和两个U8字段合计7,708,672,000字节，按真实分块存储预算；采样产生的对象、完整逻辑张量、BPTT、critic、缓存高水位、保存与隔离恢复的同时存活数据另计。世界模型数据按256窗口暂存，不改成功路径的采样顺序或逻辑批次。

训练入口、批次构造、APIC producer/consumer、CPU checkpoint audit、导出/评测和保存/恢复按同一显式 profile 验证；旧配置与 Python 保留。新 stream 限额为单成员8GiB、总10GiB，catalog64MiB/state4MiB；保存前重查额外主机头寸及输出文件系统 `f_bavail`，不删除旧 generation。64MiB checkpoint catalog 与原始 BONES 约90MB motion manifest 是不同对象，后者仍单独受256MiB和4GiB解析预留约束。APIC metadata/文件/共享区上限只限制序列化输入，不能证明CUDA占用。

该路径目前通过纯算术、旧配置回归和编译审查。保守的完整论文批次示例估算峰值约196.8GB，按65%规则要求每台实际剩余约302.8GB，因此不能在当前Spark上直接放行。micro16例仍要求约99.5GB实际剩余，且微批数值等价门禁尚未通过；不会自动切分并称为原论文配置。需要后续逐级真实校准与方法验证；配置存在、本地CPU检查通过和两机ConnectX-7互联均不等于N4096训练或收敛已完成。
