# APIC 模型构建、复杂碰撞与 GPU 剩余边界

本轮继续补 Newton 形状/接触存储、MuJoCo-Warp 混合惯量分解、基本接触和原生 GPU 接线。**这些端口尚未组成完整 Newton 模型构建或完整 MuJoCo-Warp GPU 物理程序。** 原 Python producer、旧 CLI、launcher 和原始 SHA 基线继续保留；新的原生命令是显式并行入口。

这里必须区分三个结果：MoonBit 实现的 CPU/Double 数值端口、MoonBit 经 C ABI 调用的原生库能力，以及已经实现 CUDA 源生成器、尚未运行验证的 GPU 端口。静态检查通过不代表运行时、物理结果或学习结果等价。测试、数值示例、SDK/GPU 初始化、模型/核编译、碰撞执行和 APIC 导出仍未运行。

## 固定来源

[源码证据](APIC_MODEL_GPU_SOURCE_EVIDENCE.json)当前固定 36 个 primary source 文件，包含硬编码全文件 SHA、原始 URL、词法符号和一基行号。`scripts/audit_apic_model_gpu_sources.mbtx` 只使用 FS、文本和 SHA256；不启动子进程、不求值 Python、不加载 SDK/native library、不执行算法。其 `--verify` 不刷新报告，并校验官方 MuJoCo-Warp 分发包 SHA；原有 13 文件 producer 基线不参与更新。

| 上游 | 本轮固定版本 | 边界 |
| --- | --- | --- |
| IsaacLab | `46d6cc3d7b115906fad12efd372fbf69f4e3d3ed` | Manager 顺序、resolver 选择、state/control 映射 |
| Newton | `71eeba16a717d4dcf0b9dd7056a7b6f863054dc3` | builder/model/Contacts/shape flags 与几何枚举 |
| MuJoCo-Warp | 官方 PyPI `3.15.0` sdist | 本文所对照的 Warp 物理程序；archive SHA `e87442ab4594d8132b7cf6e38b32aaa6130467b654bee260616e5817041e7045` |
| Warp | `v1.17.0` | array ABI、tile Cholesky、CUDA graph/launch 和 APIC C API |
| MuJoCo C | **`3.3.7`，header `337`，Double** | 独立 MJB 原生碰撞入口；不归为 MuJoCo-Warp 3.15 算法迁移 |

MuJoCo 3.3.7 的官方 `mujoco.h`、`mjdata.h` 已与本机 native 编译头逐字节哈希核对一致。记录头文件和 C 源并不证明任意动态库的 ABI；实际入口仍必须核验 `mj_version()` 和数值宽度。旧证据链见[上一轮 finalize/solver 证据](APIC_FINALIZE_SOLVER_SOURCE_EVIDENCE.json)。

## Newton 构建：数值数组、形状与接触存储

已有 builder/finalize 端口构造真实刚体树、world/joint/body 索引、默认 FK、typed model/state/control 数组和可选质量/惯量；缺失物理属性仍保持“不完整”，不填单位惯量来冒充可用模型。本轮继续处理已经解析的 primitive shape 参数、形状数组和接触存储。

固定源 [`ModelBuilder._finalize_impl`](https://github.com/newton-physics/newton/blob/71eeba16a717d4dcf0b9dd7056a7b6f863054dc3/newton/_src/sim/builder.py#L13680) 的完整任务还包括 shape source/cooking、碰撞过滤打包、mesh/support 数据、SDF 资源、惯量校正、各类约束与扩展 namespace。原生数组上传只完成存储，不能据此宣布构建了同一个 Newton `Model`，也不能跳过 `SolverMuJoCo._convert_to_mjc` 的 actuator/geom/equality/option 转换。

| 当前可单独移植的部分 | 必须保留的语义 | 仍缺的完整构建环节 |
| --- | --- | --- |
| 已解析 primitive shapes | Newton `GeoType` 与 MuJoCo `GeomType` 不共用数值；Z 轴、半尺寸、capsule 长度和 cylinder barrel 参数按各自定义处理 | USD 原始属性到 schema precedence 的完整解析、mesh approximation/cooking、heightfield/SDF owner |
| shape pair 过滤 | world/global、collision group、same-body/static、显式过滤 pairs 的源分支与 packed i64 不能经 Double 舍入 | 上游完整 fast paths、全部自定义 resolver、全场景语义与过滤规则联动 |
| `Contacts` 刚体存储 | `contact_counters[3]` 的 rigid、soft、overflow 是同一 Buffer 的三个真实 views，不能独立分配三个计数器 | soft/flex/gradient/custom contact 属性与所有碰撞后端的完整 owner/更新契约 |
| state/control/device storage | world-start/global-tail sentinel、两份独立 state 与可选 single-state alias、所有 graph 使用期间 owner 存活 | Newton 扩展 namespace、完整 contacts/constraints/workspace 构建和 solver 兼容性 |

[`Contacts.__init__`](https://github.com/newton-physics/newton/blob/71eeba16a717d4dcf0b9dd7056a7b6f863054dc3/newton/_src/sim/contacts.py#L163) 的刚体计数是 `contact_counters[0:1]`，soft 是 `[1:2]`，reduction overflow 是 `[2:3]`。APIC region/relocation、typed-view alias 校验和释放顺序都必须识别这种合法 alias；不能为方便通用“不重叠”校验而改变上游存储含义。

`parse_usd` 在固定源中不仅遍历 prim，还解析质量/密度/COM/惯量覆盖、collider 聚合、mesh approximation，以及 fixed-joint collapse 后的 body/shape/joint 映射。后续可逐层迁移，也可以连接合适的原生库；当前 primitive shape 数组不能宣称补齐这些缺口。

## 惯量分解：mixed、gather 与实际 GPU tile

MuJoCo-Warp [`io.m_block_layout`](https://pypi.org/project/mujoco-warp/3.15.0/) 按真实 `tree_dofadr/tree_dofnum` 的连续独立惯量块选择算法，不按“稀疏模型”一个开关决定全部布局。

| 真实分支 | 存储及算法 | 端口应保留的关键细节 |
| --- | --- | --- |
| `size <= 6` 且 compact | `qLD_block_adr=-2`，无 dense factor 分配，D 为倒数对角 | compact 是该块的实际 CSR nnz 等于 size，不仅是某个 free-joint 名称 |
| `size <= 6` 且 full triangular | dense prefix 中的 row-major upper scalar Cholesky | 只写 upper/diagonal，未用 lower seed 按原逻辑保留 |
| `size <= 64` 的其余块 | gather 实际 CSR slot 后 upper Cholesky | **小于等于 6 但非 compact/full 的块也走 gather**；缺失 pair 的 gather slot 是 `nC`，读取结果为零 |
| 更大块 | `qLD_block_adr=-1` 的 packed ancestor LDL | 保留真实父链/row prefix、depth 分组、组间 barrier 与同 target 多个 atomic contribution |

`qLD_block_total` 是 dense factor prefix 的长度。只要存在 sparse 路径，后面跟的是**完整 nC** 的 LDL tail，而不是仅挑 sparse 行拼成的新 CSR。`_factor_i_sparse` 将整个 M 复制到 tail，再对 sparse updates 分组反向更新；`_qLDiag_div` 随后覆盖所有 DOF 的 D，包含 compact/scalar/gather 块所在 DOF。求解时 full factor 使用 U，compact 使用 D，sparse 使用对应 tail 与 D。这些看似多余的写入也是固定源行为。

当前 mixed 因子化端口是 CPU/Double 对上述数值与布局语义的直接实现。gather upper factor 的 lower 清零参考 Warp [`scalar_cholesky_impl<Upper>`](https://github.com/NVIDIA/warp/blob/v1.17.0/warp/native/tile_cholesky.h#L83)；它与 scalar 小块保留 unused lower seed 的行为不同。即使公式一致，也没有执行 Warp tile、MathDx、GPU reduction 或证明它们的 float32 舍入次序一致。

惯量 M 的 mixed Cholesky/LDL 不等于 constraint Hessian 的 blocked/augmented Cholesky。`block_cholesky.py` 的 Schur block 更新、增广 RHS border、padding、Newton decrement 与实际 device tile 调度仍需各自实现。不得用整个 M 的任意 dense solve 替代原 mixed storage，再声称完成同一个 GPU 求解器。

## 碰撞：新增 primitive 与独立 MuJoCo C 替代层

MuJoCo-Warp primitive 路线在既有六类接触之外继续迁移 capsule-capsule：实际非平行最近段计算、平行四端点顺序、margin 接纳和最多两个槽位；未填槽的 infinity/zero 数据及 sensor pair 行为需要按原 wrapper 保留。物性混合、gap/margin、类型排序、contact counter 与 EFC slots 仍属于同一个写入契约。仅有几何距离函数不能替代完整 contact 写入。

所有 GPU candidate/output views 均要求实际 owned Buffer 的 dtype/rank/shape/stride/byteextent；不能根据 request 中的容量猜测指针合法。原生 entry 的 descriptor gate 放在索引前；host `validate_bindings` 另外验证 backing allocation、输出内部重叠和跨视图写重叠。contact overflow 增 rejection 计数并停止越界写，保留源 atomic count；contacts 发布前必须同时满足 rejection counters 为零和 count 不超过容量。上游 `contype/conaffinity`、parent/exclude 和 authored pair 选择仍是 candidate 输入前置。

**新增 MuJoCo C 复杂碰撞是独立 CPU/Double 替代层，不是 MuJoCo-Warp GPU 碰撞算法已经迁完。** 它消费真实 MJB，经 MuJoCo 3.3.7 的 `mj_loadModel/mj_makeData` 和 `mj_kinematics → mj_comPos → mj_collision` 调用原生库。库自身处理它所支持的复杂几何；MoonBit 持有 model/data 生命周期并读取真实 native contact。它不调用 `mj_step`，也不根据 Newton prepared arrays 自动构建等价 MJB。

| 层 | 已有/本轮可提供 | 仍未迁移或不能推导 |
| --- | --- | --- |
| MuJoCo C 原生碰撞 | MJB model/data、显式配置输入、真实 CPU complex geometry/contact | Newton→MjSpec/MJB 语义转换；MuJoCo-Warp 3.15 的 GPU 程序/浮点路径；Isaac sensor/publication 对齐 |
| Warp convex | 固定源与依赖已梳理 | GJK support/simplex/退化、EPA polytope/witness/容量与 overflow、multicontact clipping、CCD specialization 全闭包 |
| Warp mesh/hfield | 原生库可提供自己的 CPU 能力 | Warp topology/graph/support owner、hfield filter、批量 dataid、模型专用 scratch 与实际 GPU dispatch |
| Warp SDF/flex | 固定源码已记录 | volume/plugin sampling、gradient-descent 条件、flex SAP/sort/FPS/多阶段过滤与 contact reduction |

MuJoCo 3.3.7 `mjContact` 使用单个 `efc_address`、`exclude` 和 native `geom/flex/elem/vert` 字段；其 `includemargin` 注释为 **margin-gap**。这与 MuJoCo-Warp 3.15 的 contact arrays、多个 EFC slots、adhesion 和 constraint/sensor flags 不同。不得通过字段改名就宣称数组可以互换；receipt 应保留版本与来源，并为未作映射的字段明确留出边界。

固定源的复杂 Warp 路线见 `collision_convex.ccd_kernel_builder/ccd_hfield_kernel_builder`、`collision_gjk.gjk_phase/epa_phase/multicontact`、`collision_sdf.sdf_narrowphase` 和 `collision_flex.flex_collision`。即使可调用 MuJoCo C 碰撞，以上源码的 Python codegen/dispatch 依赖仍然存在于原 GPU producer 路径。

## GPU 接线与完整 physics program

原生 C ABI 的 allocate/copy/typed kernel launch、NVRTC、CUDA graph/conditional、APIC register/save 已能复用。它们连接真正的 CUDA/原生库；主机侧组织代码由 MoonBit 实现。它们不会从任意 Python `@wp.kernel` 自动生成等价 CUDA，也不会凭 kernel key 或 bytes receipt 自动补齐缺失的物理程序。

新增 `gpu_pipeline` 入口消费三类已编译的真实工件：G1 typed kernels、MJWarp `physics_kernels` 和 primitive narrowphase。它重算相应 lowerer 并校验 manifest/source/image/specialization SHA，执行显式 typed launch、copy/zero 和真正的 CUDA conditional API；该入口本身不调用 NVRTC，也不自主生成缺失的物理程序。finalize host artifact 和显式 factorization host seed 可以作为实际输入，但 host seed adapter 不等于 GPU factorization。narrowphase 限定为唯一顶层终端调用，真正执行后读取 rejection/contact counters 再通过发布 gate；只录图而未执行不能声称接触有效。初始化快照在 begin 前取得，owned buffers/modules/graph 保持至 save/close。这里描述的是显式 API 行为，未在本轮执行该入口。

本阶段 JSON pipeline 的 WHILE 仅接受 body 最后无条件 zero condition，实际只执行 0 或 1 次。后续已新增真实 device convergence producer，允许满足初始 done/count 一致性和唯一状态 writer 的多次设备 WHILE；旧 final-zero 模式保留。具体设备端计算、归约差异及完整 solver 仍缺的阶段见 [cooking/schema、MathDx 与设备循环的继续迁移](APIC_COOKING_DEVICE_MIGRATION.md)。

完整 G1 producer 仍需要同一真实模型上的 collision → constraint/Jacobian → smooth dynamics/inertia → gradient/Hessian/search → dynamic linesearch/convergence → implicit integrator → state/control/publication，并保留 warmstart、done/state-changed、sleep/enable/disable、sensor、callbacks 与 overflow。CPU 片段、用户提供的 GPU launch 清单、独立 C 碰撞和现有 hybrid 调度不能自动组成这一闭包。

所有 native graph/capture 必须保持相同 CUDA context/stream、真实模块/源/ABI metadata 和 Buffer owners；分支构造失败的 parent graph 必须丢弃。四角色 capture 的初始化快照、numeric union、mesh relocation、module image 与 APIC companion 目录仍需整体符合下游 writer 契约。当前新增 primitive/mixed/model 工件没有经过这条全链路运行验证。

## 本轮复核和后续复测

本轮已只读交叉审查 mixed 分解、native 碰撞，以及 GPU 配置/模块/缓冲区/索引验证/显式 program，未发现剩余确定阻断。GPU 初始 counter 为零的证明曾可被前序 copy/其他 kernel 改写破坏，现已增加全程序 owner 写保护：只允许其唯一 producer 和对齐 zero 写；readonly 索引也在全部分支中冻结。Warp scalar 与 MathDx upper tile 路径都会清 opposite triangle，和 scalar 小块保留 seed lower 的区别已核实。这些是源码结论，不代表物理等价。新源码证据可用纯元数据命令验证：

```text
moon run --target native --warn-list -a --target-dir _build/script-check scripts/audit_apic_model_gpu_sources.mbtx . /tmp --verify
```

此命令只读缓存源码和既有证据、校验 SHA/符号并比较 JSON，不运行 producer、数值算法或测试。后续机器空闲后仍需验证原实现与新实现的模型数组、contacts、factor/search/done 状态、APIC replay、轨迹和学习结果；现在不为其填写通过结论。

## 显式 CLI 与配置

入口是 `cmd/reference_apic_export`，子命令均接受一个 `CONFIG.json` 路径。下面仅说明接口，本轮未运行这些命令；原默认 `export` 仍保持旧 reference 语义。

| 子命令 | JSON 顶层及实际调用 | 字段定义 |
| --- | --- | --- |
| `prepare-collision-finalize` | `{request: CollisionRequest, output: String}` → `finalize.collision_artifact` | [`CollisionRequest` 源码](../src/learning_aligned/producer_native/finalize/collision_types.mbt)、[finalize 接口](../src/learning_aligned/producer_native/finalize/pkg.generated.mbti)；request 含 `base/shapes/filters/candidate_limit/contacts` |
| `collide-native` | 原样解码六字段 `collision_native.Config` → `collision_native.run` | [原生碰撞接口](../src/learning_aligned/producer_native/narrowphase/collision_native/pkg.generated.mbti) |
| `prepare-factorization` | `{request: {operation, parameters}, output: String}` → `factorization.execute`；新增 operation 为 `mixed-factor` / `mixed-factor-solve` | [factorization 说明](../src/learning_aligned/producer_native/factorization/README.md)、[接口](../src/learning_aligned/producer_native/factorization/pkg.generated.mbti)；`MixedRequest.layout` 必须提供真实 `tree_dofadr/tree_dofnum`，solve 另需真实 RHS |
| `run-gpu-pipeline` | `gpu_pipeline.decode_config(Config)` → `gpu_pipeline.execute`，没有隐式 fallback | [GPU package 说明](../src/learning_aligned/producer_native/gpu_pipeline/README.md)、[生成接口](../src/learning_aligned/producer_native/gpu_pipeline/pkg.generated.mbti)、[完整 Config 与 program 类型](../src/learning_aligned/producer_native/gpu_pipeline/types.mbt)；顶层含 `dispatch_plugin/writer_plugin/warp_library/device_ordinal/architecture/modules/buffers/host_imports/program/mode/launch_captured_graph/output` |

`collide-native` 的六字段配置形状如下。路径、容量和 qpos 都必须替换成实际输入；`qpos: []` 仅适用于真实 `nq=0` 的 MJB，存在 free/ball joint 时必须使用模型顺序的单位 wxyz quaternion。以下没有被执行：

```json
{
  "adapter": "/native/libmoonrobo_collision_native.so",
  "mujoco_library": "/native/libmujoco.so.3.3.7",
  "mjb": "/models/precompiled.mjb",
  "qpos": [],
  "contact_capacity": 800,
  "output": "/output/fresh-native-collision"
}
```

`prepare-collision-finalize` 的 `base` 沿用已有刚体 `CommandRequest`，shape/material/filter 必须已经按 Newton 语义解析；它不读取任意 USD 原始属性推断缺失参数。`run-gpu-pipeline` 的 module/image/initial buffers 需要真实 SHA 固定，program 必须显式提供受支持的操作；纯 copy/zero 图也不能据此宣称物理程序已迁移。record-only capture 的 `narrowphase_postexecution_gate_passed` 为 false，不声明接触结果有效。类型级 API 还接受 `initial_buffers`，可由纯 host adapters 提供；CLI 直接解码 Config。具体模式和所有字段以对应包 README/生成接口为准。
