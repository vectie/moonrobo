# Python 依赖：运行时、构建时与复测边界

本轮沿实际命令调用链检查依赖。MoonBit 文件调用 Python 仍然算 Python 依赖；C++ 动态库来自 Python wheel 的安装目录，或者程序读取 `.py` 做 SHA 溯源，则不等于启动解释器。原 Python 源码保留，所有科学验证继续暂缓。

## 依赖分类

最新的 [完整 cooking、刚体接触、稀疏尾部与 Newton 迭代翻译](APIC_FULL_NATIVE_TRANSLATION.md) 已继续补上 EPA/manifold、plane/heightfield、mixed GPU LDL/LU、Newton/CG、紧凑/增量与预条件辅助路径，均通过 MoonBit 与真实原生接口工作。此前 [cooking/device 报告](APIC_COOKING_DEVICE_MIGRATION.md) 的缺口表是历史快照；完整场景/SDK 物理数据生成与四图闭包仍须分别判断，所有运行及等价性复测暂缓。

模型和 GPU 的继续拆分单列于 [本轮实现与剩余缺口](APIC_MODEL_GPU_MIGRATION.md)。新的 resolved shape/contact、七类 primitive contact、混合求解基线、独立 MuJoCo C 碰撞和多内核 GPU 接口均不需要解释器；完整 Newton 四图导出仍按下表保留 Python 依赖。

| 路径 | 是否需要解释器 | 使用阶段与边界 |
| --- | --- | --- |
| MoonNum、Moonphys、MoonBit 训练/推理、MuJoCo CPU 仿真 | 否 | 生产运行时用 MoonBit 和显式原生 C 库。训练数值为 CPU/Double。 |
| 默认实验 `.mbtx` 入口 | 否 | 通过 `scripts/run_native_learning.mbtx` 路由到真实原生参数适配器与算法；旧报告、checkpoint 与 source gate 差异由适配器明确处理。 |
| 默认 E1 collector/writer、桌面 bundle | 否 | 默认选择可构建的 native CLI 与 C++ SDK adapter。缺少可执行文件或共享库时报告不可启动，不回落 Python；文件存在不代表 SDK ABI 或真实设备已验证。 |
| Newton APIC 工件生成器 | **完整四图仍需要** | 原 `producer` 原样保留。MoonBit 已有 builder/常量、完整刚体接触与参考 Newton/CG/稀疏求解路径及原生条件图；固定 profile 宿主顺序也有原生入口。完整 model finalize、物理系数生成、deformable/SDF 调度、SDK 回调与 capture registry 仍有独立边界，尚未自动替换完整 SDK 四图生成。详见 [最新源码与 callable 清单](APIC_FULL_NATIVE_TRANSLATION.md)。 |
| APIC 原生加载、重置、步进 | 否 | 部署生成后的四图工件，由 C++/Warp/CUDA 执行；不链接 producer 或 CPython。SDK/CUDA/工件验证尚未运行。 |
| 原 SMC/Python oracle 的精确执行 | **是** | 仅用于显式复测和生成 `executed-upstream-python` 夹具。独立 C++ oracle 可免 Python，但不能冒称执行了原 Python。 |
| 历史 Python 实现、E1 `python-reference` backend | **是** | 仅在明确选择历史实现时使用，供以后成对复测；`scripts/python_reference/` 同时保留旧的纯 MoonBit 报告脚本，并非每个归档入口都会调用解释器。 |
| `.py` 源文件 SHA 读取、旧 Torch/NumPy 数值文件导入 | 否 | 前者仍依赖源文件作为数据，后者使用受限原生解析器。均不 import/执行 Python，也不执行 pickle callable。 |
| E1 C++ adapter、可选 LibTorch RNG/差分插件 | 否 | 本仓构建目标直接用 C++ SDK/LibTorch，不构建 SDK pybind，也不链接 `libtorch_python`。取得头文件/库时可以使用既有 wheel 目录；这不是解释器运行依赖。 |
| Host API、实验 registry、UI/常规 CI | 否 | 使用 MoonBit、Node/Vite 等已有工具。学习 registry API 只读原生结果，不是 Python 训练调度器。 |

## 本轮入口接入

核心训练、temporal/balance、reference 三组分别提供原参数到真实 MoonBit API 的适配；未知参数与缺失数据明确失败。共享 launcher 按参数数组执行 `moon run --target native`，不经过 shell，也不启动 Python 来查找 MuJoCo。原生仿真需显式 `--library` 或 `MOONROBO_MUJOCO_LIBRARY`。

历史 `.mbtx` 原文保存在 `scripts/python_reference/`；各组 `*-sources.json` 记录原始 SHA。不要格式化这些归档。旧入口的科学 charter/hash 不会自动改写成新结果；需要重新绑定原生产物的配置时，显式传入相应原生配置。原 `.pt` 与 MoonBit JSON 的 optimizer/replay/物理状态支持范围也不能靠修改文件后缀绕过。

显式历史运行入口为 `scripts/run_python_reference.mbtx REPO ORIGINAL_SCRIPT.mbtx [原 REPO 参数之后的其余参数]`。它验证归档 SHA 后才启动历史实现，并给旧 `fit_g1_invariant` 的 `probe_g1_tail` 子入口传播 reference 选择，避免一条旧工作流混入原生子任务。本轮没有运行此工具。

默认脚本里原有的自动 Python unittest 调用不再执行。迁移工具不把它们记为通过；测试源码及历史入口仍然保留，等机器可用后单独复测。

一次性的 `migrate_*`、`repair_temporal_native_sources` 等源码改写配方在审计清单存在时拒绝再次改写入口；后续日常收尾使用 `finalize_python_migration.mbtx`，它只做静态检查、格式化和清单生成。

E1 的 native 安装入口为 `cmd/sdk_e1_native` 与 `scripts/install_sdk_e1_native.mbtx`。桌面发布包包含此 CLI；SDK C++ adapter 必须另外按文档构建并显式配置。`python-reference` 是独立选择，不是缺少原生库时的 fallback。

## 为什么还保留构建期 Python

当前固定版本的 Newton 模型 builder、Warp 内核特化/codegen 和完整物理调度仍由上游 Python SDK 提供。本轮已接入真正的 Warp C APIC authoring/save 与 NVRTC C 编译 API；这些可替代保存和已生成 CUDA 源码的编译，但不会自动生成完整 Newton model 和 solver dispatch。新 hybrid 仍明确记录 `uses_cpython=true`，不能仅因 C 绑定增加就称完整工件生成无 Python。

其中固定 G1 的 manager 循环和 13 个 typed kernel 已有独立 MoonBit 实现；纯原生单内核捕获不依赖 Python。它只覆盖一个 kernel，不是四图物理工件。完整剩余调用链、原生替代入口及 22 份上游源码身份见 [剩余原生迁移审计](APIC_REMAINING_NATIVE_MIGRATION.md)；求解器的 sparse、碰撞、条件循环与模型常量重算仍须逐项迁移。

进一步的 [物理子系统拆分](APIC_PHYSICS_NATIVE_DECOMPOSITION.md)记录新增 23 份源码证据，并区分实际 builder 数组、稀疏 MVM/CSR 力重建、NXN 候选、CUB/条件图接口、常量公式与完整物理流程。新增 `prepare-builder`、`prepare-constants`、`prepare-mass-layout` 和 `compile-physics-kernels` 均为显式入口；本轮未执行这些命令。独立 CPU/Double 数值片段不能直接视为 float32 CUDA 后端的已验证替代。

后续新增 typed model/state/control 存储及独立原生 upload、六类 primitive narrowphase、packed-tree LDL/小块 Cholesky、动态线搜索/收敛，以及刚体参考质量矩阵和 inverse weights。`export-native-constants-host` 还迁移完整 set-constants 宿主顺序，底层物理 kernels/solve 仍是实际 SDK；新 CPU/Double 端口没有自动混入 GPU 路径。具体范围和 17 份本轮源码证据见 [进一步迁移清单](APIC_FINALIZE_SOLVER_MIGRATION.md)。完整 producer 仍不能记为无 Python。

同样，原 Python oracle 的作用是以后验证新实现。把它另写成 MoonBit/C++ 可以增加一个独立数学参考，却不能替代“原源码实际执行”的证据。

## 证据与未运行事项

`scripts/python_dependency_audit.mbtx` 只读取源码、记录 SHA、校验历史入口归档，输出 [机器可读清单](PYTHON_DEPENDENCIES.json)。其 marker 候选还包含显式 reference 分支、测试标签及被动源码引用，不能把文本命中数量当成解释器启动数量。实际分类以本页的调用链审查为准。

`scripts/finalize_python_migration.mbtx` 进行类型检查、接口生成、格式化和源码清单更新。测试、数值样例、RNG 抽样、训练、仿真、SDK 初始化、安装器执行和 APIC 导出都没有运行；CPU/Double 与原实现的数值及学习结果等价性仍等待复测。
