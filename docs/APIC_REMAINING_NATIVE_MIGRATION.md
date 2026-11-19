# APIC 剩余原生迁移：实际程序与接口边界

**可继续拆成 MoonBit 编排、固定语义 kernel 生成及 C ABI 调用。完整物理程序仍需要迁移，不能用“已经连接 NVRTC/Warp”代替完成声明。** 本文区分源码可见的调用链和以后才能观测的实际 kernel 闭包。

本次审计没有导入或执行上游 Python，没有安装依赖、编译模型/kernel、初始化 SDK/GPU、生产 APIC 或运行测试。`effective_kernel_closure_observed=false`；数值及学习结果等价性仍待机器空闲后复测。

## 来源与口径

| 项目 | 固定身份 | 检查对象 |
| --- | --- | --- |
| IsaacLab | `46d6cc3d7b115906fad12efd372fbf69f4e3d3ed` | Newton manager、MJWarp manager 及实际默认配置 |
| Newton | `71eeba16a717d4dcf0b9dd7056a7b6f863054dc3` | `SolverMuJoCo` 的模型转换、step/reset、context 更新 |
| MuJoCo-Warp | PyPI `3.15.0` sdist，校验官方 SHA256 | forward、solver、collision、模型布局、set_const 与 specialization 工厂 |
| Warp | `v1.17.0` | Python AST/type specialization、CUDA 编译、原生 launch、APIC、scan/sort |

22 份直接源码和官方 sdist 的字节 SHA、符号及一基行号记录在 [APIC_REMAINING_SOURCE_EVIDENCE.json](APIC_REMAINING_SOURCE_EVIDENCE.json)。生成器为 `scripts/audit_apic_remaining_sources.mbtx`，只读取已下载的源码文本及计算哈希；符号定位是词法证据，**不是**执行 tracing 或自动证明的闭包。MuJoCo-Warp 使用官方 sdist 而非假定 Git tag/提交等价，未把包版本改写成未经验证的 Git SHA。原 producer 的独立 13 文件保全基线不受本审计更新影响。

## G1 已固定的条件与仍需观察的条件

第一方配置固定为：29 个命名关节、同一状态输入/输出、`num_substeps=4`、control dt `0.02`、solver dt `0.005`、decimation `1`、`update_data_interval=1`、`use_mujoco_cpu=false`、`use_mujoco_contacts=true`、`implicitfast`、pyramidal cone、`njmax=500`、每 world `nconmax=128`。IsaacLab 同 pin 的默认 solver 是 Newton，iterations `100`、linesearch `50`，不是从 NumPy 默认值猜测。来源：第一方 `producer_native/hybrid/sdk.mbt` 和 [固定 MJWarpSolverCfg](https://github.com/isaac-sim/IsaacLab/blob/46d6cc3d7b115906fad12efd372fbf69f4e3d3ed/source/isaaclab_newton/isaaclab_newton/physics/mjwarp_manager_cfg.py#L23)。

以下条件必须由真实构建的模型、实际 USD custom attributes 和运行配置决定，不能把通常情况当作已验证事实：

- `nq/nv/nbody/ngeom`、关节/geom/body 的实际排序、所有 world 映射、armature、actuator 配置以及 collision geometry 类型。
- Jacobian 稀疏布局。MuJoCo-Warp `io.is_sparse` 在 `AUTO` 且 `nv>32` 时选 sparse；29 关节加浮动基座通常使 `nv=35`，仍须检查实际描述，不能只做 dense solver。
- broadphase。`io.py:811` 使用过滤后 pair 数 `<250000` 选 NXN；否则按 `ngeom<1000` 分 SAP_TILE/SAP_SEGMENTED。是否需要 CUB 取决于这个实际分支，不能只看 batch 数判断。
- sleeping、speculative contacts、sensor/observable、tendon/flex/equality、callbacks、graph conditional 和 solver flag。不存在或关闭必须由实际字段约束，不能默默丢掉。

这三个布局判断直接来自 [3.15.0 官方分发源](https://pypi.org/pypi/mujoco-warp/3.15.0/json)的 `io.py:227,811`、`forward.py:2063`、`solver.py:3919`；分发包及各文件 SHA 已记录。

## 四类操作的实际调用链

| 操作 | 必须保持的程序顺序 | 可迁移的宿主层 | 仍需真实物理实现的部分 |
| --- | --- | --- | --- |
| step | masked target → scene write → stage body forces → pre/actuator/post 回调 → 4 个 solver substep → post-step 回调、sensor → Tier-1 publication | 固定 profile 的循环、参数选择、native copy/clear/launch、已知 mask/gather 算法 | `SolverMuJoCo.step` 中的坐标转换、actuation、MuJoCo-Warp forward/constraint/implicitfast、Newton FK |
| reset | masked root/joint/target 写入 → `reset(flags=0,world_mask)` → forward/FK → publication | mask 检查、确定索引映射、固定 buffer 操作 | solver warmstart/applied force/ctrl/act 清理、正确 reduced-coordinate FK 与字段转换 |
| context | 修改真实 friction/body COM base → `notify_model_changed(SHAPE_PROPERTIES | BODY_INERTIAL_PROPERTIES)` → forward → publication | native 物理字段写入、固定旗标调度 | geom/site/pair 更新、质量/主惯量更新、contact 常数、`set_const_fixed`/`set_const_0` 和 mean-inertia |
| refresh | manager forward/FK → publication，时间不推进 | 固定调度与 publication | 脏标记、world/articulation reset mask 消费、真实 FK |

IsaacLab 的 `_run_solver_substeps` 还规定：每个 substep 先恢复 staged body force，再运行 state-force callbacks，求解后 clear forces；single-state 不能错误加入双缓冲交换。sensor 更新可能调用 solver contact readback，不能因禁用了 contact sensor activation 就省略所有回调。这些语义见 [NewtonManager 的宿主调度](https://github.com/isaac-sim/IsaacLab/blob/46d6cc3d7b115906fad12efd372fbf69f4e3d3ed/source/isaaclab_newton/isaaclab_newton/physics/newton_manager.py#L1671)。

GPU substep 的明确主干是：`_apply_mjc_control` → `_update_mjc_data` → timestep fill → `mujoco_warp.step` → `_update_newton_state`。最后一步包含 Newton FK 及按需 observable。qpos/qvel 的双向转换使用 joint type、parent/child transform、body COM、dof reference 和 `mj_q_start/mj_qd_start`；不是给两个数组建立同名 alias。来源：[固定 SolverMuJoCo](https://github.com/newton-physics/newton/blob/71eeba16a717d4dcf0b9dd7056a7b6f863054dc3/newton/_src/solvers/mujoco/solver_mujoco.py#L4692)。

## MuJoCo-Warp 核心闭包

在本 profile 的 integrator 分支下，`step` 先 `forward` 再 `implicit`：

```text
forward
  fwd_position
    kinematics / COM / CRB / optional tendon
    collision broadphase + geometry-specific narrowphase
    constraint generation / transmission
  fwd_velocity / passive forces / RNE
  fwd_actuation
  fwd_acceleration + factorization
  solver.solve
    context initialization / warmstart / gradient + linesearch
    convergence iteration (capture_while or explicit fixed upper bound)
  requested sensor / post-constraint work
implicitfast
  derivative / factor_solve_i / advance
```

这是源代码主干，不是完整 kernel 名单。具体 kernel 由模型计数、contact 类型、sparse/tile/block 配置、flags、factory 参数和 `wp.static` specialization 决定。尤其不能用一个通用积分 kernel、固定 repeat 或 CPU `mj_step` 替代原 Newton 求解器并宣称等价；也不能仅因目标图叫 step/reset/context 就认定它包含了这些物理阶段。

context 另外需要模型常数闭包。Newton 在 `_set_const_0_with_physical_meaninertia` 保存 qpos、在 qpos0 重算物理 mass/inertia 统计、恢复 qpos、运行 `set_const_0` 并恢复物理 mean-inertia；单独覆写 COM 没有完成该操作。MuJoCo-Warp `set_const.py:595,616` 是对应实现入口。

## 可以直接连接的原生接口

| 能力 | 真正的上游原生入口 | 迁移含义 |
| --- | --- | --- |
| 编译已有 CUDA 源码 | NVRTC C API 或 Warp `wp_cuda_compile_program` | 替代编译调用；不自动生成物理源码 |
| 装载与调用 kernel | Warp `wp_cuda_load_module` / `wp_cuda_get_kernel` / `wp_cuda_launch_kernel` | MoonBit 可提供真实 ABI 参数与 `APICLaunchInfo`，不必调用 Python `wp.launch` |
| APIC 注册、snapshot、保存 | Warp `wp_apic_*` | 已有原生 writer；真实 operation stream、typed bases、kernel/module metadata 和 mesh relocation 仍需齐全 |
| SAP prefix scan | Warp `wp_array_scan_*_device` | 直接 C ABI 调用；Warp 内部使用 CUB，无需把 CUB 改写为 MoonBit |
| SAP segmented sort | Warp `wp_segmented_sort_pairs_{int,float}_device` | 保留 `2*count` 双 buffer、segment start/end、同设备与真实 allocation 归属 |
| USD/MJCF 数据 | OpenUSD C++ 包装成 C ABI；MuJoCo C API | 可以建设 portable scene/model IR；还需保留 USD→Newton→MuJoCo 语义映射 |

Warp native `warp.h:885` 定义真实 kernel launch；`APICLaunchInfo` 由宿主提供，但记录 hook 在原生 launch/memcpy/memset 中。scan/sort 的 Python 函数只是验证并调用 C ABI，其中 APIC array tracking 也必须迁移。证据：[Warp 原生头](https://github.com/NVIDIA/warp/blob/v1.17.0/warp/native/warp.h#L885)、[scan 包装](https://github.com/NVIDIA/warp/blob/v1.17.0/warp/_src/utils.py#L48)、[CUB scan](https://github.com/NVIDIA/warp/blob/v1.17.0/warp/native/scan.cu#L95)、[CUB segmented sort](https://github.com/NVIDIA/warp/blob/v1.17.0/warp/native/sort.cu#L518)。

## 本轮代码落点

| 代码层 | 实际迁移范围 | 不应扩大解释的部分 |
| --- | --- | --- |
| `producer_native/contracts` | typed numeric union、alias/span、mesh/scratch、四角色与来源/工件契约 | 纯元数据约束，不计算物理 |
| `producer_native/schedule` | 固定 profile 的 step/reset/context/refresh 宿主顺序；实际对象的 typed operands；缺少真实 backend 时拒绝生成成功结果 | 调度器不提供 MuJoCo-Warp solver 方程；solver 仍可由显式上游 SDK backend 实现 |
| `producer_native/kernels` | 11 个固定源函数的 13 个 typed key：masked root pose/COM velocity、joint velocity/state/target 排序、body publication、typed gather、target command 写入、implicit actuator batch、torque telemetry | 固定语义生成，不是通用 Warp AST 编译器；保留 batch actuation 的 PD+FF 总和限幅与 telemetry 的先限幅 PD 再加 FF 两种不同语义；不包含 collision/constraint/solver |
| native module/launch/APIC 接口 | 实际原生库装载、kernel 参数和 APIC metadata、copy/clear/snapshot/save | 接口完整并不代表物理 kernel 程序或调度闭包完整 |
| 原生 USD scene IR | 真实 USD physics 与扩展属性、clone/model 规划的数据层 | Newton/PhysX/MJC resolver 优先级和全部 builder 语义尚未完成，保持 `native_builder_ready=false` |
| `producer_native/builder` | portable body/joint/world/articulation 数组、默认 FK、canonical 映射及显式 mass/COM/inertia 计算 | 不代替 Newton finalize；缺失惯量不推断，USD resolver/cooking 仍有缺口 |
| `producer_native/physics_kernels` | 有明确 feature guard 的 sparse MVM/索引、CSR constraint-force 重建、NXN 候选生成 | 不包含完整接触 narrowphase、constraint generation、Hessian/factorization 或 solver 闭包 |
| `producer_native/constants` | CPU/Double 的 mapped body/geom/pair 参数、显式主惯量、subtree mass、已给定 CSR M 的 mean-inertia、qpos 参考数据 | 不装配 M、不计算完整 inverse weights/locking/eq/tendon 常数，不代表完整 `set_const_0` |
| 显式 physics-host 模式 | 固定 implicitfast/no-sleep/internal-contact 下 solver step、forward 和 context notify 宿主次序 | 核心数值阶段仍显式调用真实 SDK，继续依赖 CPython |

这些均是源码迁移范围，未运行 numerical kernel 或 SDK 验证；实际接线及支持条件以各包 README 和活动 CLI 为准。上游 Newton 的 USD 导入还涉及 DFS/关节排序、root rebasing、mesh approximation 与 schema resolver precedence，不能从“已读取 USD”推导“已构造等价 Newton model”。

## 迁移完成标准

MoonBit 可以逐个移走 manager 宿主循环、mask/坐标映射/状态 publication 等固定 kernel、已知模型语义生成，以及原生 module launch。固定源 pin 与算法适用前提要随每个 port 记录；如果要求输入或分支超出支持范围，应明确失败。

全量 G1 producer 脱离 Python 则还需要：同源 scene/model 构建、全部 effective physics kernel 的语义与 specialization、正确 native launch/conditional/copy/scan/sort schedule、完整捕获持久状态及 solver scratch 归属、四操作保存与加载。构建好接口或移走 manager 循环，只能计为对应层完成。实际 kernel 闭包、数值与物理等价性需要未来在匹配 SDK/GPU 上复测后才能确认。

当前原实现、原 launcher 及 13 文件 SHA 基线全部保留，参见 [上一层依赖审计](APIC_PRODUCER_PYTHON_DEPENDENCIES.md)。

进一步迁移的 typed finalize、primitive narrowphase、稀疏分解、线搜索/收敛和 reference/set-constants 宿主流程，见 [当前细分成果](APIC_FINALIZE_SOLVER_MIGRATION.md)。它们仍保持原生全物理闭包未完成、数值结果待复测的口径。

resolved shape/contact、复杂几何 C 接口、混合块/稀疏求解和 GPU 执行链路的后续端口，见 [模型与 GPU 链路](APIC_MODEL_GPU_MIGRATION.md)。独立原生 MuJoCo 碰撞与 Newton/MuJoCo-Warp 的完整 GPU 物理闭包分别记录，不能互相替代完成度。

多内核 JSON 执行入口保留末尾清零条件的零次/一次模式；进一步新增了真实设备收敛 producer 和多次 WHILE。后者要求末尾无条件更新同一 nsolving、初始 done/count 匹配且状态 owner 仅由该 producer 写入，不能凭任意 launch 清单宣称完整 `_solver_iteration` 已完成。原生 mesh cooking、有限 schema/equality、GJK、MathDx tile 与设备循环的当前范围见 [最新拆分](APIC_COOKING_DEVICE_MIGRATION.md)。

更细的 builder、collision/sparse、conditional、set-constants 拆分和源符号见 [物理原生分解](APIC_PHYSICS_NATIVE_DECOMPOSITION.md)；这些层的源码状态不能替代运行复测。
