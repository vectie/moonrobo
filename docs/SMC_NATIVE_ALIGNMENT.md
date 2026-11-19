# SMC 与 MoonBit native 的训练配置及语义对照

## 2026-10-28：编码器批量化与 SO3 完整融合均未准入

继续单 agent 对照原 SMC 源码、保持4096=8×512/H32及原数值/内存门槛。
参考编码器沿时间批量计算的候选，完整更新有8,486,066个值超出原容差，
未进行稳态计时。另一个候选把 SO3 系数的加法、sqrt/sin/cos 与组装融合，
完整 world/actor 更新共127,446,172个值逐值一致，但无 profiler ABBA没有收益：
world **63.063→63.103ms**，actor/critic **1430.863→1431.428ms**。
两项均保留默认关闭；没有新优化准入，不能把复测漂移当作进步。

保留配置的同期对照：actor/critic1430.863ms，SMC1303.043ms，差127.820ms（9.81%）；
world单次2048×8更新63.063ms，SMC56.271ms。低开销阶段事件中，
保留配置的actor反向/前向、world反向差额分别56.322/39.538/3.144ms。
事件窗口与无profiler窗口偏差绝对值≤0.73%，包含运行漂移；仍不是逐算子的因果账单。
此次干预否定的是这一批SO3完整融合的吞吐收益，不能泛化成所有融合/图重放均无效。
SMC仍只作计时参考，其跨语言数值检查失败记录保留。

“快50%”按吞吐1.5倍计算，本次actor参考要求≤868.695ms，目标未达。
原实现、Python与旧产物保留，无OOM，保护阈值未降。
启动保护拦截的尝试及按文件回收已结束任务输出缓存的证据也已归档。
详见[本轮记录](../output/spark-runtime-20261024/coefficient-full-20261028/README.md)、
[最终实测](../output/spark-runtime-20261024/coefficient-full-20261028/accepted-summary.json)、
[编码器数值否决](../output/spark-runtime-20261024/encoder-batch-20261028/rejection.json)。

## 2026-10-28：系数前向融合；两种 split 反向候选未准入

单 agent 继续源码对照。SO3 系数前向的逐元素组装改为一次 CUDA 提交，保留原 ATen
sqrt/sin/cos、分支阈值和既有 VJP。单更新 trace 确认 world 8 次、actor 256 次。
完整 GPU 更新与边界检查通过；七组候选更新逐值一致，论文目标、GAE、尾值和保护阈值未改。

4096=8×512、H32、20 次 critic 更新，无 profiler 单因素 ABBA：
**1447.365→1438.132ms，节省9.232ms（0.638%）**，AB/BA分别8.755/9.710ms。
world单次2048×8更新64.036→63.762ms，SMC56.186ms。
系数两列共享split、32帧回报共享split均无稳定actor收益，保留默认关闭的实现作复测对照。

最后一次已准入配置复测1434.995ms，对同期SMC1313.683ms，差121.313ms（9.23%）。
这是重复测量，不能把跨窗口变化全算成优化收益；也不是完整训练迭代。
阶段最新差额：actor前向35.527ms、反向58.352ms，world反向3.364ms；
同配置前一窗口分别为40.954/64.439ms，显示运行波动。**剩余反向差距尚未完整做出因果归因。**
SMC仍未通过跨语言严格数值门槛，仅作速度参考。

Torch reserved峰值4.76GiB，无OOM；所有内存阈值保留。
原实现、Python、旧二进制和两个负结果均保留。详见
[本轮完整记录](../output/spark-runtime-20261024/coefficient-assembly-20261028/README.md)及
[准入覆盖配置](../output/spark-runtime-20261024/coefficient-assembly-20261028/execution-override.json)。

## 2026-10-28：SO3系数反向融合；叉积反向候选未准入

单agent，继续对照SMC原源码与其编译执行图。新增默认关闭的
`fused_so3_coefficients`与`fused_cross_vjp`，原实现和上一轮冻结产物保留。
前者保留ATen前向公式、三角函数、阈值和归约，仅融合系数反向链；后者将两个叉积VJP合并提交。
四组完整GPU更新比较逐值一致（world约6344万个值、actor每组约6400万个值）；
CPU FP32/64两项和配置9项通过，原容差及论文训练语义未改。

固定4096=8×512、H32、20次critic更新，SO3单项无profiler ABBA：
**actor/critic1474.303→1453.951ms，−20.352ms（1.38%）**；同期SMC1302.825ms，差151.126ms（11.60%）。
World单次2048×8更新64.823→63.402ms（−1.421ms），SMC56.486ms。均不是整轮训练时间。
叉积单项和“SO3 vs SO3+叉积”条件ABBA均无稳定收益；后者1442.848→1442.840ms，
正反方向相反，因此`fused_cross_vjp=false`。不能将组合独立实验中31.63ms的改善全算为准入收益。

关闭叉积后补测阶段事件：actor反向789.01 vs726.01ms，差63.00ms；
前向含软终止411.77 vs361.34ms，差50.43ms；world反向41.64 vs38.18ms，差3.46ms。
这些是低扰动顺序诊断区间，不是阶段ABBA；不与CPU等待相加，也不将跨批次变化全部归因于新算子。
单更新CUDA路径核对确认系数VJP为world8次/actor256次；叉积候选232次但无稳定收益。
SMC跨语言严格数值门槛仍失败，保留为计时参考，不宣称实现已逐值等价。

Torch reserved峰值4.76GiB、无OOM；全部保护阈值不变。
主测量结束后启动保护拦住一次额外采集，GPU未启动；仅回收本任务8个已结束作业的输出文件页缓存，
保留原文件、输入和编译缓存，未降低门槛。
详见[实验记录](../output/spark-runtime-20261024/geometry-vjp-20261028/README.md)、
[准入配置](../output/spark-runtime-20261024/geometry-vjp-20261028/execution-override.json)、
[最终阶段结果](../output/spark-runtime-20261024/geometry-vjp-20261028/accepted-phase-results.json)。

## 2026-10-28：SO3 组装、叉积前向与编译开关对照

单 agent；沿用上一轮24GiB启动余量及全部运行期保护，不降低阈值。
读取本机SMC和实际运行副本，确认train/rotations/kinematics/networks源码哈希一致；
固定输入探针沿用原数学函数及独立8×512/full-critic适配器。
新增默认关闭的`fused_so3_tail`和`fused_cross_forward`：前者融合SO3矩阵组装及反向
逐元素乘法，保留原ATen三角函数、bmm和归约；后者只融合叉积前向，保留原ATen VJP。
CPU两项测试、四项完整GPU更新比较通过原容差，最大绝对差1.714e-7，无超限值。

固定4096=8×512、H32、20次critic更新，无profiler ABBA，组合
**1503.08→1473.81ms（−29.27ms，1.95%）**；同期SMC1306.85ms，差166.96ms（12.78%）。
World单次2048×8更新65.059→64.785ms，SMC56.335ms。均非整轮时间。
叉积单项稳定节省18.08ms；SO3单项actor正反顺序不一致。
补做“叉积 vs 叉积+SO3”ABBA，边际节省5.18ms（正反9.04/1.33ms），
支持启用组合，但不能相加独立实验收益或宣称稳定的大额反向收益。

新增8个soft-failure分段标记后，完整更新与标记前逐值相同。
双方前向均包含软终止时，native413.33ms、SMC363.17ms，差50.16ms；
actor反向820.38对729.47ms，差90.91ms；world反向43.13对39.08ms，差4.06ms。
两组分段记录的actor反向收益方向不一致，world反向也未改善：
**本轮不能宣称已经解决或完整归因剩余反向差距。**

额外使用原探针的SMC编译开关做同输入ABBA，隔离图级编译的作用；不修改Python源码，
不以数值失败的参考结果替换训练实现。SMC compiled仍未通过跨语言数值门槛，
其计时只能作为参考；world eager相对探针既有native基准的完整检查通过。
SMC关闭/开启compile时，world **66.635→56.278ms**，actor/critic **1639.967→1310.200ms**。
同SMC分段中，world反向44.178→38.560ms、actor反向928.056→725.983ms、
actor前向479.152→360.948ms，critic反向基本不变；观察器/off偏差含运行漂移≤0.90%。
这验证了共同的图级编译优势。Native两阶段均快于SMC eager，但慢于compiled SMC；
不能将SMC内部编译收益直接等同于native残余差额，也尚未拆分融合、提交和自动微分调度的贡献。
固定native成对运行Torch reserved峰值4.756GiB，无OOM、容器swap0。

[完整记录](../output/spark-runtime-20261024/geometry-tail-20261028/README.md)、
[成对结果](../output/spark-runtime-20261024/geometry-tail-20261028/results.json)、
[修正分段及组合增量](../output/spark-runtime-20261024/geometry-tail-20261028/scope-results.json)、
[SMC编译开关对照](../output/spark-runtime-20261024/geometry-tail-20261028/compiler-results.json)、
[配置覆盖](../output/spark-runtime-20261024/geometry-tail-20261028/execution-override.json)。

## 2026-10-28：旋转逐行融合及内存容量复测

继续单 agent，从 `smc` 的 Rodrigues/skew 与编译范围出发，为现有紧凑旋转增加
`fused_axis_rotation`、`fused_skew` 两个独立、默认关闭的执行选项。
保留原 ATen sin/cos、浮点算序、模型与训练协议；原 compact/expanded 路径均保留。
CUDA 行内拼装与 VJP 不启用 FMA/fast-math/FTZ，支持 stride、有限行数和一阶梯度。
CPU 两项测试通过；四项完整 GPU 更新比较的参数、梯度、Adam、元数据和指标
均通过原容差，其中所有比较值 `max_abs=0`。

无 profiler、固定迭代60权重与输入、batch4096=8×512、H32、20次critic更新，
每块3预热+10测量的 ABBA：actor 两项组合 **1531.61→1501.01ms（−30.60ms，2.00%）**，
正反顺序分别节省31.18/30.02ms；world单次2048×8更新 **65.760→65.322ms（−0.438ms）**。
SMC在 native 因素前后复测，actor平均1313.33ms、world56.629ms，当前相差
187.68ms（14.29%）和8.694ms（15.35%）。不是整轮时间；SMC跨语言数值检查仍未通过，
作为计时参考，不能宣称数值等价。

低观察开销 CUDA 分段结果：actor反向820.014对727.072ms（差92.942ms），
前向/geometry/reward/tail428.593对361.940ms（差66.653ms），
world反向43.300对39.185ms（差4.115ms）。本轮同侧干预分别节省12.983、11.185、0.109ms；
不能把跨次运行的整个差额变化都归给补丁。剩余差额尚未形成完整因果账单。
actor前向标签边界仍有termination差异；各分项和观察器扰动限制完整保留。

用户随后明确修改内存要求：允许用容量换速度。固定配置启动门槛由CUDA64GiB改为24GiB、
host Available/Free由64/40改为32/24GiB；运行中停止保护仍保留。输入/结果缓存常驻，
取消常规镜像/结果页回收。此轮固定配置实测Torch reserved峰值4.75GiB，无OOM、容器swap0。
微批量扩容为独立实验，不混入上述8×512数字；只有通过原完整更新数值门槛才计时/启用。
扩容检查已实际执行：1024/2048/4096的Torch reserved峰值分别6.79/10.94/18.38GiB，
均跑完actor+critic更新且无OOM；4096峰值约占CUDA报告总容量15.1%。但三个完整更新
均未通过相对已接受512结果的原数值门槛，因此未启用、未进入稳态ABBA计时，
没有速度结论；差异原因尚未隔离，不能直接称为无害舍入。

详情、脚本、原始记录与配置：
[本轮记录](../output/spark-runtime-20261024/fused-rotation-20261028/README.md)、
[成对数据](../output/spark-runtime-20261024/fused-rotation-20261028/results.json)、
[分项数据](../output/spark-runtime-20261024/fused-rotation-20261028/phase-results.json)、
[配置覆盖](../output/spark-runtime-20261024/fused-rotation-20261028/execution-override.json)。

## 2026-10-28：共享 split 与投影航向融合

继续单 agent，以上一节已验证的坐标轴旋转＋静态FK裁剪为基线。本轮重新对照
SMC `WorldModel.step` 与 `rotations.yaw_mat`，修复两个具体的执行图差异：

- SMC一次 `d.split((3,3,3,3,29,29), -1)`，native原来六次独立`narrow`。
  新增可选`split_world_delta`，使六段共享一个SplitWithSizesBackward节点。
  单个world更新有8组；actor4096=8×512、H32有256组。反向切片节点由
  48→8及1536→256；这只是结构计数，不能直接兑换成毫秒。
- 新增`compact_heading`，把投影yaw的切片、逐元素、拼接及反向 bookkeeping
  合并为有界逐行CUDA前向和一阶VJP。保留SMC公式、`1e-9`、原浮点算序与stride；
  禁止FMA/fast-math/FTZ，保留精确division/sqrt；未改变legacy heading。
  Linear、LayerNorm、奖励、软存活、GAE、尾值、裁剪与Adam时序均未改动。

源码：[split_sections.inc](../src/learning_tensor/split_sections.inc)、
[compact_heading.inc](../src/learning_tensor/compact_heading.inc)、
[compact_heading.cu](../src/learning_tensor/compact_heading.cu)、
[world_integrate](../src/learning_aligned_gpu/geometry/state.mbt)。CUDA插件构建须显式
开启`MR_ENABLE_GEOMETRY_FUSION`；未编入CUDA扩展时该选项会报错，不静默替代。
默认仍使用原路径。已验证组合配置见
[execution-override.json](../output/spark-runtime-20261024/smc-heading-body-20261028/execution-override.json)，
叠加于本轮已对齐基线，不能替代完整训练配置。

CPU实际执行15项（无SKIP）。heading、split及组合在world/actor的六次完整GPU
比较均通过：每项world检查63,442,642个参数/梯度/Adam数值，actor检查64,003,530个，
本固定输入下全部逐值相同。门槛仍为`atol=2e-6, rtol=2e-4`。另一个身体位置/速度
批量化候选在CPU第三次Adam更新失败，已从活动实现撤回；源码与失败测试保存在
`smc-heading-body-20261028/rejected-body-errors/`，显式开启请求被拒绝，未测GPU性能。

每个样本恢复iteration60的相同权重、Adam、统计量、输入、噪声及critic排列。
world为单次2048×8更新，actor为4096=8×512、H32、20次critic更新；均为计算区间，
不含采样、恢复、上传及导出，**不是完整训练一轮**。每个因素在同一进程ABBA，
四块各3次预热＋10次有效测量，无profiler；逐块检查实际选项和恢复后的指标。

| 独立因素/组合 | world 基线→候选 ms | world 节约 ms | actor/critic 基线→候选 ms | actor/critic 节约 ms |
| --- | ---: | ---: | ---: | ---: |
| 航向融合 | 67.741→65.222 | 2.519 | 1589.424→1517.386 | 72.039 |
| 共享split | 67.542→67.148 | 0.395 | 1605.824→1595.872 | 9.952 |
| **两项组合** | **67.160→65.075** | **2.085** | **1604.719→1517.028** | **87.691（5.465%）** |

每行使用各自的交替基线，不能相加。actor单项split的AB/BA收益为2.894/17.011ms，
波动较大；组合为84.350/91.031ms。组合world两顺序为1.800/2.370ms。本轮不声称
组合优于heading单项的直接成对实验，也不把总收益全部记为反向收益。完整记录和
分段对照见 [实验目录](../output/spark-runtime-20261024/smc-heading-body-20261028/README.md)。

内存保护线完全保留，新的heading/split存储分别额外预留至少64MiB/32MiB。
几次启动被原64GiB CUDA-free门槛拦住，没有进入训练、没有OOM。定位到验哈希及
先前加载会使固定export文件页重新驻留，runner C在验哈希后、CUDA启动前，对
已核实结束的本任务export产物做文件级cache advice；首次实际回收1,699,897,344bytes。
所有文件保留，加载和完整预热在测量前完成，无全局drop-cache或阈值下调。
冻结B二进制含始终关闭的body候选分支；最终源代码撤回该失败分支并增加拒绝配置检查，
没有更改通过的数学路径。`moon info --target native`、`moon fmt`及最终配置回归通过。

SMC新测无profiler参照：actor/critic **1304.222ms**，world **56.615ms/次**。
当前组合还差 **212.806ms（16.317%）** 与 **8.461ms（14.945%）**。
SMC为匹配固定输入的新测单顺序参照，native因素实验为ABBA；不能称作跨实现ABBA。
SMC编译路径原有跨语言数值断言仍失败，exit=1与明细保留，只作为性能参照；
本轮通过的是native优化与原native完整更新之间的数值检查。
无profiler数据见 [results.json](../output/spark-runtime-20261024/smc-heading-body-20261028/results.json)。

少量阶段CUDA event的三方对照如下，各3次预热＋10次有效样本，没有Nsight或
逐算子/逐autograd节点观察器。阶段计时为独立进程、单顺序；不取代ABBA总耗时。

| 阶段 | 本轮native基线 ms | 当前组合 ms | 新测SMC ms | 当前差额 ms |
| --- | ---: | ---: | ---: | ---: |
| actor反向，累计8次 | 883.681 | 828.838 | 719.156 | **109.681** |
| actor前向＋几何＋奖励＋尾值 | 457.019 | 434.884 | 360.359 | **74.526** |
| world反向，单次更新 | 44.541 | 43.158 | 38.230 | **4.929** |
| world前向＋误差 | 19.151 | 18.522 | 14.333 | **4.188** |
| critic反向，累计20次 | 46.638 | 46.842 | 46.537 | 0.304 |
| critic gather＋前向 | 95.865 | 96.883 | 95.819 | 1.063 |
| critic特征＋目标 | 75.394 | 73.702 | 70.054 | 3.648 |
| critic裁剪＋Adam | 6.670 | 6.713 | 3.453 | 3.260 |

本轮重测的actor反向差额164.525→109.681ms，组合对应减少54.843ms；
world反向差额6.311→4.929ms，对应减少1.383ms。共同的冗余反向图已获得
源码与干预证据，但这些结果**没有完整解释剩余109.681/4.929ms**，不能继续将其
笼统归给FK、MLP或CPU提交。actor前向复合项仍有原先的范围差异：SMC包含
termination，native的soft-failure/return assembly在该组之外。

事件整段相对无profiler参照：native actor基线/组合分别-9.833/-1.065ms，SMC
-1.016ms；world为+0.547/+0.210/-0.601ms。各项幅度约在1.1%内，但包含进程漂移，
负值不是“profiler加速”；不做固定校正。事件区间包含队列间隙、与CPU重叠，
不可把CPU等待或各组中位数再次相加来凑总差额。有效标记均完整，无open/dropped。
见 [phase-results.json](../output/spark-runtime-20261024/smc-heading-body-20261028/phase-results.json)。

native ABBA的Torch reserved峰值 **5,106,565,120bytes（4.76GiB）**，cgroup峰值
3,737,542,656bytes，最低host available115,358,900,224bytes；容器swap为0、无OOM。
UMA计数不可相加。runner D仅为事件复测复用刚完成的同输入SMC编译缓存，严格
验证已结束producer及镜像身份；所有权重/优化器仍逐样本恢复，三次预热照常执行。

## 2026-10-28：从源码裁剪几何计算图

继续单 agent。重新读取 SMC 的 `train.py:95–132`、`networks.py`、`kinematics.py`、`rotations.py` 后确认：SMC 对 world rollout、world error、imaginary step、reward/termination、critic input 五段函数使用 `torch.compile`；当前 native 基线已经使用原生 Linear/LayerNorm，权重布局同为 `[out,in]`，但几何仍由多个独立 ATen 节点执行。不能仅凭源码将全部剩余秒差归给编译，也不能把“一次 FFI”当成算子融合。

本轮按具体冗余实现三个独立、默认关闭的候选：

| 选项 | 源码证据与改动 | 边界 |
| --- | --- | --- |
| `compact_axis_rotation` | 冻结 G1 XML 的29个关节轴全部为坐标轴；原实现仍执行通用九元素 Rodrigues 公式。专用路径共享零项、正负 sin 和对角项，并提供一阶解析 VJP，减少零乘法、拼接和反向节点 | 只接受精确的正负坐标轴；任意轴走原实现。保留 `(1-c)+c` 等原前向算序，未直接替换为常数1 |
| `static_fk_pruning` | 对严格恒等的 body offset rotation 跳过矩阵乘法；固定连杆不再构造零关节速度及其叉积反向 | 非恒等偏置、任意父链、非零枢轴/qref继续受支持；没有删除固定连杆或改变 tracked body 集合 |
| `compact_skew` | SO(3) 指数映射中的 skew 由多次切片和拼接反向，改为线性映射的解析 VJP | 保留原前向和小角度分支，未修改 SO(3) 的系数、epsilon 或梯度裁剪；只针对论文使用的一阶训练梯度 |

实现见 [compact_rotation.inc](../src/learning_tensor/compact_rotation.inc)、[geometry/context.mbt](../src/learning_aligned_gpu/geometry/context.mbt)、[geometry/rotations.mbt](../src/learning_aligned_gpu/geometry/rotations.mbt)。公共选项与动态插件能力检查齐全；原路径和此前失败的候选均保留。没有更改奖励、软存活、GAE、尾值、学习率、更新次数、精度或 microbatch 划分。

CPU 检查实际执行15项（无SKIP），涵盖FP32/FP64、非连续角度输入、正负坐标轴、零/小角/π、任意轴与固定连杆混合链、非法轴、配置和保留内存预算；后续准入调整版本另执行同15项。完整 GPU 更新在 `atol=2e-6, rtol=2e-4` 下，world候选各比较63,442,642个数值，actor候选各64,003,530个数值；已检查参数、梯度、Adam状态、metadata和metrics。详细原始结果保存在 `output/spark-runtime-20261024/smc-structural-20261028/`。

本轮基线包含上一轮通过的 preserve-forward cross、detached rotation constants 和 world norm snapshot；不重复计入其收益。每个样本恢复相同iteration60状态/输入，actor为4096=8×512、H32、20次critic更新，world为单次2048×8更新。ABBA每块3次预热、10次有效样本，完全关闭profiler；不包含恢复、上传、采样和导出，也不是完整训练一轮。

`compact_skew` 单项world ABBA为67.092→67.300ms（两个顺序均更慢）；另一次包含相同world计算的组合复测为68.089→68.015ms，量级很小且方向不一致。actor skew单项1691.688→1692.627ms，两种顺序方向也不一致。因此不将其作为可启用的性能改进；world反向的主要差距仍未修复。最终推荐组合只保留坐标轴旋转与固定变换裁剪，单独重新做数值门槛和ABBA。

无profiler的独立ABBA结果如下，表内每一行均采用其自己的交替顺序基线，不相加：

| actor/critic 改动 | 基线 ms | 候选 ms | 节约 ms / 比例 | AB / BA 节约 ms |
| --- | ---: | ---: | ---: | ---: |
| 坐标轴旋转 | 1686.929 | 1633.110 | 53.819 / 3.190% | 53.455 / 54.183 |
| 静态FK裁剪 | 1699.581 | 1664.487 | 35.094 / 2.065% | 35.462 / 34.725 |
| skew单项（不推荐） | 1691.688 | 1692.627 | -0.939 / -0.056% | -6.009 / 4.130 |
| 三候选组合（含无稳定收益的skew） | 1699.892 | 1606.862 | 93.030 / 5.473% | 90.239 / 95.822 |
| **最终两项组合，skew关闭** | **1682.062** | **1602.437** | **79.625 / 4.734%** | **78.580 / 80.670** |

最终组合另通过64,003,530个完整更新数值检查，超差为0。可复测配置为 [execution-override.json](../output/spark-runtime-20261024/smc-structural-20261028/execution-override.json)，仅叠加于本轮已对齐基线；库默认值仍未改变。A/B二进制的训练数学实现与插件相同，B增加不含skew的组合开关，并将新增临时预算由32MiB下限扩展为随更大actor块增长；对应CPU准入回归通过，实测4096/8×512预算值不变。

新测SMC compiled参照为actor/critic **1304.652ms**、world单次更新 **56.529ms**（各3次预热+10次有效样本，无profiler）。推荐组合actor为1602.437ms，仍差297.785ms、约22.825%。world保留原路径；最新ABBA基线68.089ms，对SMC差11.560ms。SMC此处为单顺序的新测参照，不能称作native/SMC之间的ABBA因果实验。SMC原有跨语言数值断言仍失败，原始exit=1和比较明细保留；仅计时完整，不将其表述为数值等价训练。原始汇总见 [results.json](../output/spark-runtime-20261024/smc-structural-20261028/results.json)。

保护线不变：初始CUDA free>64GiB、循环free>16GiB、Torch reserved<32GiB、100GiB容器且swap=0、cgroup停止线84GiB，CPU构建8GiB且不与GPU作业重叠。新的旋转临时存储预算至少32MiB，并随实际actor块和H增长；没有扣减旧预算。第一次world基线被free准入拦截，未训练、未OOM；保留失败记录。只对已验证结束的本任务输出和固定SMC镜像文件页做`POSIX_FADV_DONTNEED`，未删除文件、全局清缓存或降低阈值。

native ABBA的Torch reserved峰值5,119,148,032bytes（4.77GiB，设备容量约3.92%），cgroup峰值2,146,639,872bytes，采样最低host available为115,341,307,904bytes，无OOM且容器swap=0；UMA计数不能相加。SMC actor首次补测同样被64GiB free前置检查拦截，重试使用新标签，旧结果不覆盖。一次将构建镜像与已结束运行容器配对的只读计划被身份检查拒绝，未创建回收worker；后续使用已审计的native运行镜像c768和SMC运行镜像e84的专用工具，只回收固定镜像文件页。所有回收均位于测量之外，预热完整保留。

最终组合的少量阶段CUDA event诊断如下，各3次预热、10次有效样本，无Nsight、ATen/NVTX或逐自动微分节点观察器：

| 阶段 | native 基线 ms | 最终组合 ms | SMC compiled ms | 当前与SMC差额 ms |
| --- | ---: | ---: | ---: | ---: |
| actor反向，累计8次 | 925.409 | 886.058 | 722.518 | 163.539 |
| actor前向＋几何＋奖励＋尾值，累计8块 | 495.162 | 460.344 | 364.482 | 95.862 |
| world反向，单次更新 | 45.153 | 45.153（路径未改） | 39.110 | 6.043 |
| world前向＋误差，单次更新 | 19.288 | 19.288（路径未改） | 13.773 | 5.514 |

前向复合项两边边界仍有差别：SMC包括termination，native的soft failure与return assembly在标记外；该95.862ms不能当作严格同范围的因果差额。critic特征和目标构造另观察到93.871→75.245ms，SMC为70.229ms；其逻辑batch拼接边界也不同。阶段时长为stream elapsed、包含提交空隙且与CPU重叠；不能相加当作完整训练账单。native actor事件整段为1696.660→1599.961ms，相对无profiler各自参考分别+14.598/-2.476ms；SMC为+5.561ms。这些独立进程数据包含漂移，分段不是ABBA，headline仍采用上面的无profiler成对结果。详情见 [phase-results.json](../output/spark-runtime-20261024/smc-structural-20261028/phase-results.json)。

已弃用skew组合的最后world事件诊断被原64GiB free准入拦截，结果文件未产生，未执行训练、未OOM；失败日志保留，未将容器exit=0误当成功。由于最终配置明确关闭skew，不再重跑此弃用候选；world阶段报告直接列出已完成的原路径与SMC，不虚构候选计时。全部有效事件窗口均完整、无未闭合或丢弃的阶段标记。最终控制器冻结为输出目录中的 `suite_structural_final_b.mbtx`；未更改旧控制器副本。

复测入口为 [structural_rotation_suite.mbtx](../scripts/structural_rotation_suite.mbtx)，冻结runner/fixture/build均保留A/B版本。数值比较继续使用原有 [compare_top3_snapshots.mbtx](../scripts/compare_top3_snapshots.mbtx)。源代码优化需要通过数值和耗时两道检查；本轮skew的负结果保留，不能以节点更少代替性能改善。

## 2026-10-28：前三热点的原语与反向图修正

继续单 agent，对照 `../smc/supermimic/{networks,kinematics,rotations,train}.py`。本轮共同基线已使用原生 Linear、LayerNorm 和激活函数；本轮没有重复计算此前收益。对应 actor 反向、actor 前向/几何、world 反向，确认并实现以下可选路径：

| 源码差异 | 实现与验收边界 |
| --- | --- |
| SMC 用原生 `torch.cross`；我们拆成分量切片、乘减、拼接，反向继续展开这些节点 | 直接原生叉积版本保留，但完整 actor 更新有 694 个 critic 梯度超差，禁止作为通过版本。新增 `native_cross_preserve_forward`：保留原前向乘减顺序，使用精确叉积 VJP `b×g, g×a` 的原生运算；输入梯度不截断，非 straight-through estimator |
| SMC 的 SO(3) 零项、单位阵不连接输入梯度；我们用可求导输入乘零构造常量 | `detached_rotation_constants` 只移除常量分支的梯度边，保留原前向值、small-angle 分支及 epsilon；world 与 actor 两条积分路径都接入 |
| world 8 步拟合中统计量不更新，却每步重新计算输入和输出标准差 | `world_norm_snapshot` 在单个 fitting 窗口/分块内复用不可变 mean/std，下一窗口重新创建；额外保留 1 MiB 内存额度，不扣减旧包络 |

直接原生叉积与保留前向顺序的 VJP 路径互斥。新选项均默认关闭，旧实现、旧二进制和旧结果保留。未放宽 `atol=2e-6, rtol=2e-4`：world 候选逐项比较 63,442,642 个数值，actor 保留前向的叉积、常量及组合候选逐项比较 64,003,530 个数值，均零超差，参数/梯度/Adam/metadata/metrics 全部通过。直接原生叉积的 694 个超差仅出现在 critic 梯度，失败记录保留。CPU 两轮各执行 11 个回归检查，覆盖非连续张量、两侧解析梯度、任意轴/非零枢轴混合链、零/小角度/一般旋转以及归一化统计刷新。

固定 iteration60 权重、Adam、normalizer、输入、噪声、排列；actor4096=8×512、H32、20 次 critic 更新，world 一次2048×8更新。每个因子在同一进程执行 A/B/B/A 四块，每块3次预热+10次测量；每个样本重新恢复，不重复初始化进程。52个样本的指标及执行选项均再次核验。以下均无 profiler，不包括采样、恢复、上传、导出，也不是完整训练一轮。

| 独立因素或组合 | 原版 / 候选 ms | 平均节约 ms | A→B / B→A 节约 ms | 判断 |
| --- | ---: | ---: | ---: | --- |
| 叉积 VJP，actor/critic | 1717.252 / 1699.440 | 17.811（1.04%） | 10.935 / 24.687 | 两种顺序均改善 |
| world 归一化缓存 | 68.082 / 67.918 | 0.164（0.24%） | 0.297 / 0.030 | 幅度很小 |
| 旋转常量，world | 68.100 / 68.027 | 0.073（0.11%） | -0.076 / 0.223 | 方向不一致，未证明稳定收益 |
| 旋转常量，actor/critic | 1725.296 / 1716.001 | 9.294（0.54%） | -0.688 / 19.277 | 方向不一致，未证明稳定收益 |
| 三项组合，actor/critic | 1733.255 / 1696.210 | 37.045（2.14%） | 28.086 / 46.003 | 两种顺序均改善，不将单项收益相加 |
| 三项组合，world | 68.047 / 67.883 | 0.164（0.24%） | 0.098 / 0.231 | 幅度很小 |

同配置 SMC compiled 新鲜短测为 world **56.473 ms**、actor/critic **1310.783 ms**；组合候选分别还差 **11.410 ms（1.202 倍）**、**385.427 ms（1.294 倍）**。这两个参照进程在完成3次预热+10次计时后，都被原有跨语言数值断言拒绝，真实退出码为1。断言没有删除、容差没有修改；不能称为数值等价目标或已通过训练验收。SMC 时序对照是单顺序新鲜参照，独立因素的因果收益依据上面的 native ABBA，不将两者混为同一实验。

完整结果见 [results.json](../output/spark-runtime-20261024/smc-primitives-20261028/results.json)。组合选项见 [execution-override.json](../output/spark-runtime-20261024/smc-primitives-20261028/execution-override.json)，仅供显式叠加到本轮已对齐的基线，不改变架构、microbatch、学习率或 checkpoint 模式。实际收益目前主要体现在 actor/critic；不能说 world 的主要差额已经被修复。原实现仍是可直接选择的对照，库默认值未改。

native ABBA 期间 Torch reserved 峰值为 5,119,148,032 bytes（4.77 GiB，设备总容量约3.92%），采样最低 host available 为115,378,987,008 bytes，容器 swap=0、无OOM。UMA 的 Torch/cgroup/host 计数口径不同，不能相加。

少量阶段 CUDA event 的独立诊断见 [phase-results.json](../output/spark-runtime-20261024/smc-primitives-20261028/phase-results.json)，没有启用 Nsight、逐算子或逐 autograd 节点观察器：

| 阶段 | 本轮基线 / 组合 ms | SMC compiled ms | 组合相对 SMC 差额 ms |
| --- | ---: | ---: | ---: |
| actor 反向，累计8次 | 962.396 / 923.444 | 726.661 | 196.783 |
| actor 前向+几何+奖励+尾值，累计8块 | 490.346 / 495.873 | 359.866 | 136.008 |
| world 反向，单次更新 | 45.012 / 45.064 | 38.296 | 6.768 |
| world 前向+误差，单次更新 | 19.376 / 19.128 | 13.693 | 5.435 |

这组阶段观察支持收益集中在 actor 反向（约38.95 ms）；actor 前向复合项和 world 反向**没有测出改善**。前向复合项的两边边界仍有差别：SMC 包含 termination，而 native 的 soft failure/return 组装位于标记外。因此不能把136.008 ms当作完全同范围的因果差额，也不能把所有阶段差额直接加成整轮账单。CUDA event 测量的是 stream elapsed（含排队空隙），与CPU提交时间重叠，不是纯 kernel 活动时间。

事件窗口相对无 profiler 参考的整段差值：native actor 基线/组合分别 -2.409/-2.120 ms，SMC actor +0.773 ms；world 分别 +0.217/-0.065/-0.691 ms。它们来自不同进程，也包含漂移，负差不能解释成“计时器有负开销”。本轮没有再观察到此前完整 ATen trace 的数百毫秒扰动；分段仍是单顺序诊断，headline 收益仍只取无 profiler 的 ABBA。

冻结源码、CPU/GPU 数值门槛和 ABBA 结果位于 `output/spark-runtime-20261024/smc-primitives-20261028/`。本轮 ABBA 入口为该目录下 `suite_primitives_d.mbtx`，每轮执行前检查全量数值 gate；`scripts/report_smc_primitives.mbtx` 收集并核验结果。保护阈值未降低。一次启动被原有 64 GiB CUDA free 前置检查拦截，未执行训练、未 OOM；随后仅对本任务已关闭作业的文件使用 `POSIX_FADV_DONTNEED`，初次回收 2,354,565,120 bytes，无文件删除或全局缓存清理。后续每次短测结束继续按已关闭容器的身份和目录范围回收本任务输出缓存，全部在计时区域之外。

阶段诊断另遇一次 SMC 启动前 free 检查：host available 仍充裕，但文件页缓存占用了 CUDA 可见 free。诊断入口更新为 `run_primitives_e.mbtx` / `suite_primitives_e.mbtx`：原训练 checkpoint 的 replay 文件只用于哈希审计，实际短测从独立冻结 export 恢复；因此哈希后、GPU 启动前，用既有 owner/终止状态/挂载/独占锁/committed receipt 校验，仅回收该已结束作业的 payload 文件页。未跳过哈希、未改训练输入或保护线。已结束 SMC 作业的独立 Inductor cache 也可按相同归属检查回收文件页，不删除编译文件。失败启动、一次脚本编译错误及后续修复均保留各自日志，没有覆盖结果。

可在179上用 `invoke_primitives_e.mbtx -- actor native off 13 新的英文标签 abba-safe` 重测组合ABBA；`world` 替换 `actor` 测 world。标签必须是新的小写英文字母/数字/连字符串；13表示每块3次预热+10次有效样本，ABBA一共52次恢复与更新。单因素分别使用 `abba-preserve`、`abba-constants`、`abba-snapshot`。原语代码见 [native_cross.inc](../src/learning_tensor/native_cross.inc)，归一化复用见 [world_norm_snapshot.mbt](../src/learning_aligned_gpu/world_norm_snapshot.mbt)，常量分支见 [geometry/rotations.mbt](../src/learning_aligned_gpu/geometry/rotations.mbt)。

## 2026-10-28：继续源码对照，区分算序修正与可启用优化

原始数据与数值检查见 [本轮完整结果](../output/spark-runtime-20261024/smc-algebra-20261028/results-final.json)。本轮单 agent，重新读取 SMC `networks.py`、`rotations.py`、`mdp.py`、`train.py` 和 `kinematics.py`。上轮原生 LayerNorm/Linear、朝向误差、航向、world 误差批量化及零枢轴 FK 路径均作为本轮共同基线；没有再次把它们计作本轮收益。

新增三个独立、默认关闭、写入 checkpoint 和审计身份的选项，旧公式和旧插件路径均保留。启用时要求插件提供相应能力，缺失时明确拒绝；没有静默回退：

| 选项 | 读源码确认的差异 | 新实现 |
| --- | --- | --- |
| `smc_world_rotation` | world 旋转误差的向量归一化使用手工展开范数 | 按 SMC 的矩阵→四元数→旋转向量表达式，使用原生 `linalg_vector_norm`，保留 epsilon、分支和运算顺序；同时接入 world target/error |
| `smc_xi_normalization` | 摩擦等上下文输入被改写成乘法加偏置，FP32 顺序与 SMC 不同 | 保留 `(x-.75)/.45`、`x/.01`、`x/.05` 的减法/除法顺序 |
| `smc_actor_return` | actor 用 32 次逐步前缀积和目标累加 | 按 SMC 使用 `cumprod`、Float32 折扣幂、批量归约和尾值乘法顺序；保留软存活梯度、完整 critic 和优化器检查 |

实现见 [原生张量运算](../src/learning_tensor/smc_algebra.inc)、[MoonBit FFI](../src/learning_tensor/smc_algebra.mbt)、[GPU learner 接入](../src/learning_aligned_gpu/smc_algebra.mbt)。这些改动对齐表达式，没有自定义反向或删减梯度；不能把一次 FFI 提交称为融合 kernel。

固定 iteration60 的权重、Adam、normalizer、张量、噪声和排列；每次重复恢复后再计时。双方 actor4096=8×512、H32，包含 20 次 critic 更新；world 为一次 2048×8 更新。无 profiler，每进程 3 次预热+10 次有效样本，下面为本轮单顺序中位数，**不是完整训练一轮，也不是已确认的稳定加速**。

| 阶段 | 本轮基线 | 三项组合候选 | SMC compiled | 候选与 SMC 耗时差 |
| --- | ---: | ---: | ---: | ---: |
| world 单次更新 | 67.978 ms | 67.408 ms | 56.719 ms | 10.689 ms，1.188 倍 |
| actor/critic | 1727.445 ms | 1714.280 ms | 1315.404 ms | 398.875 ms，1.303 倍 |

world 旋转单项 67.880 ms、xi 单项 68.008 ms，组合观察下降仅 0.570 ms（0.84%），不足以宣称稳定收益。actor xi 单项 1720.112 ms、回报单项 1695.868 ms；后者首次观察少 31.577 ms，但随后全量数值验收失败，未启动原先准备的反向顺序性能确认，也未启用候选。

验收保持 `atol=2e-6, rtol=2e-4`：

- world 三个候选各比较 63,442,642 个参数、梯度、Adam 数值，超差为 0，normalizer metadata/metrics 通过。组合与 SMC eager 比较 63,446,536 个数值也全部通过。
- actor xi 有 344 个超差，位于 critic 梯度；回报单项有 1 个 `policy-18-gradient` 超差，最大绝对差 `2.9616057872772217e-6`，最大容差比 1.20837；组合 345 个超差。其余 checkpoint metadata/metrics 均通过，但不将总体通过率代替逐项验收。
- actor 组合与 SMC eager 仍有 19,721 个数值超差，最后策略层梯度余弦相似度 0.999998872。与 SMC **compiled** 的同层梯度余弦相似度为 **0.780390**，最大绝对差约 0.050244；上轮 compiled 记录也有类似差异（0.780866），并非本轮新出现。world 对 compiled 亦有 142 个超差。因此 compiled 耗时只作执行时间参照，不能表述为数值等价目标；当前没有证据确定编译版梯度差异的具体原因。
- 11 个实际 CPU 回归检查通过，涵盖旋转/归一化/回报导数、零存活梯度、原有几何、配置、checkpoint 模式拒绝及 inference。`moon check`、`moon info`、`moon fmt` 完成，接口新增均为上述显式选项/可选元数据/FFI 方法。所有新选项保持默认关闭；没有放宽数值门槛。

资源保护保持原值、GPU 任务串行：Torch reserved 峰值 5,576,327,168 bytes（约 5.19 GiB），cgroup 峰值 5,338,787,840 bytes，采样最低 host available 112,997,343,232 bytes；无 OOM、容器 swap 为 0。UMA 指标不能相加。只回收本任务已结束作业的可回收文件缓存，保留数据和全部旧实现。

复测与验收脚本为 `scripts/run_smc_algebra.mbtx`、`scripts/compare_smc_algebra_runs.mbtx`、`scripts/summarize_smc_algebra.mbtx`。冻结实现是 `algebra_fixture_a.mbt`、`run_algebra_b.mbtx`、`smc-algebra-gate-b` 和 `libmoonrobo_smc_algebra_a.so`；新名称输出采用 CreateNew，旧结果不覆盖。`confirm_smc_algebra_return.mbtx` 含全量数值门槛，本轮因该门槛未过而未运行。

## 2026-10-27：源码对照修复与固定输入复测

最新原始结果见 [heading/FK 复测](../output/spark-runtime-20261024/smc-heading-20261027/results.json)，前一轮三项修复见 [source fixes](../output/spark-runtime-20261024/smc-source-fixes-20261027/results.json)。下文 10 月 24 日的整轮协议、默认路径说明和旧测速记录保留作历史对照。

本轮继续单 agent，读取 `../smc/supermimic/{rotations,networks,kinematics,train}.py` 后修正已确认的差异：

- 朝向误差使用显式 `rotation_error_mode="trace_acos"` 对齐 SMC；新增 `heading_mode="smc_projected"`，将 `sqrt(x*x+y*y+1e-9)` 贯穿 GPU world 输入、目标、误差、积分，以及奖励/critic 的航向重锚定。原 quaternion-log 和轴切换路径保留。两种几何选择均写入 checkpoint 与审计身份，缺字段解释为旧模式，恢复时拒绝静默更换。
- world 的 8 步误差使用已有独立批量路径；MLP 使用原生 LayerNorm、原生 Linear，policy 和 critic 也可显式选择原生 Linear。原展开路径保留；这些更改的单因素证据存于前一轮结果，不与新收益直接相加。
- 阅读 SMC FK 后确认 G1 MJCF 的 29 个关节枢轴全为零。新增默认关闭的 `zero_joint_pivot=true`，仅当实际枢轴严格为零时跳过原点和线速度补偿；qref 严格为零时跳过恒等偏移。非零枢轴、非零 qref、固定连杆及任意关节轴仍受支持，未将 G1 假设硬编码到其他机器人。

同 iteration60 权重、Adam、归一化状态、输入、噪声和排列，每次重复先恢复，恢复/上传/导出不计时。无 profiler，每进程 3 次预热、10 次有效样本，零枢轴按 ABBA 运行；SMC 使用原源码编译路径，双方 actor 均为 4096=8×512、H=32、20 次 critic 更新。

| 测量 | MoonBit | SMC compiled | 差额 |
| --- | ---: | ---: | ---: |
| actor/critic，零枢轴优化后 | 1720.54 ms | 1310.21 ms | 410.33 ms，1.313 倍 |
| world，一次 2048×8 更新 | 68.21 ms | 56.07 ms | 12.14 ms，1.217 倍 |

零枢轴对照基线为 1812.05 ms，优化后 1720.54 ms；两组顺序分别节约 67.80、115.23 ms，平均节约 91.51 ms（5.05%）。world 仅做同配置单顺序复测，不是 ABBA。以上均不含采样，也不是完整训练每轮耗时。

数值检查：零枢轴整段更新比较 **64,003,530** 个参数、梯度和 Adam 状态数值，固定 `atol=2e-6, rtol=2e-4` 下超差为 0，metadata/metrics 也通过。另有 8 个实际执行的 CPU 回归测试覆盖航向边界值/导数、混合 FK、配置、checkpoint 拒绝和 inference 兼容；不把 SKIP 算作通过。

只更换航向公式的单因素对照，使 policy 最后一层梯度对 SMC eager 的余弦相似度从 0.934410 提高到 0.999998864，最大绝对误差从 0.0287873 降至 0.000102878。**严格全量跨实现数值检查仍未通过**，包括 SMC compiled 对照；新路径未升级为默认。这些选项验证的是固定输入 GPU 学习路径，不能据此声称 CPU 物理奖励、数据预处理、采样算法以及完整论文训练均已复现。

内存保护保持原值，GPU 作业串行，无 OOM、无容器 swap；本组 Torch reserved 峰值 5,576,327,168 bytes，cgroup 峰值 5,400,477,696 bytes，采样到的 host available 最低 113,027,424,256 bytes。UMA 计数有重叠，不能相加。只对本任务已结束作业的文件做缓存回收，未删文件或全局 drop cache。

复测入口为 `scripts/run_smc_pivot_pairs.mbtx`，使用冻结的 `run_heading_b.mbtx`、`heading_fixture_b.mbt` 和 `smc-heading-gate-b`；源码检查和报告入口分别为 `scripts/verify_smc_heading.mbtx`、`scripts/report_smc_heading.mbtx`。各输出名要求全新，原二进制与全部原始结果保留。

## 历史协议与差异清单（2026-10-24）

核对日期：2026-10-24。本文依据当前工作区源码，不把参数名称相同视为逐位数值等价，也不把短程吞吐当作收敛效果。

SMC 对照版本为 `a1508d42c9d1699a52e8233ab16d08c488441ab9`；原版运行证据见 [SMC benchmark](../output/spark-runtime-20261024/smc-original-benchmark-20261024-b/README.md)。原版默认 BF16、500 轮仅世界模型、共 600 轮；521–600 轮日志区间均值为 **1.055826 秒/轮**。此前 MoonBit 约 6.61–7.00 秒/轮采用不同观测、精度、自碰撞、actor 分块和训练阶段，约 6 倍比值只是定位线索，不能作为受控语言或实现速度结论。

## 共同短程协议

本轮主比较使用双方共同修改的吞吐协议：`N=256`、`seed=0`、初始物理采样 64 步、20 轮仅世界模型、总共 60 轮，报告第 41–60 轮。历史 500/600 轮原版记录独立保留，不混入这组成对样本。短协议既不复现论文训练预算，也不证明策略收敛。

完整 FP32 actor4096 的共同配置是对齐目标，须先通过准入；当前 runner 同时准备两个独立、不得合并统计的受控协议：

| 协议 | SMC actor | native actor | 60 轮想象转移 | 每次 critic minibatch 样本数 | 解释 |
| --- | --- | --- | --- | --- | --- | --- |
| 共同 batch512、双方完整执行 | 512 full | 512 full | 655360 | 4096 | 双方逻辑/执行 batch 相同；不能直接对照历史 SMC actor4096 的每轮时间 |
| 共同逻辑 batch4096、native 分块512 | 4096 full | 4096 logical /512 micro | 5242880 | 32768 | 逻辑工作量相同，native 梯度累积/提交布局不同，需披露执行差异 |

两种协议的 WM 配置、真实转移 54784、WM 更新 600、actor 更新 40、critic 更新 800 均相同。native microbatch 不是逻辑训练 batch；不得把 512→4096 的逻辑工作量变化写成优化加速。此处仅定义待测协议，没有宣称任何一组已通过或完成。

| 项目 | 共同值 | 当前对齐条件 |
| --- | --- | --- |
| 数据 | 同一组 40 条 LAFAN1 G1 CSV、逐文件 SHA-256、30 Hz 输入→50 Hz 控制参考 | 比较实际 CSV、顺序、帧数和机器人资产；数据集名称相同不够 |
| 环境 | 256 个 G1，0.02 s 控制、4×0.005 s 物理子步，最大 episode 500 步 | native APIC 产物必须与 N256、关闭自碰撞及资产身份一致 |
| 观测 | SMC 99 维，历史 10 帧 | native `observation_mode="smc"`；Paper93 不进入主比较 |
| 目标 | 10 帧预览，每帧 73 维，总计 730 | 预览从当前参考的下一帧开始，越界重复当前 clip 最后一帧 |
| 精度 | 权重、状态、优化器 FP32，TF32 开启 | SMC `--amp none`；native `precision="float32", amp="none", allow_tf32=true` |
| 网络 | WM `[2048,2048,2048]`；策略编码器/解码器 `[2048,1024,512,256]`；critic `[256,128]` | 两个策略 MLP 中间潜变量 32，编码器末端 tanh；WM SiLU+LayerNorm、策略/critic ELU |
| replay | 1000 个时间行，每行 256 个环境 | 主比较 fresh run；两边持久化及 resume 行为不同 |
| 世界模型 | batch 2048，8 步递推窗口，每轮 10 次更新 | native `wm_microbatch=0`，一次完整逻辑 batch；须通过内存准入 |
| actor | batch 4096，32 步想象，每轮一次更新 | native `pi_microbatch=0`，与 SMC full actor 路径一致；不能准入失败后静默缩小 |
| critic | 5 epochs ×4 minibatches | `32×4096=131072` 个非尾帧样本，每个 minibatch 32768 |
| 优化器 | lr `2e-4`，Adam ε`1e-8`；WM/critic β`(.9,.999)`，actor β`(.9,.95)` | 全部 norm clip 1，actor 额外 value clip 0.1；异常梯度处理另列 |
| 回报 | γ`.99`、λ`.95`，想象奖励加 critic 尾值 | actor 使用旧 critic normalizer；critic 用本次轨迹更新 normalizer 后计算 bootstrap |
| 调度 | UTD `.4`，物理采样步数每轮交替 2/3；余弦 lr 250000 轮降到 3% | 第 21 轮开始 actor；测量窗口双方相同 |
| 随机化 | friction/COM 每环境初始化一次；关节零偏每次 reset | native 显式 `context_resampling="environment"`；默认 `episode` 与 SMC 不同 |
| 噪声 | reset noise 开启，观测 uniform noise 开启，真实动作 Gaussian σ`.1` 后 clamp `[-20,20]` | 想象动作不加该探索噪声、不 clamp |
| 碰撞 | `self_collisions=false` | 原版 SMC 固定关闭；native 默认开启，配置及编译产物都要修改 |
| 诊断 | 保留内存准入、阶段同步采样和余量保护；执行 profiler 单独运行 | native `telemetry_max_samples=512` 可保留整个 60 轮窗口，默认仍 128；最多 1024 |

SMC 命令的训练参数部分：

```sh
python -u supermimic/train.py --num_envs 256 --iterations 60 --seed 0 \
  --warmup_steps 64 --wm_only_iters 20 --buffer_steps 1000 --utd 0.4 \
  --wm_batches 10 --wm_batch 2048 --wm_window 8 --pi_batch 4096 \
  --horizon 32 --hist 10 --goal_frames 10 --lr 0.0002 --gamma 0.99 --lam 0.95 \
  --critic_epochs 5 --critic_minibatches 4 --action_noise 0.1 \
  --lr_decay_iters 250000 --amp none --log_every 10 --ckpt_every 60 \
  --motion_dir DATA_DIRECTORY --log_dir RUN_DIRECTORY
```

native 对应参数片段如下；它不是独立启动包，运行还需要真实库路径、场景、数据 manifest、APIC bundle 及准入检查。`paper-4096` 表示容量协议，不能据此宣称论文完整复现。显式放宽到 80% 的既有准入上限仍须保持 16 GiB 阶段余量保护，不能为凑满 batch 绕过失败。

```json
{
  "capacity_profile": "paper-4096",
  "backend": "isaac", "device": "cuda:0", "physics_device_id": 0,
  "num_envs": 256, "seed": 0, "iterations": 60,
  "warmup_steps": 64, "wm_only_iters": 20, "buffer_steps": 1000,
  "utd": 0.4, "lr_decay_iters": 250000, "checkpoint_every": 60,
  "observation_mode": "smc", "hist": 10, "goal_frames": 10,
  "wm_hidden": [2048, 2048, 2048],
  "pi_hidden": [2048, 1024, 512, 256], "critic_hidden": [256, 128],
  "wm_batch": 2048, "wm_batches": 10, "wm_window": 8, "wm_microbatch": 0,
  "pi_batch": 4096, "pi_microbatch": 0, "horizon": 32,
  "lr": 0.0002, "gamma": 0.99, "lam": 0.95,
  "critic_epochs": 5, "critic_minibatches": 4,
  "precision": "float32", "amp": "none", "allow_tf32": true,
  "self_collisions": false, "randomization": true, "reset_noise": true,
  "context_resampling": "environment", "max_episode_steps": 500,
  "physics_dt": 0.005, "observation_noise": true, "action_noise": 0.1,
  "reference_storage": "mmap", "telemetry_max_samples": 512
}
```

保留所有执行优化默认关闭的基线；实际配置还应记录 `reuse_geometry`、`reuse_critic_normalization`、LayerNorm 实现、critic CUDA graph、梯度桶、参考驻留、Adam 路径和混合精度等新选项，不能依赖后续可能变化的默认值。若完整 FP32 actor 未通过准入，本 cell 应报告拒绝；可以另立双方相同较小 batch 的成对 cell，或把 native microbatch 独立列为执行消融。

无 actor-readiness 补采时，60 轮的可核验工作量为：真实转移 **54784**（`(64+150)×256`）；WM 更新 **600**，WM 拟合槽位 **9830400**；actor 更新 **40**，想象转移 **5242880**；critic 更新 **800**。补采、跳过更新、提前结束都必须单列，不能继续标作相同工作量。

## 已确认相同的主干数学

定义在 [SMC train.py](../../smc/supermimic/train.py)、[native learning.mbt](../src/learning_aligned_gpu/learning.mbt)、[geometry/state.mbt](../src/learning_aligned_gpu/geometry/state.mbt) 和 [learner 默认参数](../src/learning_aligned/learning.mbt)。当前检查是源码级对照，尚不是跨语言同输入梯度实测。

- WM 从窗口第一个状态开始连续递推 8 步；在目标状态的局部坐标计算 70 维误差，除以输出 normalizer 标准差与逐维 floor 的较大值。每步误差先对 70 维平均，然后乘有效 mask，按时间求和、按 batch 平均；训练 loss 没有额外除以 8。终止转移本身保留，后续步 mask 为零。
- actor 的 `c_t=∏_{j<t}(1-d_j)`，优化 `mean[Σ γ^t c_t r_t + γ^H c_H V(s_H)]`。软终止用于奖励存活权重和尾值；固定世界模型/critic 参数但保留输入梯度。实际训练路径启用 critic。
- critic 收集初始状态和 32 个后续状态；先对整个 33 帧逻辑轨迹更新 normalizer，再算旧权重的 bootstrap；反向递推 `R_t=r_t+γ(1-d_t)[(1-λ)V_{t+1}+λR_{t+1}]`，末值 `R_H=V_H`。target detached；5 次重新洗牌，每次 4 个 minibatch、每批独立 Adam step。
- 归一化使用 population variance、并行合并公式，通常 ε`.01`，WM 输出 ε`.0001`，样本计数达到 `2e8` 后停止更新。真实采样时 policy obs/goal norm 在动作计算前更新，WM 输入/输出 norm 在实际转移完成后更新；想象不更新 WM/policy norm。
- 动作是默认关节姿态加按执行器缩放的 action，再加校准零偏；G1 29 关节顺序、14 个跟踪 body、10 Hz/阻尼比 2 的执行器参数表和 `0.25*effort/stiffness` 缩放一致。
- 观测中的 qd/root angular velocity 没有额外固定缩放：SMC `OBS_SCALE` 和 native `observation_scale` 虽有定义，这两条训练路径均未应用，实际由 RunningNorm 处理。不能只看常量表推断遗漏。

## 仍不同的数学与数值行为

这些差异不能通过上述 JSON 消除，也不能用“相同 seed”掩盖。有关几何兼容模式的改动应单独标记训练身份并保留 robust 默认。

| 项目 | SMC | native 当前基线 | 对比较的影响 |
| --- | --- | --- | --- |
| 朝向奖励误差 | `acos(clamp((Σ A*B-1)/2, -1+1e-6, 1-1e-6))²` | `||so3_log(A Bᵀ)||²`，经 quaternion 选择和归一化 | 接近零/π时值及梯度不同；SMC 完全对齐时仍有约 `2e-6` 的角度平方 floor，native 为零；非正交矩阵时也不同 |
| yaw | 只投影 X 轴，分母 `sqrt(x²+y²+1e-9)` | X 轴投影平方小于 `1e-12` 时改用 Y 轴，分母下限 `1e-12` | 竖直姿态附近会实质改变 heading，影响 WM、参考目标、奖励重锚定和 critic；普通姿态仍有舍入差异 |
| reset bin 更新 | 重复 bin 的 `index_put_` 没有聚合，相同 bin 的并发写入依赖写入行为 | 同一批完成 episode 按 bin 求平均，再 `.8 old+.2 mean` | reset 概率的真实算法差异，native 的确定性聚合不能声称复刻 SMC scatter |
| reset bin 尾部 | `ceil(frame_count/50)` 可创建仅末帧的 bin | `(frame_count-2)/50+1` 排除没有后续转移的 bin，采样再次过滤 | 当 clip 长度模 50 为 1 时不同；是否涉及当前数据须查实际长度，不能泛化为当前运行必现错误 |
| RunningNorm | count 为 GPU FP32 scalar；方差 `torch.var(unbiased=False)` | count 为 CPU Double；方差展开 `mean((x-mean)²)` | 公式相同，归约/舍入及大计数行为不完全同构；本短协议计数尚小，但不能宣称逐位相同 |
| LayerNorm | `nn.LayerNorm(eps=1e-5)` | 默认展开为多个张量算子；可选原生 LayerNorm | population variance 数学相同；归约实现、kernel 数、舍入不同 |
| 参考计算 | CSV 先转 FP32，GPU 重采样/差分/FK、参考 body 常驻 | CSV/固定窗口参考经 Float64 CPU 计算，再上传 FP32；默认想象中重算参考 FK | 相同文件不代表浮点值相同；需固定输入 fixture 验证状态、速度、goal、FK |
| RNG 和初始化 | PyTorch CPU/GPU RNG；Linear 先初始化，WM 最后层再置零 | MoonBit RNG，部分零层不消耗相同随机数；不同调用顺序 | 相同 seed 仅标识各自实验，不能使初始权重、噪声、frame、permutation 一致 |
| 非有限梯度 | actor clip 后判断 norm，坏 step 跳过；WM/critic 没有同样 fail-stop | 所有 Adam 在写参数前检查梯度/范数，不合法则停止 | 失败处理不同；不能为提速删除安全语义，发生异常的 run 不能作有限梯度等价样本 |
| critic 余数 | floor minibatch 切片，余数丢弃 | `tensor_split` 语义，早期 minibatch 接收余数 | 主 cell 131072 可被 4 整除，差异不触发；改变 batch/horizon 后要重新核验 |

几何实现见 [SMC rotations.py](../../smc/supermimic/rotations.py)、[native GPU rotations](../src/learning_aligned_gpu/geometry/rotations.mbt) 和 [native CPU rotations](../src/learning_aligned/rotations.mbt)。reset 更新见 [SMC env.py](../../smc/supermimic/env.py) 与 [native sampling](../src/learning_aligned/sampling.mbt)。归一化见 [两边网络之一：native](../src/learning_aligned_gpu/networks.mbt) 及 [SMC networks.py](../../smc/supermimic/networks.py)。

完整 `geometry_semantics=smc` 候选需要统一传播到 GPU Context、world 输入/目标/误差/积分、CPU goal/物理奖励、参考缓存和 checkpoint identity；只替换 actor reward 会制造另一种混合算法。现有两个 robustness 差异在普通有效旋转下不一定导致大误差，但不能据此跳过近零、近 π、竖直和轻微非正交矩阵的值/梯度检查。

## 采样、物理与执行路径

SMC replay 和参考都在 GPU；native replay 采用主机紧凑存储，参考默认 mmap，准备时进行 CPU 浮点数组转换和上传。两边 WM 窗口均对开始时间与环境均匀抽样；native 还检查 frame/episode 连续性，正常环境序列下与 SMC done mask 一致。actor 均从能容纳完整参考 horizon 的 replay 起点中均匀抽样：SMC rejection sampling，native 先枚举有效目录；采样分布可一致，随机数消耗和准备开销不一致。

native 在没有完整 horizon 候选时有限补采，并报告额外步数；SMC 的循环可能一直等待有效样本。主比较必须确认额外步数为零。native resume 会验证/补齐 replay；SMC resume 没有恢复 replay 且跳过 fresh warm-up，不能把原版 resume 直接用于共同 benchmark。

SMC 用 IsaacLab/ Newton MJWarp；native 用已验证的 APIC bundle 驱动原生接口。控制周期相同、执行器表相同仍不足以证明物理逐步等价；需核验场景/URDF/USD 哈希、solver 参数（implicitfast、pyramidal、contact 限额）、friction/COM 写入、link-frame 速度、重置后的 solver cache、实际自碰撞设置及 bundle contract。应保留既有物理 gate 的结果，不能仅在配置中写 `isaac` 就视为同后端。

## 时间边界与可解释的优化候选

原版 SMC `it_per_s` 是日志块 wall time；计算它发生在把 GPU metric 转成 Python float 之前，因此最后的异步工作/日志回读可能记入下个块。native 阶段 telemetry 显式同步并读主机/cgroup，iteration 还包含采样、上传及物理接口开销。两个日志的“每轮”不能直接视作相同 GPU 完成边界。

主比较需保留共同 window、完成边界、cold compile/startup、最终 checkpoint 和容器总时长的独立记录。不得通过删除 native 内存保护换取表面公平；如果 SMC 未加同样阶段同步，主结果应称“相同训练配置下的受保护 native vs 原版 SMC”，把诊断开销列为残余差异，另做同步边界消融。执行 profiler 的嵌套 CPU/CUDA 区间不可直接求和，CUDA event elapsed 包含等待，不能当作纯 kernel 时间。

当前源码中可直接定位、但仍需实测的候选：

1. full WM 每次 update 回读 loss/最后步误差，full actor 每个 critic minibatch 回读 loss；前者一轮 20 个标量回读，后者 20 个。之前 microbatch 汇总优化不自动覆盖 full 路径。可把 detached scalar 集中到既有安全边界回读，保持指标定义与异常处理。
2. native 朝向误差每个状态计算 15 次（14 bodies+root）；每次使用矩阵乘、4 个 quaternion candidate、选择、归一化及 atan2，而 SMC 是 9 元素乘加归约、clamp、acos。它既是语义差异，也是明确的算子开销候选；静态数量不能替代测速。
3. SMC `torch.compile` 覆盖 WM 展开、误差、imag step、reward/termination、critic input；native 默认逐算子 LibTorch。必须按已执行路径、编译冷启动和稳定 window 比较，不能把 BF16、compile 和计算重用一起开再逐项归因。
4. 参考重采样、重复 goal/FK、主机 replay 与多次上传、真实动作回读，是 native 数据路径的候选；参考驻留要有显式容量上限并计入峰值准入，不能把全数据驻留作为无界默认。
5. Python Adam 可能采用其 CUDA 默认的 foreach 路径，C++ Adam 实现路径不同；需要固定版本下记录实际 optimizer 路由。native 非有限梯度检查和 norm 检查保留，通过合并计算减少提交/等待；有限输入下仍要核验梯度与 Adam 参数/一二阶矩/step。

以上不能拼成预计加速倍数。特别是原版 BF16 只包围 MLP，输出回转 FP32；状态积分、运动学、奖励仍 FP32，权重和 Adam 状态也 FP32。审计起点的 native CLI 仅支持 FP32；本轮新增了显式 BF16 MLP 候选，保留 FP32 master 参数和默认 `amp=none`。该候选必须单独验证支持范围和实际路径，不能将新选项出现视为混合精度对齐已经验收，更不能把整个 learner 设成 BF16。

## 建议成对矩阵及判定

| Cell | 固定项 | 唯一变化/目的 | 必须保存 |
| --- | --- | --- | --- |
| A0 共同 FP32 | 上述 60 轮协议、TF32 on、完整逻辑 batch | SMC vs native baseline；保留披露的语义/物理/诊断差异 | 双方源码/配置/数据/资产/库 SHA、计数、内存与原始日志 |
| A1 精度 | SMC 同配置、compile 不变 | `amp none` vs `bf16` | finite/skip 状态、损失、峰值与成对时长 |
| A2 native scalar 回读 | 同一 native 固定输入和完整 batch | 保持数值，仅合并日志回读 | 各 update 权重/梯度/Adam/normalizer 对照 |
| A3 native 参考准备 | 同一 native、同抽样/RNG 顺序 | 有界参考/goal/FK 驻留与复用 | 缓存字节、峰值、索引/参考/梯度对照 |
| A4 几何兼容 | 显式独立训练身份 | robust 与完整 SMC 几何模式 | 近零/π/竖直 fixture、奖励和梯度差异；不得标作纯执行优化 |
| A5 LayerNorm/Adam | 每次只切一个候选 | 原生 LN、保留保护的 Adam 合并计算 | 真实路径计数、参数和 optimizer 状态、失败前不写参数 |
| A6 编译/图 | 相同模式、shape、batch 和同步边界 | SMC eager/compile；native eager/分段 graph 分开比较 | graph 捕获/重放计数、冷启动、额外池内存 |
| A7 双机 | 单机优化先冻结，固定 global batch | 独立种子与分布式分别计数 | NCCL 路径、每端时间线、通信桶、正常/异常退出；不得混作单机收益 |

每组成对交替 ABBA，保留每个 run、成对比值、整体均值和差异方向；不只挑最快一次。吞吐窗口仍应包含完整工作量，只有原始证据能说明超预算拒绝、非有限梯度、OOM、未完成和后台任务是否出现。CUDA allocator、进程/cgroup 和整机统一内存不是相互独立的可加总值。准入拒绝的 cell 记录失败阶段与字节数，不调低保护继续伪装成同一配置。

跨语言同输入校验需要共同导出的初始权重、normalizer、Adam 状态、replay 索引、参考张量、噪声和每个 epoch 的 permutation；同 seed 不能替代它。学习效果另用完整动作评测、多种子和足够训练预算报告，短程 41–60 轮只回答执行效率。

## 独立朝向算式诊断

[orientation_bench](../src/learning_aligned_gpu/geometry/orientation_bench/main.mbt) 保留生产几何实现，单独比较两种 eager LibTorch 算式。入口参数为 `PLUGIN_PATH cpu|cuda ROWS`；正式 CUDA 诊断使用 `ROWS=57344`（4096×14），单次持有这一批矩阵和其反向图，不同时保留 32 步想象图。编译产物的调用形式：

```sh
orientation_bench /absolute/libmoonrobo_learning_tensor.so cuda 57344
```

插件需要新增 unary opcode 18（ATen `acos`）；旧插件会显式报告 `unknown unary operation`，没有近似替代或静默 fallback。测试 `acos opcode computes values and gradients or explicitly refuses legacy plugin` 可分别通过 `MOONROBO_TENSOR_ACOS_LIBRARY`、`MOONROBO_TENSOR_ACOS_LEGACY_LIBRARY` 指定新旧插件。

诊断固定输入旋转、FP32、CUDA TF32 on，先 4 次 warm-up，再 5 组 ABBA 共 20 个样本。每个样本同时记录 forward、backward 和 inclusive total，最多 60 个区间/120 个 CUDA events；前后边界显式同步，梯度回读和全量有限性检查在事件区间外。每个边界检查 CUDA free 不低于 16 GiB，报告 allocator 峰值；主机/cgroup 保护由外层 runner 保持。报告内的十对比值只描述这个 primitive，不能推广成端到端训练加速或 Python `torch.compile` 的速度。

两种算式都把 `4096×14` 展平为一个 57344-row 调用，统一了这个 primitive 的向量化布局。生产 native 的默认奖励路径逐 body 循环调用，SMC 将 body 维一起处理；因此这里的比值没有覆盖 native 逐 body 提交的额外开销，也不能直接乘以训练中的全部 orientation 调用次数推算总收益。

独立候选 `body_orientation_batched` 默认关闭，将身体朝向堆叠为 `[batch, body, 3, 3]`，共享 yaw 对齐后展平调用原 `angle_square`，最后按 body 求均值。它保留 quaternion log、clamp、近零与 π 分支及 root orientation 路径，没有替换成 SMC 的 `acos` 算式。批量 GEMM 的舍入与新增堆叠张量的峰值仍需校验；这个候选的成对训练结果与上面的算式诊断分别报告。

另有 8 个近零、普通角度及近 π 的数值 fixture，报告两种算式的角度平方和矩阵输入梯度差异，不把它们强行判作相等。这里的梯度对 3×3 matrix leaf 求导，并非约束在 SO(3) 上的 tangent derivative。GPU 实测结果应另存原始 JSON；本文不预填未测的加速倍数。

## 本轮结果报告约定

以下是报告结构，当前不填入未完成运行的数字：

| 必备栏 | 内容 |
| --- | --- |
| 协议身份 | batch512 full 或 logical4096/native micro512；FP32/BF16；SMC compile on/off；逐项候选开关 |
| 不可变输入 | spec/plan、双方源码、trainer/plugin、镜像、40 条 CSV、机器人资产、APIC bundle 的 hash；实际命令与运行配置 |
| 接受状态 | 完整 ABBA 是否全部通过；拒绝阶段和原因；失败组不取成功子集计算速度 |
| 共同工作量 | 每个 run 的真实/想象转移、WM/actor/critic 更新；native 额外补采为零；SMC 日志全部标量有限 |
| 时间 | 每个 run 第 41–60 轮均值、相邻 AB/BA 两对比值、完整原始行；warm-up/首次编译/容器生命周期/最终 checkpoint 分开 |
| 内存 | CUDA allocator allocated/reserved（可用时）、cgroup high-water 采样、整机 Available/Free 最低值、swap/OOM 事件；缺失量明确留空 |
| 语义限制 | 本文几何、采样、RNG/normalizer、物理与同步边界差异；同 seed 不等于同轨迹 |
| 下一步 | 只根据已测瓶颈选择下一项；候选没有稳定收益时保留默认关闭 |

`summarize_smc_native_pairs.mbtx` 的 iteration time 来源在双方不同：native 是同步 phase-end 边界差值，SMC 是原版 `log_every=1` 的 `1000/it_per_s`。应同时保留其 wall_h 边界值作交叉检查；不能将两个时钟边界的细微差异省略。两种 batch 协议及 FP32/BF16 不得汇总成一个整体均值。CSV 的 6 位有效数字也不支持宣称超过原始精度的测速结果。
