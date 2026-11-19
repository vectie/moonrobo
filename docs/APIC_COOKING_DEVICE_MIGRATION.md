# APIC cooking、schema、凸体与 device solver 迁移边界

后续状态见 [完整 cooking、接触与求解翻译](APIC_FULL_NATIVE_TRANSLATION.md)：已新增完整 EPA/manifold、plane/heightfield、mixed sparse/LU、Newton/CG 与 compact/incremental 实现。以下保留本阶段历史快照及其证据，不刷新旧 SHA 或把未执行项目记为通过。

本轮继续保留 Python producer、原 CLI 与所有历史源码基线，并行补上 MoonBit 与真实原生接口。新增代码已有可调用实现；**本轮没有运行测试、数值算法、native cooking、SDK、GPU、NVRTC/MathDx 编译或 APIC 导出**。静态检查与源码审查不能证明运行成功或数值等价。

全仓 Python 身份检查另发现本轮编辑范围外的训练文件变化与新增文件，且工作区在校验期间继续变化；旧基线未刷新，当前文件未回退。详见[保全校验记录](PYTHON_SOURCE_PRESERVATION_STATUS.md)，最新差异路径保存在 native inventory 的 diagnostics 中。因此不能将本轮原 producer 的保留表述成所有历史 Python 字节均已验证不变。

这份报告记录本轮增量；[上一轮 model/GPU 报告](APIC_MODEL_GPU_MIGRATION.md)描述上一阶段，其 36-source evidence 的原始字节保持不变。旧报告已链接本轮变化：JSON WHILE 零/一次限制属于此前快照；本轮增加真实 device convergence producer 后，符合下文证明条件的多次 WHILE 已有实现，尚未执行。

## 固定源码与审计口径

[本轮 evidence](APIC_COOKING_DEVICE_SOURCE_EVIDENCE.json)记录 **32 个固定 primary 源文件**的 SHA256、字节数、官方 URL、词法符号及一基行号。Newton 固定为 `71eeba16a717d4dcf0b9dd7056a7b6f863054dc3`，Warp 固定为 `v1.17.0`，MuJoCo-Warp 固定为官方 PyPI `3.15.0` sdist。源码只作为文本读取，从未 import 或执行。

[metadata 审计脚本](../scripts/audit_apic_cooking_device_sources.mbtx)仅使用文件系统、文本与 SHA256。它先检查上一 36-source 报告的原始字节 SHA，再校验本轮固定源码及符号；不会启动进程、编译内核、加载库或计算物理算法。缓存根目录为 `/tmp`，具体相对路径在 evidence 中。

```text
moon run --target native --warn-list -a --target-dir _build/script-check scripts/audit_apic_cooking_device_sources.mbtx . /tmp --verify
```

该命令只验证元数据。下述 native 编译/执行 API 均为以后明确调用的接口，本轮未调用。

## 本轮实际增加的能力

| 子系统 | 现有真实实现 | 尚未完成的闭包 |
| --- | --- | --- |
| [cooking](../src/learning_aligned/producer_native/cooking/README.md) | MoonBit 验证并打包显式三角形局部坐标；真实 Warp C API 创建、refit、销毁 CPU Mesh/BVH；实际 owner 生命周期 | USD triangulation/scale/reflection、凸包、SDF、质量/惯量推断、GPU Mesh、Newton 全 Model finalize |
| [schema_constraints](../src/learning_aligned/producer_native/schema_constraints/README.md) | 有限 builtin Newton/PhysX/Mjc authored 优先级、getter/默认值、首次使用属性采集；connect/weld/scalar-joint equality 的真实 typed rows 与 MjSpec authoring slots | 全 USD composition、custom resolver、fixed-joint collapse 与 mimic/loop remap、编译后参考常数、完整约束 Jacobian/Hessian |
| [convex](../src/learning_aligned/producer_native/convex/README.md) | primitive/显式顶点 support、完整 S1D/S2D/S3D simplex、实际 GJK 迭代、cutoff/witness、sphere/capsule shrink/inflate；typed CUDA lowerer | EPA 深穿透、接触 manifold、最终 CCD/material contact writer、heightfield/flex/非凸三角碰撞 |
| [tile_solver](../src/learning_aligned/producer_native/tile_solver/README.md) | MoonBit 经真实 Warp C ABI 生成 cuSolverDx POTRF/POTRS LTOIR+FATBIN，再经 NVRTC/nvJitLink 链接 CUBIN；独立 dense tiles 的真实 CUDA call sites | 完整 mixed CSR/gather/scatter GPU factorization、稀疏尾部、全部 solver 调度、MathDx 运行与差分验证 |
| [device_convergence](../src/learning_aligned/producer_native/device_convergence/README.md) | 真正 `_solve_done` / CG beta-finalize 的 FP32 device 算法；done/niter/overflow/nsolving 更新 | 完整 GPU line search、梯度/Hessian/Jacobian producer、完整 Newton/CG solver body 与 tile 归约顺序等价 |
| [gpu_pipeline](../src/learning_aligned/producer_native/gpu_pipeline/README.md) | 校验并执行上述真实 module，device 条件 WHILE、owned buffer/状态保护、执行后结果 gate | 自动生成完整 G1 物理程序、所有 upstream Python kernel/codegen/dispatch 的全量替换 |

### CPU Mesh/BVH：原生资源与几何 cooking 的界线

`cooking.prepare_mesh(MeshRequest)`验证显式 float32 点/速度、int32 三角形索引与可选 group。它拒绝 float32 转换后退化三角形、索引越界、非有限/上下溢和未三角化输入；不猜测 USD 变换、单位或拓扑。`mesh_artifact`写真实 bytes 与元数据，属于 host preparation。

`open_host_mesh(adapter, warp_library, prepared)`通过 genuine `warp.h`/`array.h` ABI 调用 `wp_mesh_create_host`，并提供真实 `wp_mesh_refit_host`、`wp_mesh_destroy_host`。适配器拥有 points/velocities/indices/groups 的稳定 native vectors；Warp 借用这些指针，refit 不 resize，先销毁 Mesh/BVH，再卸载 Warp，最后析构 vectors。MoonBit 外部对象保留 adapter 并有显式关闭/最终清理。**CPU resource ID 不能作为 CUDA mesh ID，也不是可序列化复用的 BVH**。

只查询 `wp_version()==1.17.0`，不调用 `wp_init`：pinned `warp.cpp::wp_init` 会调用 `cuda_init`。`execute_cook`未来执行时才创建/关闭真实资源并写 receipt；其 root library/adapter 前后 SHA 不覆盖全部传递 native 依赖。

Newton `Mesh.finalize` 后续仍涉及 content/device cache、signed scale/winding、convex hull 与 support adjacency、surface velocity、SDF/hydroelastic、device/gradient mesh，以及 `geometry/inertia.py` 的质量、COM、惯量积分与修正。新增 host BVH 无法替代这些语义，也未将任意三角网格声明成凸体。

### Schema 与 equality：显式输入，保留真实默认值

`resolve_schema(SchemaRequest)`按调用者给定 resolver 顺序选择第一个成功 authored 值，再使用 caller default、首个非空 mapping default；默认值不冒充 authored supplier。支持域覆盖显式有限 logical keys，保留 PhysX `contactOffset-restOffset`、Mjc effort-range 与 solref 转换，以及首次成功使用时采集 namespaced 属性。完整 USD authored/time-sampled/composition 语义仍依赖调用者提供的已解析输入。

`prepare_equalities(EqualityRequest)`生成真实 Newton float32 频率字段与提升至 Double 的 MjSpec data slots，保留 world ordering、body/joint 类型与跨 world 护栏。weld 缺失 relpose 时保留 pinned public helper 的 **`position=(0,1,0), quaternion=(0,0,0,0)`** sentinel，由未来模型编译器推断参考相对位姿；不会提前替换成 identity。connect/weld/scalar-joint authoring rows 不代表已生成运行中的约束 J/H 或编译后的 eq_data。

XML 包含全部输入 rows，对应非分离模型的 authoring 分支。分离 MuJoCo worlds 时选择首个本地 world 加全局 rows 的步骤仍需调用者显式准备；本接口不推断该选择或全模型名称映射。

### GPU 凸体：真实 GJK 子程序，拒绝尚未迁移的接触分支

`convex`迁移 pinned `collision_gjk.py` 的 actual support、signed-volume/minor simplex 子算法、离散方向稳定化、Frank-Wolfe/cutoff 终止与 witness 恢复。mesh 使用显式实际 owned vertex arrays 的 exhaustive support 分支，并保留缓存索引与严格 tie 规则；它求这些点的凸包 support，不执行非凸三角碰撞，也未创建 Warp GPU Mesh。

Sphere/capsule 浅接触沿用 shrink→GJK→inflate。需要 EPA 深穿透、迭代耗尽、非法/不稳定低维结果时返回明确拒绝 status，不能把它们算作分离成功。输出是 **GJK phase 的距离与 witness**，尚未经过最终 CCD margin/gap、material mixing、contact writer/manifold。pipeline 必须实际执行后读取全部 status/rejected 才能公布该阶段结果，不能据此公布最终 contacts。

### MathDx：C 接口可用，链接链路不等于完整 mixed solver

真实 ABI 是 `wp_cuda_compile_solver` 与 `wp_cuda_compile_program`，不是对 C++ template 做 `dlsym`。前者通过 libmathdx cuSolverDx descriptor 产生实际 POTRF/POTRS LTOIR 与 universal FATBIN；后者 NVRTC LTO 编译并经 nvJitLink 链接。`num_include_dirs=0`、`include_dirs=nullptr`、`mathdx_include_dir=nullptr`遵循该 pin 的实际实现。FATBIN 必须与 LTOIR 一起链接一次。`wp_cuda_compile_program`返回的是状态，**零成功**。

`mathdx.cpp`在 CUDA/MathDx 不可用构建下提供 false stub，因此代码检查 `wp_is_cuda_enabled/wp_is_mathdx_enabled`，拒绝降级成虚假成功。新增 dense tile 接口采用 row-major、Upper、float32/float64、size 1..64，每 CUDA block 合作处理一个 tile，所有线程参与 POTRF/POTRS 并同步；status 全零才允许公布结果。真实 MathDx specialization、资源占用与 GPU 运行仍待复测。

已有 CPU/Double mixed factorization 继续保留。独立 MathDx tile 尚未接完整 MuJoCo block selection、CSR gather/scatter、compact/sparse tail、world mask 与 solver 调度；manifest 的 `mixed_sparse_gather_closure_generated`及`physics_solver_closure_generated`保持 false。

### Device WHILE：动态收敛条件已迁，完整迭代体尚未迁

新增 FP32 CUDA producer 迁移 `_solve_done` 和 `_solve_beta_finalize_tiled` 的真实 done gates、niter 增量、ITERATIONS overflow=512、原子 nsolving 减计数，以及 CG beta 公式。每 world 单线程顺序归约 nv，明确不宣称与 upstream GPU tile 关联顺序数值一致。

pipeline 中多次 WHILE 必须是 top-level；body 最后无条件运行唯一 convergence producer，并更新与 WHILE 完全同一个 `nsolving` view。实际初始 bytes 要求 canonical bool、`nsolving=#unfinished`、unfinished 的 niter 小于有限 iteration limit。done/niter/overflow/nsolving 的四个完整 owner 独立冻结，仅该 producer 可写，其他 kernel/copy/zero 及分支写入全部拒绝；tolerance/meaninertia 同样全程序只读。每个 world 最多从 unfinished 转换一次并减一，niter 上界保证有限退出，不能用固定 repeat 冒充收敛。

只有真实执行后 count=0、all done、niter range gate 才通过；record-only 不声称成功。body 可显式调用其他实际 kernel 更新浮点 metrics，但三类既有 G1/MJW primitive lowerer 加新增 modules 仍不足以自动产生完整 solver equations、GPU line search 或全接触程序。无 convergence producer 的旧受限 WHILE 仍只接受最后 unconditional clear 条件的零/一次 profile。

## 运行时、构建时与后续工作

| 依赖 | 本轮位置 | 迁移结论 |
| --- | --- | --- |
| Python/NumPy host triangle packing | 旧 Newton Mesh wrapper 的一部分 | 新显式 MeshRequest preparation 已有 MoonBit 实现，原实现保留 |
| Warp host Mesh/BVH | 运行时几何资源 | 由 MoonBit 连接真实 C API；需要匹配 native 库及 owner，未在本轮执行 |
| Python USD resolver/equality host authoring | 模型构建时 | 有限实际字段已迁 MoonBit；USD composition 与全模型编译仍有缺口 |
| Python Warp GJK AST/codegen | GPU kernel 构建时 | 已迁固定支持域的 MoonBit typed lowerer；EPA/manifold 等闭包尚缺 |
| Python MathDx build wrapper | GPU kernel 构建时 | 新 MoonBit 直连真实 Warp/libmathdx C/LTO/link 链；需要 CUDA/MathDx native 组件，未编译 |
| Python convergence dispatch wrapper | device 循环 orchestration 与 kernel 构建 | 新真实 producer+native conditional WHILE 已接；完整迭代体仍不是全原生 solver |
| Isaac/Kit、完整 Newton Model 与上游差分 | 参考/尚未迁移的全量路径 | 继续保留，不能由本轮局部模块替代或宣称全链脱离 Python |

优先缺口依次是：完整 Newton cooking 与模型惯量/资源闭包；GJK 后的 EPA/manifold/contact material writer；mixed GPU gather/scatter/sparse-tail 与 Hessian factor/solve；由实际 equations 组成的 GPU line-search/gradient/constraint 迭代体；最后在机器空闲后验证 native ABI、生命周期、CUDA/APIC replay 与原实现差分。CPU/Double 与 GPU FP32/FP64 的数值、学习及物理结果等价性均等待复测。

## 显式 CLI 与配置入口

[CLI](../cmd/reference_apic_export/main.mbt)形式为 `reference_apic_export SUBCOMMAND CONFIG.json`。本轮新增映射如下，**全部未运行**；原默认/reference export 语义不变。

| 子命令 | Config JSON 与实际 API |
| --- | --- |
| `prepare-mesh` | `{request: cooking.MeshRequest, output: String}` → `cooking.mesh_artifact`，只准备 host bytes |
| `cook-host-mesh` | `cooking.ExecuteRequest {request, adapter, warp_library, output}` → `cooking.execute_cook`，未来调用会创建并关闭真实 host Mesh/BVH |
| `prepare-schema` | `{request: schema_constraints.SchemaRequest, output: String}` → `decode_schema` / `schema_artifact` |
| `prepare-equalities` | `{request: schema_constraints.EqualityRequest, output: String}` → `decode_equalities` / `equality_artifact` |
| `compile-convex-gjk` | `convex.CompileConfig {request, mujoco_warp_root, warp_native, nvrtc_library, options, kind, output}` → `compile_specialization` |
| `compile-mathdx-tile` | `tile_solver.CompileConfig {request, warp_library, warp_native, cuda_include_dirs, output}` → strict `decode_config` / `compile_artifact` |
| `compile-device-convergence` | `device_convergence.CompileConfig {request, mujoco_warp_root, warp_native, nvrtc_library, options, kind, output}` → `compile_specialization` |
| `run-gpu-pipeline` | `gpu_pipeline.decode_config(Config)` → `execute`，消费实际 compiled artifacts；body与owned typed views必须显式提供 |

host preparation 的配置外壳示例（`request`必须另填对应完整字段，此处只展示封装，不能作为可执行配置）：

```text
{"request": <MeshRequest / SchemaRequest / EqualityRequest>, "output": "<fresh-directory>"}
```

`MeshRequest`字段为 `vertices/indices/velocities/groups/bvh_constructor/bvh_leaf_size/support_winding_number`；`SchemaRequest`为 `resolvers/prim_type/attributes/keys/defaults`；`EqualityRequest`为 `world_count/body_world/body_names/joints/joint_names/rows`。嵌套 row、CUDA Request、pipeline Config 的精确字段与支持域以各包 README、生成接口为准：[cooking API](../src/learning_aligned/producer_native/cooking/pkg.generated.mbti)、[schema/equality API](../src/learning_aligned/producer_native/schema_constraints/pkg.generated.mbti)、[convex API](../src/learning_aligned/producer_native/convex/pkg.generated.mbti)、[MathDx API](../src/learning_aligned/producer_native/tile_solver/pkg.generated.mbti)、[convergence API](../src/learning_aligned/producer_native/device_convergence/pkg.generated.mbti)、[pipeline API](../src/learning_aligned/producer_native/gpu_pipeline/pkg.generated.mbti)。
