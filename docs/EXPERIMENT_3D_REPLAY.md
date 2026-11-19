# 实验 3D 回放与姿态通道

这项集成在现有 Cockpit 的 **MoonData → Learning experiments** 中增加独立的
**3D replay** 面板。原有实验曲线、trial 检查器和 URDF/STL 编辑器继续保留。

## 使用方式

打开 3D replay，选择实验和动作，然后播放、暂停或拖动时间轴。时间轴也支持键盘
操作和逐帧按钮。参考动作可以独立显示或隐藏；实际仿真机器人和参考机器人共用
同一个世界坐标系，不做自动平移对齐。

回放的时间是从所选动作起点开始的经过时间。参考源的绝对起点另外记录。例如
源动作从第 20 秒开始，回放显示 0–10 秒，而不是把参考源的 20 秒当成回放延迟。
物理轨迹提前终止时，界面保留最后一个真实记录姿态并标明结束；参考动作可以
继续播放。插值仅用于已记录帧之间的显示，不产生终止后的物理状态。

实验列表保留尚未附加 3D 数据的实验，并明确显示数据不可用。不会用参考动作、
示例动画或新跑的仿真冒充缺失的实验记录。

## 首批已登记记录

研究 RoboBook 位于 `target/learning/experiment-book`。两份原实验均附加了 seed 0、
参考起点第 1000 步（20 秒）的两个动作：

| 实验 | 动作 | 实际物理轨迹 | 参考轨迹 |
| --- | --- | --- | --- |
| `reference-feedforward-initialization` | `pose-offset` | 501 帧，0–10 秒 | 501 帧，0–10 秒 |
| `reference-feedforward-initialization` | `joint-sines-high` | 501 帧，0–10 秒 | 501 帧，0–10 秒 |
| `reference-joint-initialization` | `pose-offset` | 501 帧，0–10 秒 | 501 帧，0–10 秒 |
| `reference-joint-initialization` | `joint-sines-high` | 253 帧，0–5.04 秒终止 | 501 帧，0–10 秒 |

这些是已有初始化实验的记录，不是最新大规模训练 checkpoint 的新评测。每份模型
包含 31 个刚体（含 world）和 36 个显示几何体；网格资源约 19 MiB，两实验在
BlobStore 中共用相同内容。两次离线导出的 `simulation_steps` 都为 0。

登记回执：

- [前馈初始化实验](../output/research/g1-3d-replay-feedforward-registration.json)
- [关节输入初始化实验](../output/research/g1-3d-replay-joint-registration.json)

首批回放 JSON 分别位于 `target/learning/replay-feedforward-20261025/replay.json`
和 `target/learning/replay-joint-20261025/replay.json`。SHA256 分别为
`619ad79374bdb5370f2953a0a24e48ee081f5acb64fbdbf1fe1ef649acf7caa7` 和
`7315f78ac571aa562648c81d45ebd74f00cb49a78e9abdc86f71c0432e987dcc`。

本地研究入口为 `http://127.0.0.1:5300`，路径是 MoonData → Learning experiments
→ 3D experiment replay。需要重新启动时，在仓库根目录执行：

```sh
moon run --target native cmd/main -- serve target/learning/experiment-book ui/rabbita-cockpit/dist 127.0.0.1 5300
```

前端修改后先在 `ui/rabbita-cockpit` 执行 `npm run build`。这个本地入口加载研究
RoboBook；其他 RoboBook 需单独登记自己的实验回放。

## 数据来源与保留方式

MoonBit 离线 producer 读取已保存的完整物理状态及对应参考片段，检查来源摘要，
通过原生 MuJoCo C 接口恢复状态并调用 `mj_forward` 得到刚体世界姿态。它不调用
`mj_step`，不执行策略推理或训练。回放包含初始 `state[0]` 和最后一个
`next_state`，避免丢失终止时的姿态。

模型几何取自同一个编译后的 MuJoCo 模型：网格导出为内容寻址的 OBJ，保留编译
后的顶点和 geom 局部变换；球、箱体、圆柱等保留原生几何参数。坐标单位为米，
四元数顺序为 `wxyz`。显示模型的选择不改变原物理模型或碰撞配置。

回放通过 MoonData BlobStore 保存。独立的 `learning-replay` source 绑定原实验
摘要、物理记录、参考记录和回放文件的 checksum；不重写原实验摘要、checkpoint、
Python 实现或数值档案。重复注册相同内容是幂等的，同一绑定下更换内容会被拒绝。

## API 与可复用的帧格式

读取回放：

```text
GET /api/moondata/learning-experiments/{experiment_id}/replay
GET /api/moondata/learning-experiments/{experiment_id}/replay-assets/{sha256}
```

资源接口只提供该实验已登记并通过摘要检查的网格，不接受任意本地文件路径。
没有回放的实验返回明确的 unavailable 响应，原有 physics API 不受影响。
登记首版接收内容寻址 OBJ：单资源最大 32 MiB，模型资源总计最大 128 MiB；
回放 JSON 最大 64 MiB。实验列表的 `replay_experiment_ids` 仅为可用性提示，
读取时仍验证完整绑定。资源校验使用浏览器 WebCrypto，需要 HTTPS 或 localhost。

`moonrobo.pose-replay.v1` 保存模型、动作、轨道和来源。每个动作含 `physics` 和
可选的 `reference` 轨道，轨道各自保留真实开始/结束时间。每帧的核心格式是：

```json
{
  "time_s": 0.02,
  "bodies": [
    {
      "body_id": "0",
      "position": [0, 0, 0],
      "quaternion_wxyz": [1, 0, 0, 0]
    }
  ]
}
```

示例仅展示单个刚体；有效帧必须完整包含所绑定模型的每个刚体。模型坐标系固定为
`right-handed-z-up`，渲染时只做一次坐标系转换。body ID 是模型内部的稳定标识，
不能跨不同模型 SHA 混用。帧中的姿态是世界姿态，不应再沿 body 层级重复累乘。

MoonBit 的帧校验与前端的无传输依赖姿态通道可以用于后续实时 MuJoCo 会话。
实时 producer 需要先绑定模型，再持续发送相同结构的完整帧；重置需显式开始
新的时间周期。网络传输、会话生命周期和实时策略控制尚未接入。

## 验证边界

本次按要求不运行测试套件。类型检查、接口生成、格式化和构建结果在交付记录中
单独说明；离线导出仅用于生成用户请求的实际回放工件。3D 动画可观察记录中的
跟踪误差和跌倒，不构成策略收敛、完整训练等价性或硬件部署验证。

2026-10-25 交付检查：新增及受影响包的 native `moon check`、登记脚本类型检查、
JavaScript 语法检查、原生 exporter/register/host 构建、Cockpit 生产构建均通过；
`moon info` 已更新公开接口，新增代码已格式化，相关 `git diff --check` 通过。
旧工具链弃用警告和现有 UI 主包体积警告保留。两次实际离线导出及两次登记完成。
测试套件、浏览器交互复测、实时推理及训练均未运行。

前端 `predev` / `prebuild` 明确只编译 Cockpit 的 `main` 包，避免工作区新增的
原生训练包被无关地编译成 JavaScript。原有 UI 入口和构建产物准备流程保留。
