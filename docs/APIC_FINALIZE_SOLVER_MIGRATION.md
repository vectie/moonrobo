# Finalize、接触、分解与收敛的进一步迁移

本轮继续并行保留原实现，新增五个实际算法/存储包，以及独立的 set-constants 宿主流程入口。**完整 Newton 模型、全部碰撞/约束求解和原生四图 producer 仍未完成。** 下表区分已写出的计算或接口与完整运行链路；静态检查不证明数值等价。

来源为固定 Newton `71eeba16a717d4dcf0b9dd7056a7b6f863054dc3`、MuJoCo-Warp 官方 3.15.0 分发源码及 Warp 1.17.0。新增 [17 文件源码证据](APIC_FINALIZE_SOLVER_SOURCE_EVIDENCE.json)包含整文件 SHA、符号和一基行号，并关联上一轮 [23 文件证据](APIC_PHYSICS_SOURCE_EVIDENCE.json)。只读脚本 `scripts/audit_apic_finalize_sources.mbtx` 校验源码字节；不执行 Python、算法、编译器、测试或 SDK。

## 分层成果与明确缺口

| 层 | 新增实际实现 | 仍缺的能力 |
| --- | --- | --- |
| `producer_native/finalize` | 真实 f32/f64 typed model/state0/state1/control 字节、world/ancestor/articulation/target 布局、SHA 工件；独立 `upload` 通过 Warp C API 分配和上传 | shape/contact/constraint/particle 等完整存储、cooking、惯量推断、schema/solver namespace、完整 Newton `Model` 和状态 alias 契约 |
| `producer_native/narrowphase` | plane-sphere、sphere-sphere、sphere-capsule、plane-capsule、sphere-box、plane-box 六类基本接触；真实物性混合、frame、margin/gap、contact 写入、容量/拒绝计数；typed CUDA + NVRTC | capsule-capsule、box-box、GJK/EPA、mesh/hfield/SDF/flex 等未支持类型；完整 candidate 构建、全部接触闭包及已验证执行适配器 |
| `producer_native/factorization` | CPU/Double packed-tree sparse `LᵀDL` 和 UP/D/DOWN 回代；compact 标量与至多 6 维独立小块 Cholesky/回代；保留 seed/offset | 混合块/稀疏路径、tiled/gather、增广 Hessian/CG 等未覆盖分支；不将通用 dense solve 标成 sparse port |
| `producer_native/convergence` | CPU/Double pyramidal 一维动态线搜索、bracket/Newton/midpoint、piecewise 代价、noise floor、Newton/CG done/beta、overflow/niter/nsolving 转移 | 实际 Mv/Jv、梯度/Hessian、椭圆锥、GPU tile reduction、完整 solver iteration 与设备接线 |
| `producer_native/set_constants` | 真实刚体 qpos0 FK、COM/world inertia、祖先 Jacobian、动能质量矩阵加 authored armature、MoonNum LU、DOF/body inverse weights、子树复合惯量和 mean inertia | tendon/flex/mocap/kinematic locking 的参考模型支持；equality/camera/light/actuator 专项常量与设备状态/缓存恢复 |
| hybrid `constants_host` | 完整 `set_const_fixed` / `set_const_0` 宿主顺序、Newton physical-mean-inertia pre-pass、原生 typed copies；保留实际 SDK kernel 与 solve | 数值 kernel 和 factor/solve 仍由真实 SDK 提供；不是完整 Python-free set-constants 或原生物理后端 |

这些包分别提供受支持子集。编译一个新 narrowphase module 或得到一个 host mass matrix，不会自动替换 live SDK 路径。原 `export-native-io`、`export-native-schedule`、`export-native-physics-host` 的选择仍保留；没有错误后回退或静默混用 CPU/Double 与原 CUDA float32 的行为。

## 显式入口

`cmd/reference_apic_export` 新增以下命令，均为未来明确运行时才执行：

- `prepare-finalize CONFIG.json`：`{request:{builder_request,scalar_type,target_layout},output}`。写实际 host `.bin`/元数据，不初始化 GPU；独立库 API `upload` 才访问真实原生存储。
- `compile-narrowphase CONFIG.json`：配置遵循 [narrowphase](../src/learning_aligned/producer_native/narrowphase/README.md) 的 typed specialization；通过已有 NVRTC C API 编译实际生成源码。
- `prepare-factorization CONFIG.json`：`{request:{operation,parameters},output}`，操作为 `tree-factor`、`tree-factor-solve`、`small-block-factor`、`small-block-factor-solve`。
- `prepare-convergence CONFIG.json`：同样的 request/output 结构，操作为 `linesearch` 或 `convergence`。
- `prepare-set-constants CONFIG.json`：`{request:{models,qpos0,current_qpos,features},output}`，进行显式 CPU/Double 刚体参考计算。
- `export-native-constants-host CONFIG.json`：使用原 scheduled nested config `{config:原hybrid配置,dispatch_adapter}`。wrapper 新增 `--native-constants-host`；默认入口不变。

这些显式准备/编译命令记录输入、结果和 SHA，供之后成对复测。它们不是 APIC 四图物理工件。完整请求类型、数值布局及支持条件以各包 `.mbti` 和 README 为准。

## Set-constants 的实际流程

新的 hybrid 模式要求原固定 implicitfast/no-sleep/internal-contact profile，并额外校验实际导入的 `set_const.py` 整文件 SHA。它先按反向 body tree 计算 subtree mass，再执行 physical-mean-inertia pre-pass：保存 qpos、切到 qpos0、暂用 authored armature、实际 kinematics/COM/CRB 与可选 tendon armature、计算 physical statistic、恢复 locking 与 qpos。

随后迁移完整 `set_const_0` 宿主控制流：保存当前 qpos，写入 reference；执行 kinematics/COM/camlight/flex/tendon/CRB/armature/factor/transmission；计算 mean inertia、tendon/equality 常量；逐 DOF/body/tendon 求解并提取 inverse weights；更新 camera/light 参考和 actuator acceleration/dampratio；恢复 qpos 并重建 derived state。最后恢复 physical mean inertia，再保留原 solref/tendon/connect anchors 与 world geom/site 更新。

上述物理 stage、kernel、矩阵 solve 和 Python APIC registry 都仍调用真实 SDK。原生 copy 要求完整、同设备、同类型/shape 的分配；无法满足的布局明确失败。新宿主模式额外限制 `nv<=256`、`nbody<=4096`。完整 host 顺序不等于这些底层数值内核已经迁移。

## 验证状态

各包补充了待执行的科学/布局回归源码，并进行交叉源码审查。当前只运行 MoonBit 类型检查、接口生成、格式化和只读 SHA 审计。没有运行测试、数值样例、host 准备算法、GPU allocation/upload、CUDA/NVRTC 编译、SDK 初始化、图捕获、导出、回放或训练。

CPU/Double LU/Jacobi/串行累加、原 float32 tiled/atomic 路径及 f32 typed buffer 的数值和学习结果等价性均待机器空闲后复测。原 Python、producer 与旧 launcher 的保全 SHA 继续独立校验，不刷新基线来接受修改。

后续的 resolved shape/contact finalize、复杂几何原生接口、混合求解布局与多内核 GPU 接入，单列于 [模型与 GPU 链路的继续拆分](APIC_MODEL_GPU_MIGRATION.md)。本文描述的上一阶段接口仍保留；新的原生接口不会自动改变现有 hybrid 导出路径。
