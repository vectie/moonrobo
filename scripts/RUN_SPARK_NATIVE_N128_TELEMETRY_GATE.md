# Frozen N128 telemetry gate

`run_spark_native_n128_telemetry_gate.mbtx` is a separate diagnostic launcher.
It preserves the original `run_spark_native_n128_gate.mbtx` and all old evidence.
No GPU, SSH, Docker deployment, or host configuration occurs during its CPU
self-test. Build it as a native Linux executable:

```text
moon build --target native --release scripts/run_spark_native_n128_telemetry_gate.mbtx
moon run --target native --release scripts/run_spark_native_n128_telemetry_gate.mbtx --self-test
```

Inside an already limited container, call the resulting executable with two
required arguments:

```text
HELPER /workspace/moonrobo/private/NEW_BUILD/trainer EXACT_TRAINER_SHA256
```

The trainer SHA must be the independently recorded hash of the approved new
build, not a value selected by the trainer or derived on demand to accept an
unknown executable. The launcher hashes the actual file before running it and
requires the same digest in its run identity. Both path and SHA are recorded
in `/gate/command-plan.json`. `--inside` is only its bounded watchdog child.

The host must verify the container image ID before launch:
`sha256:9d517324498da0ab109841d666bd49b9e9838bf3878e678c226c15848cbcac3b`.
The helper cannot infer Docker image identity inside the container, and labels
this as a host requirement. Mount the repository read-only at
`/workspace/moonrobo` and a **new empty** writable output directory at `/gate`.
Use CUDA device access, **64 GiB memory, zero swap, four CPUs**, and the existing
bounded N128 execution environment. It verifies these cgroup limits and zero
OOM event counters before and after work.

Fixed new tensor plugin:

```text
/workspace/moonrobo/private/native-tensor-telemetry-20261024-c/libmoonrobo_learning_tensor.so
SHA256 226e18f2cd6cbfbdfbf0a7b6faab1b8833440746eac17fd5d377205db75852d4
```

The config, original 40-LAFAN catalog, N128 genuine APIC bundle, scene, MuJoCo,
and APIC native plugin retain the original gate's exact hashes. It preserves
logical batch 128, microbatch 16, replay 256, Float32, H32/K8, one iteration,
10 world updates, one actor update and 20 critic updates. Memory admission
remains 65%, with the same 24 GiB physical reserve and exact 36,531,105,856-byte
single-process plan. There is no cap, precision, model or formula adjustment.

Both preflight and training receive `--cuda-memory-telemetry`. Preflight must
report the required diagnostic capability. The watchdog covers hashing,
preflight, training and evidence checks: 895 seconds plus at most five seconds
of termination grace. Preflight is separately bounded to 120 seconds; training
uses only the remaining allotted time. A hard timeout can leave a partial
summary, so retain the container exit and OOM state alongside its files.

The helper retains the original report/counter/actor-readiness checks and
stream-v2 receipt, sidecar and archive SHA verification. These are save/integrity
checks; an actual optimizer reload is a separate audit. It also requires:

- A complete fresh rank-0 measurement window bound to the run identity, exactly
  one peak reset and all nine ordered phase samples.
- Synchronized device-0 counters, valid current/peak/free/total relationships,
  cumulative peaks that never decrease after reset, and aggregate values
  matching the retained samples.
- The independent immutable telemetry file to equal the report's telemetry.
  Its name is confined to the validated window ID, and its SHA is recorded.
- Explicit Linux host/cgroup observation scope, with missing values preserved
  rather than converted into zero.

`/gate/telemetry-phase-comparison.json` records each phase's current and
cumulative peak counters, growth of the cumulative peak since the previous
boundary, observed CUDA free drop from the window baseline, and original host
observations. These differences are **not phase-local peaks**. Allocations
outside the allocator/pool are excluded from its counters; no external or host
values are added to manufacture a total memory peak. Root cgroup peaks may
predate the diagnostic window. Synchronization changes runtime, so the summary
explicitly disallows performance comparisons with uninstrumented runs.

The final inside summary includes the comparison, unchanged training counters,
checkpoint integrity result and cgroup peak observed before helper exit. It
does not certify SDK numerical equivalence, convergence, exact warm physics
resume, full container-lifetime memory peak or paper-exact motion coverage.

## Recorded execution on 178, 2026-10-24

Attempt `native-n128-telemetry-20261024-b` passed preflight, one real CUDA/APIC
training iteration, all nine phase checks, and stream-v2 save verification.
The [inside summary](../output/spark-runtime-20261024/native-n128-telemetry/runs/native-n128-telemetry-20261024-b/inside-summary.json)
records 8,448 physical transitions, 4,096 imagined transitions, 10 world-model
updates, one actor update, 20 critic updates and 10,240 model-fit transition
slots. No actor-readiness refill was needed. This used the unchanged 40-LAFAN,
N128/B128/microbatch-16 configuration, not the full BONES corpus or a completed
training study.

The earlier attempt `-a` remains recorded in its
[failed summary](../output/spark-runtime-20261024/native-n128-telemetry/runs/native-n128-telemetry-20261024-a/inside-summary.json).
The exact config file was absent on 178, so input validation failed **before
either preflight or training started**; both exit-code fields are `null`.
The already pinned config (`6913ba684c3f07b0398665668e9c3b3773ecdc89accd4cf4cfa50522c1aa2643`)
was copied to 178, and `-b` used a fresh output directory with unchanged limits.
The combined [Docker evidence](../output/spark-runtime-20261024/native-n128-telemetry/runs/native-n128-telemetry-20261024-b/docker-final.json)
contains both containers: `-a` exited 1 and `-b` exited 0, both with
`OOMKilled=false`. Select the container by name, not the first array element.

The successful container had 68,719,476,736 bytes of memory, four CPUs and zero
swap. Both admission plans retained the 36,531,105,856-byte estimate and
25,769,803,776-byte APIC reserve; budgets were 44,539,952,537 bytes before and
44,209,546,035 bytes after catalog preparation, each computed using the same
65% rule. The lower observed usage did not change those conservative bounds.

The [phase evidence](../output/spark-runtime-20261024/native-n128-telemetry/runs/native-n128-telemetry-20261024-b/telemetry-phase-comparison.json)
contains these selected boundaries (all values are bytes):

| Boundary | Allocated current | Cumulative allocated peak | Cumulative reserved peak | Observed CUDA free |
| --- | ---: | ---: | ---: | ---: |
| Window start after reset | 73,915,904 | 73,915,904 | 83,886,080 | 88,257,249,280 |
| Warmup complete | 82,435,584 | 92,123,648 | 115,343,360 | 87,780,835,328 |
| World updates complete | 197,493,760 | 278,041,600 | 289,406,976 | 87,152,709,632 |
| Actor/critic complete | 275,504,128 | 341,745,664 | 434,110,464 | 87,007,383,552 |
| Checkpoint complete and final sample | 275,504,128 | 341,745,664 | 434,110,464 | 86,754,131,968 |

The complete window is
`cuda-memory-1792804699434-rank-0-iteration-0`. Its allocated peak was
**341,745,664 bytes**, reserved peak **434,110,464 bytes**, and minimum sampled
CUDA free **86,754,131,968 bytes**. Peaks were reset once after initialization;
the separate pre-reset sample is also retained. All nine observations were
synchronized, with no omitted samples or host-read errors. This measures the
active allocator/pool through training and checkpoint publication, excluding
outside allocations and teardown. The CUDA free minimum is sampled, not a
continuous device-wide peak. These numbers cannot be added to host/cgroup
memory or interpreted as the total GPU memory required by the physical run.

The final in-container cgroup read and the independent
[training watcher](../output/spark-runtime-20261024/native-n128-telemetry/runs/native-n128-telemetry-20261024-b-memory/final-summary.json)
both observed a kernel memory peak of **2,346,942,464 bytes**. Observed OOM and
OOM-kill counters remained zero. The watcher had 43 samples with a known kernel
peak and one final missing sample after cgroup removal, so it explicitly sets
`complete_lifetime_peak_certified=false`. This is an observed cgroup peak,
not a certified full container-lifetime peak or a CUDA allocator peak.

A separate CPU-only decode of this exact generation also passed:
[readback report](../output/spark-runtime-20261024/native-n128-telemetry/runs/native-n128-telemetry-20261024-b/readback.json),
[readback container](../output/spark-runtime-20261024/native-n128-telemetry/runs/native-n128-telemetry-20261024-b/readback-docker-final.json),
[readback watcher](../output/spark-runtime-20261024/native-n128-telemetry/runs/native-n128-telemetry-readback-20261024-b-memory/final-summary.json).
It ran with an 8 GiB cap, two CPUs and no requested GPU; exit was 0,
`verification_passed=true` and `held_state_attestation_verified=true`.
The decoded shared-state SHA256 was
`cbb675302254ed4e16f6610636909992df6b8accc947b762ef409325ba7945e7`.
The audit decoded 218,560,088 archive bytes and 17,127,581 streamed sidecar
bytes; the separately observed cgroup peak was 586,584,064 bytes, with no
observed OOM event. Its final poll also lost the deleted cgroup, so that peak
has the same incomplete-lifetime qualification. `comparison_performed=false`:
this verifies the saved learner against this run's held-state attestation,
not equality with an older uninstrumented run or another seed.

This is a bounded execution, measurement and checkpoint-readback result. It
does not establish convergence, full training, long-run memory bounds, speed,
SDK numerical equivalence, exact physics resume or unchanged weights relative
to earlier runs. The added synchronization also precludes a performance claim
from elapsed time alone.

## Execution and source-package boundaries

The deployed binary hashes are preserved in
[runtime.sha256](../output/spark-runtime-20261024/native-n128-telemetry/runs/native-n128-telemetry-20261024-b/runtime.sha256):

| Artifact | SHA256 |
| --- | --- |
| Linux trainer | `9cc8a6159d25a54dc7b6b7fe3602aa8a08988a34da8a91bc776a814f68a814db` |
| Linux helper executable | `41e2646c23913957b1c44732f60e3496ac2e3d3bd26cf512540e87a86b3c9012` |
| Tensor plugin | `226e18f2cd6cbfbdfbf0a7b6faab1b8833440746eac17fd5d377205db75852d4` |
| Helper `.mbtx` source | `9f02c64448c8c6af042d5169f3ef5d66853d095daf9c8652fa9654de828bd945` |

The Linux trainer was an integrated build including the telemetry source
overlay and concurrent optional critic-trace/TF32 interfaces; those optional
features were not enabled by this gate. Its binary identity is therefore the
value above, not the old N128 trainer's identity. The phase gate records the
actual Float32/no-AMP training configuration, but is not a separate audit of
which CUDA arithmetic kernels ran.

The [training telemetry source archive](../output/spark-runtime-20261024/native-training-telemetry-source-20261024-a.tar.gz)
remains frozen at
`a6240594304e0fe8464f8382f04d7530aea29948089c34c3f4a2c360465fc32d`;
it is an 11-file overlay, not a complete repository or standalone reproduction
of every integrated source dependency. The two-file
[launcher archive](../output/spark-runtime-20261024/native-n128-telemetry-launcher-20261024-a.tar.gz)
remains frozen at
`b6dc280f472d4d609bed51bbdb763806b6db09f43caa4913f9084427be24584c`.
Both archives retain their original README versions. This subsequent evidence
update changes only working-tree documentation; it does not rewrite either
archive, the helper source or any original run evidence. The local evidence
copy intentionally omits large `.pt`, f64 payload and reference-cache files;
the actual CPU decoding occurred on 178 before these compact reports were
copied locally, rather than being independently repeated on this Mac.
