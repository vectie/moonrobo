# Python / MoonBit parallel migration

The baseline contains **125 Python files, 17,848 lines, including 42 test files** in `providers/motion_learning` and `bridges/sdk_e1`. Dependencies, build outputs and archived experiment copies are excluded. All Python sources remain in place. Historical experiment launchers are preserved byte-for-byte in `scripts/python_reference/`, with SHA manifests, and can be selected explicitly through `scripts/run_python_reference.mbtx` for later comparison.

This is an additive migration in progress. **It is not a completed replacement of all Python programs.** The new packages contain actual numerical implementations and native adapters; having a corresponding package does not mean every experiment entry point or test has been ported. The inventory deliberately marks every source as partial/unverified until the complete behavior is compared.

The active experiment entrypoints and E1 collector/writer now default to MoonBit/native adapters. See [runtime, build-time and reference Python dependencies](PYTHON_DEPENDENCIES.md) for the reviewed command graph and remaining interpreter requirements. Native source gates and checkpoint conversion retain the actual source and file identities; changing an extension cannot turn a Torch checkpoint into native JSON.

## Package ownership

| MoonBit package | Responsibility |
| --- | --- |
| `src/learning_numeric` | Reverse-mode AD, dense networks, normalization, Adam, portable RNG |
| `src/learning_artifacts` | WindowBatch JSON/gzip/shards, SHA256, NPY/NPZ, versioned JSON checkpoints, artifact comparisons |
| `src/learning_training` | Residual/root-integrated dynamics, actor/critic, imagined rollouts, PPO, cloning, replay/refit |
| `src/learning_aligned` | Rotations, FK, motion resampling, observations/rewards, buffers/sampling, aligned models and training |
| `src/learning_balance` | Balance observations, causal histories, feedback fitting, teachers and full-body reference features |
| `src/learning_temporal` | Temporal actor/value models, imagined training, PPO and physical episode adapters |
| `src/learning_reference` | Reference actor/value, tracking rewards, initialization, training and diagnostics |
| `src/learning_reference_directions` | Open-loop action tapes and closed-loop feedback counterfactual studies/exports |
| `src/learning_reference_routes` | Gradient routes, final-cycle optimizer forks and tail directions |
| `src/learning_reference_roots` | Paired root integration fits, directional physics and prefix/tail decomposition |
| `src/learning_physics` | Native MuJoCo runtime, exact integration-state snapshots, rollout and dataset collection |
| `src/learning_probes` | Return metrics, gradient/action directions, model summaries and physical diagnostics |
| `src/learning_comparison` | Common-scale held-out comparison across initial/refitted models |
| `src/learning_registry` | Sustained-balance recorded-physics registry export with proof/hash checks |
| `src/learning_calibration` | Training-only coupled-noise exploration calibration and recorded PPO verification |
| `src/learning_refinement` | Full temporal refinement and alternating value-calibrated training studies |
| `src/learning_studies` | Learned/sustained balance train-only fitting, selection and long-duration studies |
| `src/learning_torch_rng` | Optional native ATen CPU generator adapter for strict legacy seeded audits |
| `src/sdk_e1_native` | E1 fixture/live bridge, SDK native adapter, command validation and watch behavior |

Package `MIGRATION.md` files document detailed mappings and remaining work. [The source inventory](PYTHON_MIGRATION_FILES.md) lists every original, its owner and line count; [the JSON baseline](PYTHON_MIGRATION_INVENTORY.json) also records the original SHA256.

## Compatibility boundaries

The initial numerical backend uses CPU `Double` arrays and a MoonBit RNG. PyTorch commonly uses float32 and different random generators. Same seed does **not** imply the same weights, samples, optimizer history or learning curve. Compare fixed weights and shared sampled inputs first; compare training distributions separately.

New MoonBit checkpoints use `moonrobo.moonbit-checkpoint.v1` JSON. Legacy dense numeric Torch ZIP checkpoints can be read through a restricted data-only pickle interpreter and explicit model adapters. The reader also supports the primitive C-order NumPy ndarray pickle state used by aligned MuJoCo environment snapshots. This does not support arbitrary Python objects or execute pickle callables. The original migration snapshot only type checked these generic importers and adapters; compatibility with the full existing checkpoint collection remains unverified. Preserving optimizer/RNG state is the responsibility of each model's checkpoint wrapper; a generic tensor checkpoint alone is not evidence of resumable training. Aligned legacy weight import explicitly starts fresh optimizer/replay/RNG/physics state. A separate native CUDA learner later completed a short exact checkpoint continuation; that result does not validate generic legacy import.

NPY supports C-order numeric float64/float32, selected integer and boolean dtypes. NPZ supports stored/deflated entries with CRC verification, including ZIP64 directory metadata within addressable byte-array sizes. Output archives use float64 and stored members. Pickle/object NPY arrays, Fortran order, big-endian arrays and integers outside exact Double range are rejected. Gzip input supports a single member with no trailing data and a 1 GiB decompressed size limit. Native decompression requires zlib headers at build time and a system zlib shared library at runtime.

The migration targets the repository's preferred **native** backend. Browser/Wasm support is not established. MuJoCo requires matching native headers and shared library; the adapter checks their versions. A build without MuJoCo headers reports the missing dependency when opened. SDK live mode requires a separately built C++ adapter and the vendor SDK/DDS runtime. No **robot hardware** execution was performed. The aligned package now contains a four-graph native Warp APIC replay adapter and a MuJoCo-to-USD converter; their source/build boundaries are documented in `src/learning_aligned/MIGRATION.md`. The offline APIC producer still embeds CPython for pinned vendor model construction, kernel/JIT and capture. Native CUDA learner, small DDP gates and a single-host native APIC GPU physics/CUDA learner iteration have passed on Spark. Upstream differential equivalence remains unverified; the independent SDK numerical check retains a failure.

Legacy seed-law audits can explicitly use the optional native ATen CPU generator adapter, compiled against a matching LibTorch distribution. It does not start Python. This preserves the native RNG implementation for those audits; it does not make Double network arithmetic identical to Torch float32. Missing adapters or failed strict comparisons remain errors.

## Verification status and remaining comparisons

The original source-porting snapshot deferred Python/MoonBit tests, training, simulation and hardware runs. Later work on 2026-10-24 did execute narrow runtime gates on the Spark machines. The [Python two-node DDP report](../output/spark-runtime-20261024/report.json) records one 128-environment-per-rank learning iteration on the 40-motion LAFAN1 catalog, with a checkpoint. The [native single-host CUDA gate](../output/spark-runtime-20261024/native-cuda/runs/g1-native-cuda-gate-179-v3/report.json) records a 2-environment Float32 CUDA learner using CPU MuJoCo physics, resumed to iteration 2 with `resume_kind=exact`. Separate [native DDP rank-0](../output/spark-runtime-20261024/native-ddp/178/runs/native-ddp-gate-20261024-c/rank-0/report.json) and [rank-1](../output/spark-runtime-20261024/native-ddp/179/runs/native-ddp-gate-20261024-c/rank-1/report.json) reports record one synchronized iteration with 2 environments per rank. Each rank performed 36 physical and 64 imagined transitions and one model, one actor, four critic update operations; summed work is 72/128 transitions and 2/2/8 rank-local operations, not two synchronized iterations. Both DDP containers exited 0 with `OOMKilled=false`; logs show NCCL `NET/IB`, `GDR 0`. The native gates used 16 GiB container caps without measured peak memory. On 178, the full 142,220-clip, 124,554,605-source-frame BONES-SEED G1 conversion is complete but still unfiltered. These are integration gates, not full BONES-SEED training, parity with all Python behavior, convergence, native GPU physics or cross-host checkpoint resume. The native reports' `hardware_execution=false` concerns robot hardware and does not negate CUDA learner execution.

Later gates supplement those initial results: the [native DDP repeat](DGX_SPARK_CONNECTX7_RDMA.md) measured cgroup peaks of 3,062,317,056 / 3,065,729,024 bytes and verified saved parameters, Adam and normalizers against held-state attestations. The [single-host APIC GPU physics/CUDA learner](DGX_SPARK_APIC_EXPORT_PLAN.md) completed two environments and one iteration with 36 physical / 64 imagined transitions and 1/1/4 updates, then passed CPU checkpoint readback. Its observed kernel peak was 2,588,884,992 bytes, without a certified final lifetime peak. Neither run observed OOM. The original APIC/SDK numerical failure is retained; the successful execution does not establish physical equivalence, convergence or full-corpus training.

`scripts/finalize_python_migration.mbtx` performs native package and standalone-entrypoint type checking, interface generation, formatting and metadata-only dependency auditing, then records source/interface/config/fixture hashes and toolchain version in [the native inventory](MOONBIT_MIGRATION_INVENTORY.json). It never starts a test or experiment. Original CPU test contracts are represented as pending MoonBit test source; package test-source audits describe their mappings and external-runtime boundaries. Postponing execution does not remove tests from migration scope.

Preserve the Python baseline before comparisons:

```console
moon run scripts/python_migration_inventory.mbtx . --verify
```

When broader machine time is available, run the selected packages' tests and then compare common exported artifacts. Native physical fixture tests require `MOONROBO_MUJOCO_LIBRARY` pointing to the matching shared library, real G1 assets and headers visible when compiling the adapter. Reference fixtures optionally accept `MOONROBO_G1_SCENE`. Missing physical dependencies fail explicitly. For example:

```console
moon test src/learning_numeric src/learning_artifacts src/learning_training src/learning_aligned src/learning_balance src/learning_temporal src/learning_reference src/learning_probes --target native
moon run cmd/learning_compare -- python-export.npz moonbit-export.npz 1e-6 1e-5
```

The comparator supports JSON, NPY and NPZ, uses `abs(candidate-reference) <= atol + rtol*abs(reference)`, and fails on shape/field mismatches or nonfinite numbers. JSON comparisons should use the same exported schema. Checkpoint files from different formats cannot be compared directly.

Recommended differential order: rotations/observations and reward → fixed-weight network inference → shared-batch loss/gradients/Adam → native reset/step/integration restore → short training/resume → full experiments and report/registry exports. Passing type checks does not establish any of these equivalences.
