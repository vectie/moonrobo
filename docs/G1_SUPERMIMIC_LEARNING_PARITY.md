# SuperMimic 学习主干数值对照

2026-10-23 的修正继续以本地 `../smc/supermimic` 和论文 §3.2–3.3、附录 C/D 为依据。此记录只覆盖网络、模型拟合、想象 actor/critic 与 replay；不把学习公式一致等同于物理环境一致、训练收敛或论文成绩复现。

## 实际修正

`aligned/learning.py` 原来在每个想象步单独计算解析奖励/终止，并逐步构造 critic 特征。现按 `smc/train.py` 的原始布局，先保留顺序展开的 32 步状态/动作，再将 `H×B` 轨迹一次交给解析 reward/termination heads；critic 使用含初始状态的 `(H+1)×B` 一次构造输入。这样保留同一时序和梯度路径，同时避免 32 次 reward FK 调用和 33 次 critic-feature FK 调用。没有据此宣称具体加速倍数。

没有发现需要修改网络方程、模型 8 步损失、actor 存活权重/尾值或想象 GAE 递推的数值错误。已有 40/40 失败的 smoke 不能由这次对照直接归因于这些公式。`networks.py` 和 `buffer.py` 本次未因猜测而改写。

## 对照方法与结果

[test_smc_learning_differential.py](../providers/motion_learning/aligned/test_smc_learning_differential.py) 加载本地 `smc` 的原始 rotations、MDP 数学、network、buffer 源文件，并从其 `train.py` AST 提取原函数体执行。仅替代导入时需要的 kinematics/motion 类型依赖，避免启动 Isaac；没有手工重写一份目标方程充当对照。

4 项差分测试通过；以下张量比较均为 `rtol=0, atol=0`：

- 相同网络参数和输入下的世界模型、策略、critic 前向值；世界模型 8 步拟合后的梯度、权重与 Adam 状态。
- 执行原始 `smc.policy_update` 与本地完整 32 步更新后的 actor/critic 权重、归一化状态和优化器状态。模型输出非零，实际经过模型和 critic 的状态梯度。
- 给定相同 replay 位置时的窗口、终止 mask、10 帧历史；环形 buffer 已覆盖旧行后，保存恢复的抽样结果逐值一致。
- 默认论文规模网络的参数名称/形状完全相同。该项使用 meta device 检查结构；数值更新使用显式小网络和固定 CPU 输入，未执行论文规模训练。

另外，7 项原有学习/导出测试继续通过，包括真实终止与 timeout 的不同 GAE bootstrap、冻结模型/critic 权重但保留输入梯度、空 replay 拒绝采样，以及 71 维状态转换。真实 MuJoCo 恢复回归再次通过：连续 3 轮与保存 2 轮后恢复 1 轮的网络、优化器、replay、控制历史、随机数和计数逐值一致，约 2.02 s。

```sh
target/learning-venv/bin/python -m unittest \
  providers.motion_learning.aligned.test_smc_learning_differential \
  providers.motion_learning.aligned.test_aligned_learning -v

target/learning-venv/bin/python -m unittest \
  providers.motion_learning.aligned.test_aligned_resume -v
```

## 保留的边界

数值测试固定相同起点；本地直接在合法 replay 起点中均匀抽样，`smc` 用拒绝抽样筛去跨 clip 的起点。二者分布目标一致，但随机数消耗不同，不能据此宣称同 seed 的整次训练完全相同。本地额外检查 episode/frame 连续性，保存实际 replay，空恢复时重新热身，防止已确认的 `smc` 空 buffer 恢复问题。

critic batch 不整除时，本地处理全部样本，`smc` 的整除切片会丢弃余数；论文配置可以整除，所以该差别不影响此次配置对照。日志 `v_loss` 在本地为所有 critic minibatch 的均值，`smc` 返回最后一个 minibatch；两者不是不同的训练目标。非有限梯度在本地明确报错，`smc` actor 跳过该次更新；此次测试全部为有限梯度。

此对照没有启动 `torch.compile`、CUDA、bf16/TF32 或 Isaac。MDP 中保留的旋转数值修正、不同观测模式及机器人执行器/FK/场景差异需要各自的对照证据，不能由本文件外推。已封存的 smoke 报告与 checkpoint 保持原样；本次代码修改不是其重新训练结果。
