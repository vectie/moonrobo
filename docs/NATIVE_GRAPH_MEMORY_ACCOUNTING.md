# Native learner graph memory accounting

Audit date: 2026-10-24. This is an implementation review and a proposed accounting design, not a replacement admission formula or a larger-batch launch approval. No training code, memory coefficient, logical batch, precision, optimizer schedule, or simulator setting was changed for this document. No GPU job or SSH session was started by this review.

## Conclusion

The current planner intentionally composes several conservative estimates. Its actor graph estimate is multiplied by the imagination horizon, then the largest device working estimate is doubled and retained in every later phase. The maximum fresh-run phase is optimizer serialization, which independently includes 10 GiB of serialization workspace and 1.5 GiB of archive file cache. Consequently, bounding actor CPU decoding to 256 starts does **not** reduce that maximum or make microbatch 1024 admissible.

The implementation does support a more precise, reviewable graph ledger: one chunk graph at a time, one tail critic per chunk, shared frozen parameter storage, and separate graph-building, detached feature-building, concatenation, critic, and checkpoint phases. Some of these are provable lifecycle facts. A complete numerical upper bound still needs the full kinematic graph, backward temporaries, actual ATen dispatch, allocator rounding/retention, and non-Torch workspaces. The measured microbatch 256 peak is evidence of conservatism for one run, not a factor by which to divide the planner.

## Scope and notation

This review covers the explicit microbatch paths in [microbatch.mbt](../src/learning_aligned_gpu/microbatch.mbt) and [actor_microbatch.mbt](../src/learning_aligned_gpu/actor_microbatch.mbt), with FP32 tensors, no AMP, and the current eager C++ adapter. Both zero microbatch and microbatch equal to the logical batch select a different full-batch path (`learning.mbt:186,359`); the reduced lifecycle ledger must not silently apply to that path. In particular, the subsequent WM2048/actor512 trial uses the full world path and chunked actor path. Optional diagnostic traces, distributed collectives, alternate geometry, and other dtypes require their own allowances.

| Symbol | Meaning | Reviewed paper configuration |
| --- | --- | --- |
| `m` | Active chunk rows, including a possible smaller last chunk | 256 or 512 in the sweep; 1024 is a planning candidate |
| `Bw`, `Bp` | World and policy logical batches | 2048, 4096 |
| `W`, `H` | World fitting window and imagined horizon | 8, 32 |
| `k`, `d` | History length and observation width | 10, 93 |
| `G` | Encoded goal input width, `73 × goal_frames` | 730 |
| `C` | Critic input width, `142 + 3T + G` | 914 for `T = 14` |
| `U`, `J`, `T` | All kinematic bodies, jointed nonroot bodies, tracked bodies | Must come from the verified kinematics, not a guessed G1 body count |
| `P` | Number of model parameter values | 18,083,716 |
| `Σw`, `Σp`, `Σc` | Sums of world, policy, critic hidden widths | 6144, 3840, 384 |

Unless stated otherwise, formulas count payload bytes with FP32 = 4, Int64 = 8 and Bool = 1. They do not include tensor/graph object headers, allocator size classes, CUDA alignment, fragmentation, library workspaces, or simulator memory. A narrow view keeps its entire underlying allocation alive: accounting must deduplicate by storage, not sum view `numel()` or tensor handles.

The preserved model state floor is `16P` for parameters, parameter gradients, and two Adam moments. Frozen networks do not add another copy of parameters. Normalizers, immutable geometry tensors, optimizer bookkeeping, and temporary gradients are separate. The current planner adds 0.5 GiB to `16P`; this review does not remove that allowance.

## Current rejection mechanism

At the reviewed widths, [plan.mbt](../src/learning_native_admission/plan.mbt) computes:

```text
actor_graph_per_step
  = max(262144, 32 × (Σw + 2Σp + Σc + kd + G + 256))
  = 515968 bytes per row per imagined step

actor_graph(m) = m × H × 515968
actor_device_work(m) = 1529987072 + actor_graph(m)
cached_workspace(m) = 2 × max(device_phase_work) + 268435456
```

The actor phase is the device maximum in these three configurations. Its 1,529,987,072-byte constant includes the logical policy payload, concatenation allowance, two detached critic inputs, and critic miscellaneous data. This is the existing formula, not a newly derived live-storage bound.

| Active microbatch | Actor graph estimate, bytes | Retained device cache estimate, bytes | Initial fresh-run peak, bytes | Initial required free bytes at 80% plus 16 GiB reserve |
| --- | ---: | ---: | ---: | ---: |
| 256 | 4,226,809,856 | 11,782,029,312 | 59,399,532,656 | 76,579,401,840 |
| 512 | 8,453,619,712 | 20,235,649,024 | 67,853,152,368 | 85,033,021,552 |
| 1024 | 16,907,239,424 | 37,142,888,448 | 84,760,391,792 | 105,950,489,740 |

These figures use the micro256 report's initial metadata bounds and change only both microbatch sizes. After the catalog is read, its verified sampler count reduces this particular plan by 3,623,829,720 bytes. Even the post-catalog 1024 plan requires 101,420,702,590 bytes under the 80% policy. These are deterministic planner calculations, not forecasts from observed peaks.

The independent save phase remains:

```text
save_archive_bound = 3 × 512 MiB = 1.5 GiB
archive_work = 6 × max(save_archive_bound, 16P) + 1 GiB = 10 GiB
save_optimizer_archives
  = common retained costs + replay capacity + archive_work + archive file cache
```

`Learner::save_optimizers` calls the three saves sequentially; `mr_adam_checkpoint` destroys its local archive objects before returning. Thus three serializers are not simultaneously active. It does **not** follow that process memory returns to its previous level: the C++ allocator may retain memory, serialization can make internal copies, and file cache remains a different cost. The 6× estimate cannot be replaced with 2× merely from this call ordering. The 24 GiB physics floor, 4 GiB reference reserve, and CUDA cache retention also remain independent of actor host staging.

The actor CPU change visible in the reviewed tree changes the compatibility-object term from `Bp × (k+1) × 128 KiB` to at most `256 × (k+1) × 128 KiB`, plus compact selected indices and existing block staging. At `Bp=4096,k=10`, that term falls from 5.5 GiB to 0.34375 GiB. It is a real host bound improvement, but `save_optimizer_archives` is still the largest phase; its peak above is unchanged.

## Proven storage and lifetime facts

| Implementation fact | Accounting consequence | Local source |
| --- | --- | --- |
| `Network::frozen` uses `stop_gradient` | Frozen parameters share persistent storage; gradients through network inputs still exist | `networks.mbt:115` |
| Adapter `stop_gradient` is `detach()`; generic `detach` is `detach().clone()` | These two API names have different storage behavior; do not merge them in a ledger | `adapter.cpp`, unary op dispatch |
| Chunk slicing uses `narrow` | Full logical batch storage remains resident despite smaller chunk views | `actor_microbatch.mbt:17`, `microbatch.mbt:29` |
| Every chunk calls backward before returning | No previous chunk's saved activation graph is needed by the next chunk | `actor_microbatch.mbt:141`, `microbatch.mbt:81` |
| Default backward does not retain the graph | Autograd's saved variables are released as backward completes; explicit output tensors can still remain alive until their owning scope ends | `learning_tensor/tensor.mbt`, `adapter.cpp:167` |
| Actor tail is evaluated once after the `H`-step loop | Count one differentiable frozen critic and one tail feature construction per chunk, not `H` copies | `actor_microbatch.mbt:129` |
| Critic inputs are constructed after actor backward from detached states | Separate this no-gradient feature phase from the peak saved actor graph; explicit state/action outputs may overlap it | `actor_microbatch.mbt:142` |
| Detached chunk critic inputs accumulate until reassembly | Chunking does not eliminate logical-batch critic storage | `actor_microbatch.mbt:183` |
| Reassembly allocates the joined input before clearing chunk arrays | Both old chunks and the joined input coexist briefly; similarly for rewards/failures | `actor_microbatch.mbt:227` |
| Critic normalizer and bootstrap use all reconstructed rows | Critic transient storage is not bounded by actor `m` | `actor_microbatch.mbt:318` |
| Critic backward/Adam runs once per minibatch; only detached losses accumulate | Do not multiply one critic activation graph by 20 updates; retained metric scalars are capped at 256 before readback | `actor_microbatch.mbt:343` |
| World/actor metrics retain three detached scalars per chunk | Count small scalar allocations and one stack/readback; not an entire retained graph | both microbatch files |

The absence of retained saved variables is narrower than “everything from the graph is freed.” `states`, `actions`, concatenated states, rewards and failures still own result storage while in scope. Detaching a scalar shares its scalar storage; it does not alias optimizer parameter storage because these losses are newly produced arithmetic results. Parameter in-place updates therefore do not change those saved scalar values in the reviewed paths.

## Storage sets for the MLPs

These formulas describe the main **saved activation payload**, under the reviewed operator implementation and conditional autograd saving. They are not complete memory caps. Final outputs, explicit caller-owned tensors, geometry, gradients and kernel temporaries must be added or storage-deduplicated separately.

The upstream PyTorch 2.11 derivative definitions support the following rules: matrix multiplication keeps the operand needed for each requested gradient; out-of-place ELU and SiLU keep their input; tanh/sigmoid/sqrt use their result; arithmetic retains the operands needed for its derivative; `where` keeps its condition. Shape-only operations do not generally require a second payload. The deployed report says `2.11.0`, but the exact upstream build commit is not established; a refined admissible ledger must pin or validate the actual build. [PyTorch derivative definitions](https://github.com/pytorch/pytorch/blob/v2.11.0/tools/autograd/derivatives.yaml)

| Network path | Candidate saved FP32 elements for `m` rows | Required storage interpretation |
| --- | ---: | --- |
| Trainable ELU MLP, input width `D`, hidden sum `S` | `m(D + 2S)` | Normalized first input, hidden pre-ELU input, hidden post-ELU input to the next trainable linear |
| Frozen ELU MLP with input gradients | `mS` | Hidden pre-ELU inputs; linear weights are shared persistent tensors |
| Trainable world MLP with manual LayerNorm, `Lw` hidden layers | `m(133 + 4Σw + Lw)` | First normalized input; each layer's centered input, normalized input to trainable scale, SiLU input and output, row standard deviation |
| Frozen world MLP with input gradients | `m(2Σw + Lw)` | Each layer's centered input, SiLU input, row standard deviation; frozen scale/weights share storage |
| Both trainable policy MLPs plus encoder tanh result | `m(G + 2Σp + 32 + kd + 2Σp + 32)` | Encoder and decoder are separate parameter sets; tanh result is also decoder input data after concat |
| One frozen tail critic | `mΣc` | One call after the horizon, not one call per imagined step |

For the reviewed widths, the trainable world candidate is `24712m` floats, the frozen world candidate is `12291m`, both policy networks and tanh are `17084m`, and the tail critic is `384m`.

LayerNorm here is **not** an opaque fused LayerNorm operator. [Network::forward](../src/learning_aligned_gpu/networks.mbt) explicitly computes mean, subtraction, square, mean, epsilon addition, square root, division, scale, bias, and SiLU. A saved tensor used by several of these operators is one storage allocation. Conversely, the normalized tensor required for trainable scale gradients is a distinct allocation. The arithmetic must follow this implementation rather than a generic “MLP activation factor.”

The frozen formula requires actual conditional saving for frozen weights/scales to be verified against the built autograd operations. A conservative intermediate implementation may keep the trainable storage set for frozen calls; it must not quietly rely on an unverified smaller set. World input/output normalization also creates standard deviation vectors of widths 133 and 70; these can be retained for input gradients and output scaling. The world error standard deviation is shared across the `W` steps of one chunk. Policy history normalization adds a width-`d` vector per call when input gradients are required. These small vectors are distinct from the row-scaled terms above.

One useful cross-check is the volume of all explicit forward operation results, **not their simultaneous peak**. Counting the local adapter's unfused `affine` as multiply plus add gives:

```text
world forward results, in FP32 elements:
  m × (8Σw + 5Lw + 4×70 + 2×133) + 3×(133+70)
  = 49713m + 609

policy forward results, in FP32 elements:
  m × (2G + 6Σp + 4×32 + 3kd + 2×29) + 3×(G+d)
  = 27476m + 2469
```

The world expression includes both normalizations; the policy expression includes both MLPs, goal/history normalization, latent tanh and decoder concat. Its `4×32` comprises the encoder linear's two results, tanh, and the latent contribution to the decoder concat.

These counts are suitable as operation-ledger cross-checks. They omit internal ATen packing, algorithm workspaces and backward operations, so they must never be presented as total allocation or peak bounds.

## Geometry must be parameterized by the full model

`Context::forward` loops over **every** kinematic body before selecting tracked bodies (`context.mbt:122`, then `:171`). Both the reward and critic feature builder call it twice, for state and reference. Even though critic features only consume body positions, the current implementation also computes rotations and velocities. Counting only 14 tracked bodies underestimates this work.

The existing planner accepts the G1 dimensions and bounded network widths but has no `U` or `J` term. `Context::new` validates parent ordering, joint indices, and tracked indices; it does not cap total bodies. A future tighter geometry formula must bind verified `U,J,T`, topology/geometry identity, supported strides, dtype and observation mode. An unknown geometry must not acquire the refined admission path. Either retain an explicitly conservative supported-profile path with its own validated bounds or reject the unsupported refinement; the old heuristic is not a proof for arbitrary kinematics.

For each FK call with `R` rows, a directly checkable forward-result tally is:

```text
F_fk(U,J) = 66 × (U-1-J) + 159 × J   FP32 elements per row
explicit FK result volume = 4R × F_fk(U,J)
```

This sum counts every explicit forward result, even ones already dead, and therefore overcounts simultaneous explicit result storage. It excludes internal matmul copies/workspaces and all backward outputs. The root aliases the input state. A fixed child contributes position 6, offset rotation 9, pivot 6, zero joint velocity 6, linear velocity construction 36, and angular velocity 3 elements. A jointed child additionally builds its axis-angle matrix and pivot correction; the actual source tally is 159. Immutable per-body constants contain 15 floats, plus the shared 87 default/limit values.

The geometry ledger must also cover, separately:

| Call site | Rows | Required paths |
| --- | ---: | --- |
| World model input | `m`, each of `W` or `H` steps | Invariant features, yaw frame, normalized context, concatenation |
| World integration | `m`, each step | SO(3) exponential, frame transforms, six state outputs |
| World fitting error | `m`, each of `W` steps | Target quaternion conversion, frame transforms, SO(3) logarithm, normalized squared error |
| Actor reward | `Hm` | Two full FK passes, tracked position/orientation/velocity errors, root terms, joint limits, action regularization |
| Actor soft failure and objective | `Hm`, then `H` sequential reductions | Relative height/tilt, sigmoid, survival products and discounted objective |
| Differentiable actor tail features | `m`, once | Two full FK passes, relative tracking features and concatenated goal |
| Detached critic feature assembly | `(H+1)m`, after actor backward | The same full FK operations without a saved gradient graph |

Two concrete aliasing traps prevent a blanket “reshape/view is free” rule:

1. `mat_to_6d` narrows a contiguous `[R,3,3]` tensor to its first two columns and reshapes to `[R,6]`. The row gaps make the six entries non-viewable as one flat dimension; the ordinary contiguous-input case allocates `6R` floats. Other reshape calls require stride-specific treatment, particularly `entry` on a matrix that may be transposed.
2. Batched matmul can expand or pack broadcast/noncontiguous inputs internally. Public result dimensions alone do not bound this internal storage. The implementation must pin the supported dispatch/layout or retain an independent workspace allowance. [PyTorch matmul implementation](https://github.com/pytorch/pytorch/blob/v2.11.0/aten/src/ATen/native/LinearAlgebra.cpp)

The adapter's `affine(x,a,b)` evaluates `x*a+b`, producing two results even when a scalar is zero or one; it is not an allocation-free fill or fused kernel. `select_where` arguments are computed before selection: both small-angle and general branches of the rotation functions incur work. Their branch predicates and saved arithmetic operands belong in the geometry graph ledger. Transcendental and matrix backward implementations, including gradient accumulation, remain a distinct unresolved part of the complete peak bound. [PyTorch manual backward implementations](https://github.com/pytorch/pytorch/blob/v2.11.0/torch/csrc/autograd/FunctionsManual.cpp)

## Phase equations for a replacement ledger

Use storage sets or conservative disjoint categories, not a sum that counts the same state tensor as both a saved input and an explicit output. Let:

```text
L = full logical policy payload = 509362176 bytes in the reviewed case
I(x) = 4 × (H+1) × x × C
F(x) = 2 × 4 × H × x            # detached rewards and failures
I(Bp) = 494174208 bytes
```

`L` includes full references, goals, noise, start data and critic permutations. It remains resident while chunks run. The five epoch orders have `5HBp` Int64 entries; they are not regenerated by actor chunks.

For chunk `j`, with `p_j` already completed rows and `m_j` active rows:

```text
actor forward/backward phase:
  persistent + L + I(p_j) + F(p_j)
  + unique live actor chunk storage(m_j, H, geometry)
  + backward transient/workspace

post-backward detached feature phase:
  persistent + L + I(p_j) + F(p_j)
  + explicit chunk state/action/reward roots still alive
  + detached feature construction peak((H+1)m_j)

reassembly phase:
  persistent + L + 2I(Bp) + 2F(Bp) + concat workspace

critic phases:
  persistent + L + I(Bp) + F(Bp)
  + max(normalizer/whole-input bootstrap, one trainable minibatch and GAE live data)
```

Take the maximum of these phases, accounting for each phase's actual overlapping roots. In particular, do not add the maximum actor saved graph to detached feature building and two whole critic inputs if they occur at different times. On the other hand, `loss.backward()` does not kill explicit `states`, `actions` or reward tensors before detached feature construction; those must remain in the second phase.

The six state outputs have total width 76 (`p3,R9,v3,w3,q29,qd29`). The initial flat state is width 71 and its views retain their original backing allocation; rotation is a separate width-9 result. `concat_states` allocates all six fields. History updates concatenate a new `k×d` row, and earlier policy inputs can retain earlier histories. Actions and `previous_actions` frequently alias the same action storages; do not charge two independent action arrays without checking the reference relation.

Critic normalizer update and frozen bootstrap operate on `R=(H+1)Bp` rows. With detached input and detached parameters, the bootstrap has no differentiable graph, but normalization and hidden layer results still allocate. The trainable minibatch is `ceil(HBp / critic_minibatches)=32768` rows here, independent of actor `m`. The 5×4 update schedule repeats that working set; it does not keep 20 simultaneous graphs. GAE tensors, targets, index-selected copies, optimizer/clip temporaries and pending metric scalars remain explicit items.

For world fitting, use a full logical world payload plus **one** `W`-step chunk graph, target/error geometry, backward temporaries, and scalar metrics from earlier chunks. Accumulated parameter gradients persist between chunks. Ten world updates are sequential, so their graphs are not tenfold resident.

After computing payload live sets, retain separate allowances for CUDA allocator rounding/fragmentation and retained cached blocks, C++/MoonBit allocator retention, APIC physics, library workspace, NCCL when enabled, reference loading, and archive/file-cache phases. Shared physical memory on Spark does not make Torch-reserved, cgroup memory and CUDA free disjoint quantities that can simply be added.

## What is established and what is not

| Status | Item | Consequence for a smaller admission estimate |
| --- | --- | --- |
| Source-established | One graph per chunk; frozen parameter sharing; tail once; critic updates sequential | Can restructure phases without changing learning math |
| Source-established | Exact logical-batch dimensions and detached critic payload | Can replace blanket duplication with phase-specific simultaneous copies |
| Source-established | Full FK traversal and non-view 6D reshape | Must be added to any refinement; these are potential undercounts, not reasons to lower a bound |
| Conditional on pinned autograd/build | Smaller saved sets for frozen linear/LayerNorm paths | Validate before taking credit; trainable saved sets can be a conservative interim choice |
| Incomplete | Geometry backward payload, matrix packing, gradient accumulation and optimizer scratch | Keep explicit residual allowances; no new complete upper bound is claimed |
| Intentionally conservative, not proved worst case | 2× device cache, 6× archive workspace, physics/reference floors | Do not rescale from one observed run or remove because a particular phase is small |
| Not proved by this audit | Peak at micro1024, long-run fragmentation, OOM absence, convergence or numerical equivalence | No automatic 1024 launch or result claim |

## Minimal reviewable follow-up

1. Add a pure, versioned graph-ledger helper alongside admission. Inputs should include verified geometry dimensions/identity, actual execution path, dtype, widths, horizons and supported layout/backend identity. Use checked integer arithmetic and reject unsupported refinements. Produce named terms and phase maxima in the report; leave the existing formula active until the residual terms are justified.
2. Separate actor graph, post-backward detached feature construction, reassembly, critic normalization/bootstrap and critic minibatch phases. Keep full logical payloads and original math/order. Give tail features/critic their own once-per-chunk term. Do not modify batch sizes, GAE, Adam or loss normalization as part of accounting.
3. Add narrow structural CPU tests for storage aliasing versus copies, the non-view reshape, ragged final chunks, frozen parameter sharing, one-tail scaling, graph release between chunks, and unknown geometry rejection. These validate structural claims, not GPU workspace bounds or training equivalence.
4. If additional instrumentation is needed, record tensor storage identity, allocation bytes, offset, strides, dtype and requires-grad status at adapter boundaries. Use non-owning/weak bookkeeping so the diagnostic does not itself retain graphs. Internal `affine` intermediates and ATen internal allocations require separate observation; recording only returned tensors is incomplete. Do not read tensor payloads for this accounting task.
5. Preserve independent allocator/library/physics/archive allowances until their own implementation or allocator constraints justify a change. A revised graph ledger can reduce unjustified activation duplication without implying that all remaining coefficients are proven caps. Re-run fresh actual-free admission before any larger candidate; boundary telemetry and the 16 GiB reserve are safeguards, not continuous monitoring or an absolute OOM guarantee.

## Measured evidence and throughput implications

The local [micro256 training report](../output/spark-runtime-20261024/paper-batch-sweep-evidence-20261024-a/cases/micro256/train/report.json) and [phase report](../output/spark-runtime-20261024/paper-batch-sweep-evidence-20261024-a/phase-report-micro256.json) record 10 completed iterations and checkpoint publication; Docker exit was 0 with `OOMKilled=false`. The reported Torch allocated window peak is 2,337,255,936 bytes, reserved peak 4,009,754,624 bytes, and minimum boundary-observed CUDA free is 83,150,860,288 bytes. These counters are not the complete external physics memory peak, nor a continuous CUDA-free minimum. The report's cgroup observations must not be added to Torch-reserved or subtracted again from CUDA free.

Excluding the first iteration, mean synchronized wall times are 3,887 ms for ten world updates, 6,348 ms for actor plus twenty critic updates, and 539 ms for collection/other inter-iteration work. They correspond to roughly 36%, 59% and 5% of those measured stages. Thus the useful next throughput question is how larger admitted chunks change model/geometry work and launch overhead. This evidence does not identify CPU collection as the main bottleneck.

The adapter still performs a finite-gradient `.item<bool>()` synchronization at each optimizer step, and clipping may introduce further synchronization. Eager scalar geometry also launches many small tensor operations; increasing `m` reduces chunk call count but does not remove the per-step operator count or the 20 critic optimizer updates. GEMM utilization, kernel launch gaps and host dispatch need their own profiler evidence before promising speedups. Keeping memory occupied is not itself a throughput metric.

## Reviewed source identities

The tree is shared and work continues in adjacent runtime/admission files. These hashes identify the reviewed source snapshot; the micro256 report identifies its own earlier executable and tensor library. No equivalence between those source snapshots is implied.

```text
9c3d9f64b4f27292ec17a0f5ea9addbf6bd8b3776c9eae538ae86bbdbd40d90e  src/learning_native_admission/plan.mbt
c39703607c47e406af91eb1708bf1334f4690355b754850624c54df434c8372b  src/learning_aligned_gpu/actor_microbatch.mbt
0d6591f665be8ed4064707ce48e2698c05bad59abc0c90d581a24c0be4675af6  src/learning_aligned_gpu/microbatch.mbt
78a908cac8fc70aa8749db38eab9c4a2d418b8b19b8f5e2d286358acbe5afb96  src/learning_aligned_gpu/networks.mbt
d3140e91de85d943e024aa43dfca1e190b76d6b1ce5d0ad89d2b86ca86ef3b4f  src/learning_aligned_gpu/geometry/state.mbt
0011b8949f4b81ef44ffb6598d9e89320590402620d574af202ab283e5c37111  src/learning_aligned_gpu/geometry/rotations.mbt
061098cc9849e11ad350a2d10cf2ae35d700e5a5aa581216447c95cd66951dff  src/learning_aligned_gpu/geometry/context.mbt
bd8431cb6d54b1d643f58477cc697a5a269992ea4315fc9f680ead9ef22c53de  src/learning_tensor/adapter.cpp
```
