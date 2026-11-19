# APIC 全量原生翻译：源码、可调用路径与验证边界

本轮按 cooking、完整接触几何、mixed/sparse 求解与 Newton/CG GPU 迭代四条路径持续补实现。原 Python 与既有 MoonBit reference producer 保留；新路径通过 MoonBit typed CUDA lowerer、真实 Warp/MuJoCo/Qhull C 接口和 owned buffers 工作。**不能把生成源码、接入 API、运行成功和数值等价合成一个“100%”结论。**

| 维度 | 判断依据 | 当前状态 |
| --- | --- | --- |
| 源码翻译 | 真实公式、分支、循环、状态与 native ABI 已落地，可定位到固定源符号 | 下表逐项登记；仍有分支/调用边界，未宣称全部 upstream 代码完成 |
| 支持的 callable path | 公共 typed API、lowerer、绑定与入口接线实际存在，输入域/owner/错误受校验 | 新模块提供真实实现；全 SDK Model/scene/step 闭包另外判断 |
| SDK / runtime execution | 实际 native 调用、编译、GPU launch/APIC replay | 本轮全部未运行 |
| 数值与学习/物理等价 | 同输入原实现与新实现差分 | 等机器空闲后复测；CPU Double、GPU FP32/FP64、归约关联顺序不能预先判等 |

[固定源码证据](APIC_FULL_NATIVE_SOURCE_EVIDENCE.json)当前登记 **62 份固定源文件**，由[纯 metadata 脚本](../scripts/audit_apic_full_native_sources.mbtx)读取字节、SHA 与词法声明生成。它严格验证上一 [32-source evidence](APIC_COOKING_DEVICE_SOURCE_EVIDENCE.json)原始 SHA 链；旧报告不刷新。词法 `def` inventory **不是 call graph，也不是自动完成率**。Newton pin 为 `71eeba16a717d4dcf0b9dd7056a7b6f863054dc3`，Warp 为 `v1.17.0`，MuJoCo-Warp 为官方 `3.15.0` sdist；Qhull `2020.2` 与 MuJoCo `3.3.7` 头文件单独列证，不混同后端版本。

## 接触计算：真实公式覆盖

主要新实现为 [convex/contacts](../src/learning_aligned/producer_native/convex/contacts/README.md)，并行保留旧 primitive、distance-only GJK 与 CPU MuJoCo collision 接口。

| 固定上游 callable | 实际新代码 | 覆盖与差异 |
| --- | --- | --- |
| `collision_gjk.support`、`_gjk_support`、`_S1D/_S2D/_S3D`、`gjk/gjk_phase` | `contacts/support.mbt`、`simplex.mbt`、`gjk.mbt` | primitive、mesh exhaustive 与真实 graph hillclimb；两种 cached-index 语义和严格 tie 保留；FLEX/TRIANGLE support helper 已有公式，deformable entry 未接 |
| `_attach_face/_epa_support`、`_polytope2/3/4`、`_rotmat/_ray_triangle/_test_tetra` | `contacts/epa.mbt` | 实际初始 polytope、边界 fallback、packed faces、容量/数值错误护栏 |
| `_add_edge`、face flags、`_epa`、`_epa_witness`、`epa_phase` | `contacts/epa.mbt`、`core.mbt` | 实际动态 horizon/最近面/重复 support/见证恢复；10-bit 顶点限制；耗尽或容量失败拒绝发布 |
| `_feature_dim/_intersect1/_intersect2`、mesh/box/cylinder normals/edges/faces、alignment | `contacts/manifold.mbt` | 实际 feature recovery、local/global mesh indices、面/边顺序；输入双向 polygon membership 先验证 |
| `_plane_normal/_halfspace/_plane_intersect/_witness_on_face/_polygon_clip/_polygon_quad/multicontact` | `contacts/manifold.mbt` | 实际 clipping、去重/面积 quadrilateral 选择、四 contact 与空 manifold 回退；所有 push 有显式容量 |
| `collision_primitive.plane_convex`、plane wrappers/core | `contacts/plane.mbt` | plane-sphere/capsule/ellipsoid/cylinder/box/mesh；真实 mesh exhaustive/hillclimb 四点选择；plane-box 实际八角点；sensor 占位槽保留 |
| `collision_convex._hfield_filter/ccd_hfield_kernel_builder` 与 hfield 特殊 support/inflate/EPA witness | `contacts/hfield.mbt`、`gjk.mbt`、`epa.mbt` | 实际 local transform、raw geom-margin/rbound filter、subgrid/prism 遍历、50 临时 contact 与四点选择；world 输出不重复做 rigid margin 修正 |
| `collision_core.contact_margin_gap/contact_material_params/write_contact`、`eval_ccd_write_contact` | `contacts/materials.mbt`、`write.mbt`、`lower.mbt` | 真实 pair override/priority/solmix/friction/adhesion、inflated-distance gate→margin correction、frame、sensor/constraint flags、slot IDs 与全 EFC slots |
| `_ccd_grid_size`、`convex_narrowphase` / `_pair_count` | `contacts/planner.mbt` | 实际 scratch/layout 与 per-type launch plan；硬件 occupancy 结果是显式输入，runtime query/launch 单独接线 |

`contacts`当前为 **69 个真实 typed views**，Request 显式给出 mesh/graph/polygon/hfield/scratch capacities；native entry 在任何数据索引前做 descriptor 与真实内容范围检查。Host `validate_bindings`证明完整 reachable bytes、alignment、scratch 行不重叠与所有写 view 的 alias 域。counter 最坏写入是八 contact/candidate，因此 `contact_capacity+8*candidate_capacity<=INT_MAX`。真实执行后才读取 ncollision/nacon 与八个 rejection counters，经 `validate_results`发布。

`plan_host_schedule(HostScheduleRequest)`还实际翻译 `convex_narrowphase` 的 box-only 16 EPA 迭代、global polygon sizing、scratch 分配字节、hfield-first launch 顺序及 `_ccd_grid_size` 两波 occupancy 上限。它消费真实外部 query 结果，返回 typed plan；不执行 query/分配/launch。上游按类型的 layout 与新的统一 69-view terminal entry 分开，不能互换。

仍需独立识别的调用闭包包括 `collision_driver` 的全 broadphase/candidate 排序、`collision_flex` 的真实 deformable providers/filter/FPS/soft writer、`collision_sdf.sdf_narrowphase`，以及 occupancy 查询与完整动态 workqueue 的实际执行接线。不能因为 shared support helper 已包含 TRIANGLE/FLEX 分支，就称这些完整调用路径也已迁移。`mjMAXVAL=1e10`、`mjMAXCONPAIR=50`有单独固定 MuJoCo 3.3.7 header 常量证据；未查询 SDK runtime，也不据此判定 3.15 runtime 等价。

## Mixed / sparse factor 与 solve

[sparse_solver](../src/learning_aligned/producer_native/sparse_solver/README.md)提供真实 GPU mixed factor、solve、fused factor-solve 与 D-CSR sparse LU；CPU/Double [factorization](../src/learning_aligned/producer_native/factorization/README.md)及独立 [MathDx tiles](../src/learning_aligned/producer_native/tile_solver/README.md)继续保留。

| 上游 callable / layout | 新实现 | 关键语义 |
| --- | --- | --- |
| `io` tree/block selection 与 CSR/gather index layout | `factorization.describe_mixed_layout`、`sparse_solver/metadata.mbt` | actual tree metadata、compact/scalar/gather/sparse 分类、缺项 `nC` sentinel；实际 metadata bytes 必须匹配且全程序冻结 |
| `_small_cholesky_factorize_block/_small_cholesky_solve_block/_small_cholesky_factorize_solve_block` | `sparse_solver/helpers.mbt::mr_small` | actual compact reciprocal 与 full small scalar Cholesky/solve，保持源公式除法/乘法 |
| `_tile_cholesky_factorize_block/_tile_cholesky_solve_block`、Warp native scalar tile fallback | `mr_gather` | actual gather、upper factor、opposite triangle clear、solve/scatter；显式 scalar GPU tile fallback，非已经验证的 MathDx association |
| `_factor_i_sparse/_qLD_acc/_qLDiag_div` | `mr_sparse` | 整个 nC tail 复制、reverse-level 原子 LDL、每 level barrier、存在 sparse tail 时 ALL-nv D 覆盖 |
| `_solve_LD_sparse_fused/solve_LD/solve_m/factor_solve_i` | `mr_sparse` 与生成 entry | sparse-only UP / diagonal / DOWN、真实每层同步与 mixed dense prefix |
| `_factor_solve_lu_sparse_fused/factor_solve_lu` | `sparse_solver/lu.mbt` | 实际 reverse sparse LU elimination、remaining-row scratch、(U+I) backward 与 L forward；sorted CSR/diag/symbolic-fill proof |

Cooperative entry 的 status/done 由 lane0 一次快照并同步广播，避免迟到线程因本 block 刚写 failure 而绕过 barrier。失败状态 sticky；不能用后续 zero/copy 覆盖。mixed RHS/result 仅允许真实 exact-inplace 情形；LU 的 solution 先作为 row-count scratch，因此明确禁止与 RHS alias。这里的真实 GPU scalar/tile body 不等于完整 upstream blocked Hessian 调度与所有 runtime 特化已验证。

## Newton / CG GPU 动态迭代

[newton_solver API](../src/learning_aligned/producer_native/newton_solver/pkg.generated.mbti)提供 actual FP32 objective/derivative 的 full-rebuild reference GPU 路径；[device_convergence](../src/learning_aligned/producer_native/device_convergence/README.md)负责实际 convergence/beta/niter/nsolving。它不是只执行一个 convergence kernel 的空 WHILE。

| 固定源码功能 | 新代码 | 当前 callable 边界 |
| --- | --- | --- |
| warmstart、Jaref、Ma、qfrc、search 初始化 | `newton_solver/kernels.mbt`、`model.mbt` | 实际 dense/CSR J/M、已给定真实模型/约束 buffers；不填 identity M 或 zero J |
| `_eval_constraint`、ellipse/quadratic/friction states、Jᵀ force、gradient/Hessian | `equations.mbt`、`kernels.mbt` | 实际 analytic curvature 与完整 H 重建；明确区别源 incremental/stable-state 优化和 tile 关联顺序 |
| factor/direction 与 CG initial done | `kernels.mbt` | 真实 Cholesky solve、Newton direction/decrement、CG preconditioned search；状态/计数与真实初始 unfinished 数一致 |
| `_linesearch_iterative_kernel`、shifted pyramidal/elliptic costs、bracket | `line_search.mbt`、`equations.mbt` | 实际动态标量候选/接受/改进/迭代上限、qacc/Ma/Jaref 更新；不以固定 repeat 替代收敛 |
| `_solve_done/_solve_beta_finalize_tiled` 与 native `capture_while` | `device_convergence`、`gpu_pipeline` | producer 必须末尾无条件更新完全相同 predicate；owner 保护/初始 count/niter 有界证明；执行后 all-done/count0 gate |
| `njmax==0` / zero DOF | `newton_solver` unconstrained entry/planner | 独立真实 qacc_smooth copy/constraint zero/niter reset；不创建虚假的 solver loop |
| `_init_compact_inertia/_gather_M_sparse/_gather_rhs_compact/_scatter_solution`、DOF/J gather/scatter、compact/full M multiply | `solver_adapters/compact.mbt` | 实际 inverse maps、active prefix、padded identity/zero、dense/CSR 原数据与稀疏乘法；不是伪造 awake map |
| constraint state/quad change、incremental qfrc/gradient/H、factor reuse/stable ray、qfrc recovery | `solver_adapters/incremental.mbt`、`newton_solver` incremental line search | 实际变化行列表/增量 H、grad_scale、noise-floor exhausted 与缓存 Cholesky；非椭圆约束 profile，显式区分原 tile association 与 symmetric H 存储 |
| `island._reset_compact_maps/_compact_dofs_builder/update_active_dofs` | `solver_adapters/active_maps.mbt` | 实际 CPU host tree-order awake==1 packing、reset、nvmax cap 与 NVMAX128；导入真实 map bytes，不冒充 replay 内动态 GPU sleep producer |

[solver_metrics](../src/learning_aligned/producer_native/solver_metrics/pkg.generated.mbti)另外提供实际 `derivative.py` 的 effective rhs、3×3 Cholesky/solve、efm0 sparse solve、backbone rhs、tendon/actuator/efc/contact rank1 fold、fluid/diag/CSR matvec 与 qH additions。`preconditioner_plan`按实际 efm0/block/backbone 分支组装，`backbone_factor_plan`实际复制 M→qH 再加真实 coefficients 并 factor；没有从计数制造系数。串行 FP32 world 归约与原 atomic/tile 关联顺序仍需差分。

实际 compact incremental planner 现在包含 M/J/vector gather→core controls/state/H/factor→incremental 初始化→真实 WHILE→qfrc recovery→scatter/full-Ma refresh，核心与 adapter 读取相同真实输出 views。Pipeline 从认证 module Request 与实际 view 重算完整 canonical plan，逐项比较顺序/状态；不接受缺失初始化、陈旧 factor、插入的 copy/zero 或另一个 J。完整 M 源 owner 在 gather 到末尾 Ma refresh 之间也不能被中间 scratch 写坏。已完成的 mutable state 不能被无关 suffix 覆盖。

标准 full-rebuild Newton 同样逐项认证实际 initial4+WHILE，不能只运行收敛计数 kernel 到上限就宣称完成 Newton 迭代。CG 的 dense/operator 分支另经完整 canonical plan、真实 preconditioner chain 与 core gradient/res/done 身份证明。以上均为实际代码中的源码/结构/owner 校验；未执行物理算法、GPU 或差分测试。

DISCRETE 的完整 coefficient 生成、replay 内动态 GPU sleep/active-map 更新及其与全 `forward/step`的上下游闭包必须分别登记，不能由调用者提供 `added_metric` 或 index map 字段自动算作已经生成实际物理数据。已落地的 compact/incremental kernel、host plan 与 CPU active-map producer 不再列为“未翻译”；公共 artifact、绑定与调度接线见 [solver_adapters API](../src/learning_aligned/producer_native/solver_adapters/pkg.generated.mbti)。最终 source ledger 未逐项覆盖之前，`full_solver_closure`继续保持 false。

## Cooking 与资源闭包

[cooking](../src/learning_aligned/producer_native/cooking/README.md)本轮从 host BVH 扩展到实际 mesh moments/solid/hollow inertia、primitive/shell mass、scale/reflected winding/heightfield mesh、topology、convex hull/support adjacency、device Mesh/cache，以及 sparse SDF/Volume/Texture 原生资源。调用源包括 Newton `geometry/types.py::Mesh.finalize`、`geometry/inertia.py`、`geometry/utils.py::remesh_convex_hull`、SDF helpers 与真实 Warp native Mesh/Volume/Texture ABI。

| 固定源码功能 | 实际实现 | 完成度与执行边界 |
| --- | --- | --- |
| `Mesh.finalize` points/triangles、scale/reflected winding、heightfield mesh | `prepare.mbt`、`geometry.mbt` | 真 f32/i32 owned bytes、实际坐标/索引变换；不假装完成 USD triangulation/composition |
| `geometry/inertia.py` solid/hollow moments、shape/shell mass、惯量变换/修正 | `mass.mbt`、`primitive_mass.mbt`、`spectral.mbt` | 实际 tetra/triangle wedge、analytic primitives、barrel quadrature、Jacobi；CPU Double 与 upstream NumPy/Warp 关联顺序待差分 |
| rank0/1/2 hull fallback 与 3D Qhull retry | `hull.mbt`、`native/hull.cpp` | 真 reentrant Qhull `Qt/TA/QJ` ABI；没有实际执行 native hull |
| canonical vertices/edges/dihedral/watertight、support adjacency/LUT | `topology.mbt` | 真算法与 closed-convex certification；canonical ID 排序差异不能预判为字节等价 |
| concave edge / redundant-edge absorption | `collision_edges.mbt` | 实际几何判断/解析过程；并列登记两份固定 helper 源，非只记录选项 |
| Warp host/device Mesh/BVH、refit/sharing/cache | `native.mbt`、`native/host_mesh.cpp`、`cache.mbt` | 真 native allocations、stable vectors、device context retained owner、typed lease；CPU id 与 CUDA id 分离 |
| surface velocity、point/velocity adjoint storage | [gradients.mbt](../src/learning_aligned/producer_native/cooking/gradients.mbt) `refit_velocities/enable_gradients/zero_gradients/gradient_snapshot` | 真 `array_t.grad` 与 host/device owned allocations、同步快照；不是 Tape/backward，保留 pinned `MISSINGADJOINT` 边界 |
| `_build_sparse_sdf` occupancy/729 samples/linearity、slots/paired-X/quantization | `sdf.mbt`、`primitive_sdf.mbt` | 实际 sparse storage 构造；量化与未用 texel 初值需逐字段审计，不能因有纹理对象即宣称等价 |
| `create_sparse_sdf_textures`、`Volume.from_tiles`/stores | `fields.mbt`、`native/field.cpp` | 真 Warp Texture3D/NanoVDB ABI、host storage 与 CUDA copy/object；非自造 texture/NanoVDB descriptor |
| software sample/gradient、integer voxel lookup、texture isomesh | `sdf_sample.mbt`、`isomesh.mbt`、`mc_tables.mbt` | 真 fine/coarse/quantized/extrapolation、MC case/edge/三角插值与反转面；literal table 由纯文字脚本读取固定源，CPU 发射顺序区别原 GPU atomic append |
| legacy occupied tiles/coarse volume、late margin 与 legacy→texture | [legacy_sdf.mbt](../src/learning_aligned/producer_native/cooking/legacy_sdf.mbt) `build_legacy_sdf/open_tile_volume/sample_volume/to_texture`、`native/field.cpp` | 真 8³ tile 与独立 coarse 数据、PNanoVDB linear world sampling、native host/device resource；background 使用固定 `core/types.py::MAXVAL=1e10`，不以 texture 数据替代 legacy volume |
| persistent sparse-data cache | [sdf_cache.mbt](../src/learning_aligned/producer_native/cooking/sdf_cache.mbt) `mesh_sdf_cache_key/primitive_sdf_cache_key/store_sdf_cache/load_sdf_cache/validate_storage` | 实际 typed binary+JSON/SHA 格式；区别原 `_sdf_cache.py` 的 NPZ/Blake2b 文件名与失败时 log+miss，不宣称磁盘格式兼容或可复活指针 |

以上层次分别核对 native allocation/device context/借用指针/缓存失效/销毁顺序。Native cleanup 先销毁 Warp resource，再释放其库与私有 retained Context；native Volume descriptor 与显式 owned GPU allocation 的所有权分开。独立 dense distance/reference 算法不能替代真正的 sparse texture/NanoVDB storage。CPU host resource ID 不能用于 CUDA；资源 receipt 不能序列化成可复用 pointer。真实 native API 的实现、源码校验与成功 SDK execution 仍分别计量。

全 Newton `ModelBuilder.finalize`还涉及 USD composition、schema、articulation/world ordering、joint/shape/particle/flex/constraint/collision资源与 device arrays，不能通过“返回一个描述性 JSON”标记全 Model 完成。已有 [builder](../src/learning_aligned/producer_native/builder/pkg.generated.mbti)、[finalize](../src/learning_aligned/producer_native/finalize/pkg.generated.mbti)、[schema_constraints](../src/learning_aligned/producer_native/schema_constraints/README.md)的实际数组实现继续复用，缺项由其 typed API/source ledger明确记录。

## 显式入口

[reference_apic_export CLI](../cmd/reference_apic_export/main.mbt)目前提供以下新路径；这里只描述调用协议，**本轮没有执行这些命令**。旧 `export` 仍为保留的 reference alias。JSON 里的数组必须来自真实模型与 owned buffer，不能用示例计数或 identity/zero 填充物理数据。

| 子命令 | 配置与公共 API |
| --- | --- |
| `cook-native-geometry` | `{ "request": GeometryRequest, "output": "fresh-directory" }` → [cooking API](../src/learning_aligned/producer_native/cooking/pkg.generated.mbti) `geometry_artifact` |
| `compile-convex-contacts` | [contacts CompileConfig](../src/learning_aligned/producer_native/convex/contacts/pkg.generated.mbti) → `compile_specialization`；真实 mesh/hfield/scratch capacities |
| `compile-sparse-solver` / `compile-sparse-lu` | [sparse_solver decode_config/decode_lu_config](../src/learning_aligned/producer_native/sparse_solver/pkg.generated.mbti) → 对应真实 compile API |
| `compile-newton-solver` | [newton_solver CompileConfig](../src/learning_aligned/producer_native/newton_solver/pkg.generated.mbti) → `compile_specialization` |
| `compile-solver-adapters` | [solver_adapters CompileConfig](../src/learning_aligned/producer_native/solver_adapters/pkg.generated.mbti) → 实际 compact/incremental 模块 compiler |
| `prepare-compact-smooth` / `prepare-compact-constraints` | `CompactPlan` → `compact_smooth_plan` / `compact_constraint_plan`；真实 gather→typed solve program→scatter |
| `prepare-incremental-newton` | `IncrementalPlan` → `incremental_plan`；真实初始 H/factor、变化行/缓存迭代与 recovery |
| `compile-solver-metrics` | [solver_metrics CompileConfig](../src/learning_aligned/producer_native/solver_metrics/README.md) 经 `decode_config` → `compile_artifact` |
| `prepare-solver-preconditioner` | `PreconditionerPlan` → `preconditioner_plan`；真实 gradient/res/qH factor views 与状态 owner |
| `prepare-solver-backbone` | `{ "request": PreconditionerPlan, "include_fluid": true或false }` → `backbone_factor_plan`；真实 packed M/qH 与 metric coefficients |
| `prepare-newton-program` | `PlanRequest` → `plan`；真实 constraint/model typed views |
| `prepare-newton-operator-program` | `{ "request": PlanRequest, "preconditioner_program": [actual-operations] }` → `plan_with_preconditioner` |
| `prepare-effective-cg` | `EffectiveCGPlan { solver, operator }` → `effective_cg_plan`；真实 operator 的 gradient/res/done 直接绑定到 CG |
| `run-gpu-pipeline` | [gpu_pipeline Config](../src/learning_aligned/producer_native/gpu_pipeline/README.md) 经 `decode_config` → `execute`；先认证源码/image/layout，真实执行后才发布结果 |

构造 artifact 的基础外层为 `{ "request": { ...typed fields... }, "output": "fresh-directory" }`；compiler 配置还要求实际 `nvrtc_library`、`warp_native`、`mujoco_warp_root` 与 `cuda_include_dirs`，精确字段以相应 `.mbti` 和 README 为准。Live Mesh/Texture/Volume/cache API 保持显式资源对象，不能由 CLI receipt 的数字指针复活。

## 保全与复测

本轮不删除、不覆盖其他任务正在修改的 Python。旧 `PYTHON_MIGRATION_INVENTORY.json`仍是不可刷新来掩盖变化的历史 hash 记录；已有 metadata 验证发现 aligned train/learning/networks 变更及 distributed 新增，不能把它们当作排序噪声忽略。reference `.mbtx` wrappers 引用当前模块，不等于旧 Python 字节已独立归档。最终 drift 以严格校验器的 changed/added/missing 诊断为准，保留并发工作与旧基线。

可执行验证仅限机器空闲之后；本轮只允许 MoonBit check/info/fmt、真实头文件 syntax-only 和上述纯 FS/text/crypto evidence 审计。没有执行任何测试、科学数值算法、原生资源构建、SDK/GPU/NVRTC/MathDx 或 APIC 导出。
