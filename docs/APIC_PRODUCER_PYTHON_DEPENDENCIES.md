# APIC 离线 producer 的 Python 边界

这次继续沿用 **MoonBit → C ABI → 上游原生库** 的方式拆分。新增原生模型描述、OpenUSD 检查、Warp APIC 写入和 NVRTC 编译接口；完整 G1 场景构造及上游物理 kernel 捕获仍需要嵌入式 CPython。生产回放与离线生产工件是两个独立依赖范围。

当前只做源码迁移、类型检查和原生源码语法检查。**未执行测试、Python、SDK 初始化、模型编译、CUDA/NVRTC 编译、APIC 导出或物理回放，尚无数值及学习结果等价性结论。**

## 依赖分类

| 阶段 | 原实现调用 | 本次原生对应能力 | 仍有的边界 |
| --- | --- | --- | --- |
| 配置、文件身份与元数据 | MoonBit 读 JSON、SHA256、实际 Git HEAD/dirty 检查；部分 SDK 身份由 Python 查询 | `producer_native/contracts` 处理 region、view、capture 和 inventory 数据契约；文件及来源身份继续用 MoonBit | 需要调用 Python SDK 时，仍校验实际导入对象 `__file__` 和版本，不能用目录名代替 |
| USD 预检查 | `pxr.Usd.Stage.Open`、default prim、variant set/name 检查 | `producer_native/model` 经 C ABI 连接 OpenUSD C++；检查真实 stage、variant、依赖与元数据 | 原生检查不等于复现 IsaacLab 的 USD spawner、Newton model builder 或 GPU solver |
| MJCF 模型描述 | IsaacLab/Newton 构造物理模型 | `producer_native/model` 经 C ABI 调用真实 MuJoCo，输出模型描述及 MJB | MJB/`mjModel` 不是 Newton 的已构建 GPU model；不能把这一步标成完整 G1 APIC 生产 |
| APIC 注册与保存 | `warp.capture_save` 及 Python capture 的 region/module/kernel/mesh 元数据 | `producer_native/warp` 经 C ABI 调用固定版本 Warp 原生 APIC 注册、snapshot、mesh 和保存接口 | 原生 serializer 消费真实 capture 的状态与元数据；不会自动生成 Newton solver kernel/dispatch |
| CUDA 模块编译 | Warp 的 Python specialization/codegen 与编译装载链 | `producer_native/compiler` 动态连接 NVRTC C API，编译**已经生成的** CUDA C++ 源码 | 仍缺 Warp Python AST/type specialization 到 CUDA 源码、完整 Newton kernel 及 solver dispatch 的原生生成链 |
| 固定 G1 场景配置与数据 | 实际 USD schema + 第一方机器人/solver 配置 | `producer_native/scene` 读取真实原生 physics IR，产生 canonical 29 关节 recipe，并接入 scheduled hybrid | Newton schema resolver、clone/world 分组、mesh cooking、inertia 推断及 device finalization 仍未迁完；`native_builder_ready=false` |
| 固定 kernel 特化 | mask、actuation、状态重排/发布等 Warp 函数 | `producer_native/kernels` 生成 13 个 typed key、覆盖 11 个真实源函数，校验源 SHA，接 NVRTC | 不是通用 Python AST 编译器，不包含完整物理求解闭包；实际 CUDA 编译仍未运行 |
| Manager 宿主调度 | `_simulate_full` / `forward` 的循环及 force/mask 操作 | `schedule` + hybrid `export-native-schedule` 保留实际 callbacks/adapter/sensors/solver/FK；copy/zero 走 `dispatch` C ABI | 调度次序迁移不等于 solver 方程迁移；SDK publication 和 APIC typed registry 仍是实际 Python 对象 |
| 独立单 kernel 捕获 | Python launch/capture 入口 | `producer_native/capture` 以 owned buffers、真实 Warp C launch/APIC save 实现，无 CPython | 产物是独立单 kernel 格式，没有四图及完整 scene/physics/context 闭包，不能用于冒充完整 aligned bundle |
| 受限 Newton builder | 上游拓扑、clone、默认状态和 inertia 处理 | `producer_native/builder` 实际计算 directed tree、world/canonical 索引、初始 FK、关节数组及显式惯量 | 无完整 schema precedence、shape cooking、质量推断、fixed collapse、Newton→MuJoCo 转换或 device finalize |
| 碰撞/稀疏子运算 | MuJoCo-Warp support/solver/collision_driver | `physics_kernels` 提供稀疏 MVM、CSR force 清零/重建、受限 NXN broadphase；`mass_gather_layout` 计算真实 packed-M gather 映射 | 不是完整 narrowphase、constraint、Hessian/factor/linesearch/convergence；新 module 格式不被旧单 G1 kernel runner 自动接受 |
| 原生条件控制流与 CUB | Warp CUDA graph / scan / segmented sort | `dispatch` 连接真实 C ABI，保留 typed owner、不可变已校验 partition、APIC 分支和失败废弃契约 | 条件节点不实现 solver iteration；动态 device partition 仍需另外支持，不能把 arbitrary GPU 值当合法边界 |
| 模型常量片段 | inertia、pair/geom、subtree、qpos0/mean inertia | `constants` 实际计算 CPU/Double 公式，复用 MoonNum；host qpos 仅作真实数据复制 | 完整 mass assembly、inverse weights、solref/tendon/equality/camera/light/actuator 与缓存恢复仍依赖真实后端 |
| Physics 宿主流程 | SolverMuJoCo.step、MJWarp.forward/step、固定 flags notify | `export-native-physics-host` 将精确受限 profile 的 host 顺序移到 MoonBit，保留 scope、callbacks、RNE、物理常量恢复 | 真实 physics stage、kernel/codegen、FK、SDK metadata 仍走上游；继续 `uses_cpython=true` |
| G1 物理场景和四类操作捕获 | IsaacLab/Newton/Warp 的 Python 对象和方法 | `producer_native/hybrid` 复用真实上游 scene/solver，接入可替换的原生阶段 | 仍依赖 CPython、上游 SDK 以及其传递依赖；此路径应明确称为 hybrid |
| 生产环境 APIC 回放 | 原生 Warp/CUDA 加载已保存工件 | 现有 `learning_aligned/gpu_native` | 回放本身不链接离线 producer 或 CPython；工件仍需在匹配 SDK/GPU 上实际生产和验证 |

OpenUSD 和部分 SDK 提供 C++ 接口，仓库用小型 C++ 包装导出稳定 C ABI，再由 MoonBit `extern "c"` 连接；MuJoCo、Warp 和 NVRTC 的原生入口也通过 C ABI。新模型、Warp writer 的 CMake 没有 Python 查找或链接步骤。原有 `producer/native/CMakeLists.txt` 中 CPython 3.12 `Development.Embed` 则继续用于保留的参考实现及 hybrid SDK 对象桥。

## 原 producer 实际用了哪些 Python 能力

原实现源码位于 `src/learning_aligned/producer`，其中第一方编排已经是 MoonBit；`native/python_objects.cpp` 负责引用计数、GIL、导入、属性和方法调用，没有新增 `.py` 算法、Python 子进程或源字符串 `exec`。

直接模块与用途如下：

| 模块 | 实际用途 | 迁移判断 |
| --- | --- | --- |
| `builtins`、`json` | 构造 list/tuple/slice/dict、序列化普通数据、通过 `type` 与上游 `configclass` 创建配置类 | 新的纯原生阶段不需要；hybrid 与 Python 对象交互时仍需要对象桥，不能只替换 JSON 就消除解释器 |
| `importlib.metadata`、`isaaclab`、`isaaclab_newton`、`newton` | `mujoco-warp` 分发版本、模块 `__file__` 及真正导入的 SDK 来源 | 原生阶段可独立读元数据；仍运行 Python SDK 的部分必须验证实际被导入的对象 |
| `pxr.Usd` | stage/default prim、请求 variant 的真实存在性 | 新增直接 OpenUSD C ABI 代替这一独立预检查 |
| `isaaclab.app`、`isaaclab.sim`、`isaaclab.assets`、`isaaclab.actuators`、`isaaclab.scene`、`isaaclab.utils`、`isaaclab_newton.physics` | kit-less headless launch、真实 articulation/actuator/scene、Newton/MuJoCo-Warp manager | 仍是完整 producer 的主要 Python 边界；不是一组可直接重命名的 C 函数 |
| `warp`、`warp._src.types` | GPU typed arrays、所有权、shape/stride、primitive dtype 以及 capture begin/end | 已增加原生 APIC writer；SDK 数组和类型的取得、真实 kernel 生成/调度仍由现有 SDK 提供 |
| `warp._src.context` 与 Python capture 元数据 | APIC 状态、typed region registry、module/kernel、mesh ID、官方保存流程 | hybrid 可把已取得的真实状态交给原生 writer；必须保留句柄生命周期和 pointer relocation |

`mujoco`、`mujoco_warp`、`numpy`、`sys` 出现在桥接模块允许列表，但允许导入不代表第一方源码直接调用。NumPy 也会被原实现 `Warp array.numpy().tolist()` 间接使用；`scene.env_origins` 来自 Torch tensor，原 host 读取使用 `detach().cpu().tolist()`。这些是 **producer 的实际传递依赖**，不能因为没有 `import torch` 就写成无 Torch，也不能把 Python wheel 中原生库的路径本身算作解释器依赖。

原 producer 捕获的 `step`、`reset`、`context`、`refresh` 继续要求真实 upstream 操作；禁止以空 graph、CPU 近似模型或伪造 `.wrp` 替代。numeric union 不能包含未知指针/opaque handle；mesh 需要官方序列化与 relocation。原生 serializer 和 NVRTC 接口都不单独证明这条闭环已经完成。

## 原实现与来源保全

`APIC_PRODUCER_BASELINE.json` 记录迁移前工作区的 **13 个文件**：原 producer 的 9 个文件、旧 CLI 的 3 个文件及旧 launcher。它描述原始源码字节，不表示干净 Git 提交或已执行的二进制基线。

- 原 producer 的 9 个文件继续留在原路径，并保持原 SHA256。
- 旧 CLI 的 `main.mbt`、`moon.pkg` 保存在 `cmd/reference_apic_export_legacy`；旧接口字节保存为该目录的 `original.pkg.generated.mbti`，避免被 `moon info` 更新覆盖。
- 旧 launcher 保存在 `scripts/python_reference/export_g1_aligned_apic.mbtx`，其 SHA256 也登记在 `apic-producer-sources.json`。旧正文仍调用 `cmd/reference_apic_export -- export`；活动 CLI 保留 `export` 为原实现语义（等同 `export-reference`），因此归档不会误入新后端。
- 全部 13 份原始字节另存于 `docs/migration-baselines/apic-producer/original/`，后缀统一为 `.source`，避免 `moon.pkg` 或脚本被工具意外识别为活动包或入口。
- `scripts/capture_apic_producer_baseline.mbtx` 只消费既有基线，校验原目录/迁移位置和 `.source` 副本；`--preserve` 只创建缺失的完全相同副本，拒绝覆盖已有副本。它不提供刷新 SHA 来接受修改的功能。

只读 SHA 校验命令（不会调用 SDK 或生成物理工件）：

```text
moon run --target native scripts/capture_apic_producer_baseline.mbtx . --verify docs/APIC_PRODUCER_BASELINE.json
```

入口现在显式区分：`export` / `export-reference` 使用原 producer，`export-native-io` 使用接入原生阶段的 hybrid producer；活动 `scripts/export_g1_aligned_apic.mbtx` 默认选择后者。没有遇到错误后悄悄回落到 Python 的行为。由于原 producer 的 README 也被原样保留，其中展示的是历史命令；新配置以活动 CLI 和 `producer_native` 的接口说明为准，原 README 不会为了描述新实现而被改写。

新增显式命令为 `prepare-scene`、`compile-kernels`、`capture-kernel` 和 `export-native-schedule`；wrapper 的 `--native-schedule` 选择最后一个命令，配置是 `{config: 原 hybrid 配置, dispatch_adapter: 原生 dispatch 插件路径}`。这些命令本轮均未运行。原 `export-native-io` 仍走实际 SDK manager 方法，未被悄悄替换为新调度。

进一步新增 `prepare-builder`、`prepare-constants`、`prepare-mass-layout`、`compile-physics-kernels` 与 `export-native-physics-host`。wrapper 的 `--native-physics-host` 使用同一 nested scheduled config；普通 `--native-schedule` 保留此前调用真实 solver.step/notify 的语义。新模式要求实际 implicitfast、internal contacts、update interval 1、无 sleeping/speculative，并校验实际 imported Newton/MJWarp 源码 SHA。具体请求结构见 [native producer](../src/learning_aligned/producer_native/README.md)；细分缺口见 [物理程序拆分](APIC_PHYSICS_NATIVE_DECOMPOSITION.md)。所有新计算、编译、捕获入口仍未执行。

后续又增加 `prepare-finalize`、`compile-narrowphase`、`prepare-factorization`、`prepare-convergence`、`prepare-set-constants` 和 `export-native-constants-host`。独立算法/存储端口不依赖解释器；host 导出模式继续使用真实 SDK 的物理 kernel、factor/solve 和 Python APIC registry。它迁移的是完整 reference-constant 宿主顺序，并明确保留 `uses_cpython=true`。请求、能力及未完成的完整模型/接触/求解闭包见 [进一步迁移](APIC_FINALIZE_SOLVER_MIGRATION.md)；默认和原参考模式未被静默改成新后端。

原生 APIC 加载从 recording 读取 entry/shared-memory 元数据并直接装载实际 image，不要求 Python cache 的 `.meta`；新保存器仅在真实 companion 存在时一并保全。APIC-only 捕获会执行内核，单 kernel runner 在 begin 前保存初始 buffer 快照，避免把 post-state 错当 initial state。完整调用链和直接源码证据见 [剩余迁移梳理](APIC_REMAINING_NATIVE_MIGRATION.md)。

## 留待机器空闲后验证

继续新增 `prepare-mesh`、`cook-host-mesh`、`prepare-schema`、`prepare-equalities`、`compile-convex-gjk`、`compile-mathdx-tile`、`compile-device-convergence`。原生 GPU runner 已接入 GJK、MathDx 和真实设备收敛多次 WHILE，各自结果门槛独立校验。上述执行/编译入口本轮均未运行；host Mesh ID 不可当 GPU mesh，GJK witness 不可当完整 contact stream，tile 不等于完整 mixed solver。详见 [当前拆分与证据](APIC_COOKING_DEVICE_MIGRATION.md)。

本轮再增加 `prepare-collision-finalize`、`collide-native`、`run-gpu-pipeline`，并通过既有 `prepare-factorization` 暴露混合块/稀疏分解操作。它们是独立、显式的原生入口，未改变原 `export` 或 hybrid 路由；具体算法、版本、工件和不支持的闭包见 [模型与 GPU 链路](APIC_MODEL_GPU_MIGRATION.md)。其中 MuJoCo CPU 碰撞读取已有 MJB，不能等同于 Newton 或 MuJoCo-Warp GPU 接触等价。

当前保留 `runtime_validated=false`。后续需在匹配版本的 SDK/GPU 上实际验证 OpenUSD 选择和依赖、MuJoCo 描述一致性、真实 kernel/module 闭包、四种操作的 capture/save/load、跨图持久状态同步、masked reset 隔离与物理差分。新 CPU/Double 训练后端的数值及学习结果等价性仍单独等待复测。
