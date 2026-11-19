# Native full-batch memory admission audit — 2026-10-24

The reported approximately **186.7 decimal GB** rejection is a conservative
planning envelope, not an observed native allocation peak. This audit does not
authorize full actor batch 4096, change admission coefficients, or start a GPU
job. The retained rejected configuration is
[native-config-full4096-rejected.json](../output/spark-runtime-20261024/smc-native-aligned-20261024-a/native-config-full4096-rejected.json).

The subsequently archived [actual preflight output](../output/spark-runtime-20261024/smc-native-validation-20261024-a/native-full-preflight/stdout.log)
confirms **186,719,444,880 B**, with `save_optimizer_archives` the largest phase.
The selected 80%/16 GiB-reserve decision allowed **66,371,747,840 B**, using
83,551,617,024 B actual CUDA free and 107,176,316,928 B host/cgroup remaining.
The process exited 1 with `OOMKilled=false` and zero sampled OOM events. It
stopped at admission; it did not attempt a full4096 training update.

The current safe comparison route is logical actor batch 4096 with native
microbatch 512, explicitly recording that execution difference. A separate
comparison with actor batch 512 and no microbatching on either implementation
removes this particular difference. Neither comparison identifies language as
the sole cause of a throughput gap.

## Where the large estimate comes from

[The paper planner](../src/learning_native_admission/plan.mbt) uses configured
network widths and historical per-step allowances. For the rejected SMC99
configuration, world hidden widths sum to 6144, each policy network to 3840,
critic hidden widths to 384, history width is 990, preview width is 730, and
imagination horizon is 32.

```text
actor_graph_per_sample_per_step
  = max(262144, 32 * (6144 + 2*3840 + 384 + 990 + 730 + 256))
  = 517888 bytes

actor_graph = 4096 * 32 * 517888 = 67880615936 bytes
```

The factor 32 is an engineering allowance, equivalent to eight FP32 values per
summed feature. It is not a tensor-by-tensor account of autograd saved storage.

| Planned component for this configuration | Bytes |
| --- | ---: |
| Actor graph allowance | 67,880,615,936 |
| Full logical policy device payload | 513,490,944 |
| Largest staged concatenation allowance | 16,220,160 |
| Two full critic input buffers | 988,348,416 |
| Critic miscellaneous buffers | 17,039,360 |
| Actor device working estimate, sum above | **69,415,714,816** |
| Device cache envelope: twice maximum working estimate plus 256 MiB | **139,099,865,088** |

The last row replaces the working estimate inside each phase's shared budget;
the planner does **not** add the 69.4 GB actor estimate a third time. It assumes
the CUDA caching allocator retains memory across phases and uses a conservative
2× allowance for its working set and fragmentation. This is not evidence of two
simultaneously live actor graphs.

The remaining phase budget includes these independent allowances:

- Physics: `max(24 GiB, 3*APIC_payload + numeric_union + 1 GiB)`. The 24 GiB
  floor is constant even with N256 and a small artifact.
- Reference catalog/construction: `max(4 GiB, 16*motion_manifest_bytes)`.
- Parameters, gradients, Adam state and an allocator allowance; replay capacity,
  live history/environment and reset sampler metadata.
- Host sampling/upload work or checkpoint archive/stream publication work,
  according to the phase. Disjoint archive and sidecar phases are already
  separated; summing every phase again would be incorrect.

The exact total also depends on actual versus unknown sampler/APIC bounds,
whether restore is included, and enabled execution reserves. The approximate
186.7 GB rejection must not be used as a universal value for all B4096 runs.

The `physics_scene_reserve` field added to the compatibility report in
[cmd/memory.mbt](../src/learning_aligned_gpu/cmd/memory.mbt) is not a second
physics allocation added by `assess`: the assessed phase already contains
`physics_scene_working_floor`.

## Confirmed lifetime mismatches and their limits

**Critic hidden layers are included at every imagined step in the actor graph
formula, while the differentiable actor tail calls the critic once.** In
[learning.mbt](../src/learning_aligned_gpu/learning.mbt), the imagination loop
uses policy and frozen world networks; `tail` calls the frozen critic after the
loop. This particular structural overcount is
`31 * 4096 * 384 * 32 = 1,560,281,088 B`, or approximately 3.12 decimal GB after
the cache multiplier. Correcting it alone cannot admit the rejected run. Other
critic work and its independent phase budget must remain.

**Full critic inputs are prepared after actor backward and the policy Adam
step.** The actor working formula nevertheless combines two full critic inputs
with the complete actor BPTT allowance. Backward releases saved backward tensors,
but state/action arrays, rewards, loss outputs, and optional cached geometry can
remain referenced. A corrected planner must distinguish those retained outputs
from released saved activations. Taking `max(actor, critic)` without accounting
for retained outputs would not be justified by the current source alone.

**Post-catalog re-admission uses remaining memory after catalog loading, then
retains the complete reference/catalog allowance.**
[main.mbt](../src/learning_aligned_gpu/cmd/main.mbt) reads fresh host/CUDA
availability after the loader, while
[host_available](../src/learning_aligned_gpu/cmd/memory.mbt) already subtracts
current cgroup usage. Thus existing resident catalog/bin allocations are already
reflected in the headroom reading and are conservatively budgeted again. The
4 GiB allowance also covers construction/working storage, so the evidence does
not justify deleting that entire allowance. A future incremental re-admission
contract needs to identify existing versus future bytes explicitly.

**The largest uncertainty is the per-step activation multiplier and 2× cache
allowance.** They are documented conservative estimates, not certified bounds
or native full4096 measurements. Reducing them merely until the configuration
passes would substitute an unsupported estimate for another estimate. The same
applies to lowering the 24 GiB physics floor based only on artifact size.

## What the retained measurements establish

| Evidence | Configuration and scope | Measured quantity |
| --- | --- | ---: |
| [Original SMC run](../output/spark-runtime-20261024/smc-original-benchmark-20261024-b/README.md) | N256, full actor4096, BF16, compiled tensor paths, 600 iterations | cgroup `memory.peak` **7.50 GiB** |
| [Native series-D baseline](../output/spark-runtime-20261024/optimization-stage2-20261024-b/README.md) | N256, logical actor4096/micro512, FP32 with TF32 allowed, eager critic | allocator allocated peak **3,382,561,280 B**, reserved peak **5,085,593,600 B** |
| Same series, critic graph candidate | Same baseline configuration except graph replay | allocated peak **3,534,817,792 B**, reserved peak **9,130,999,808 B** |

These are different metrics and must not be added together. The native figures
are allocator diagnostic-window peaks; free-memory/cgroup observations are
sampled and do not certify every lifetime peak. The graph candidate's private
pool reservation was only 182 MiB, yet total reserved memory increased much
more. This demonstrates why the complete allocator lifetime matters.

SMC's full4096 result establishes that its own compiled BF16 execution fits in
that measured configuration. It does not establish a bound for native expanded
LayerNorm, FP32 eager autograd, its geometry intermediates, or native host/data
storage. The older measurements also use different observations, warmup and
other execution settings; they are not a matched memory calibration.

## Conditions for correcting the planner

Keep the original planner selectable and retain its reports. A replacement
should identify its accounting version and attach the evidence used to derive
its estimates.

1. Inventory storage by lifetime: permanent model/Adam/replay/reference/physics;
   actor saved activations; retained actor outputs; critic bootstrap; critic
   minibatch; upload construction; archive serialization; and allocator cache.
   Count aliases once and distinguish detached views from copies. Explicitly
   include geometry and optional graph/reference-cache storage.
2. Measure native execution with fixed source/plugin/image/data identities and
   the actual precision, LayerNorm, geometry, graph and microbatch settings.
   Begin with sizes admitted by the existing planner. Use allocated/reserved
   peaks and host/cgroup/free-memory observations together, retaining complete
   warmup, training and checkpoint results. Record sampling gaps.
3. Reconcile measured growth with the storage inventory before advancing batch
   size. A linear extrapolation from micro512 alone is not proof of a full4096
   bound; new workspaces, retained outputs and cache fragmentation can change.
   Any size rejected by the old planner needs a reviewed structural bound and
   a separate explicit admission policy, not an unrecorded bypass.
4. Split startup total-process admission from post-load incremental admission,
   with an explicit accounting of already resident bytes. On Spark unified
   memory, do not sum host/cgroup/device telemetry as if they were independent
   physical pools. Preserve conservative shared-memory protection.
5. Compare the revised planner against old accepted/rejected cases using CPU
   arithmetic tests, then run bounded GPU correctness and memory gates. Only
   complete paired throughput runs enter performance summaries; refused or
   guard-stopped runs remain retained evidence rather than surviving samples.

The current execution bounds remain: **100 GiB cgroup, zero container swap,
12 CPUs, host MemAvailable at least 24 GiB, host MemFree at least 12 GiB, and
at least 16 GiB CUDA free**. The existing guard also stops before cgroup usage
exceeds its 84 GiB threshold. `assess` retains the selected 65–80% budget and,
when explicitly selected, the independent 16 GiB free reserve. Monitoring does
not guarantee that every instantaneous peak is observed and does not replace
pre-allocation admission.

The initial audit above changed documentation only. The follow-up below records
the separately authorized narrow implementation.

## Follow-up: opt-in serial optimizer save accounting

On 2026-10-24, the matched N256/full-actor512 run was rejected before training:
available CUDA memory was 81,920,348,160 bytes, the existing 80%/16 GiB-reserve
policy permitted 64,740,478,976 bytes, and the old plan estimated 65,241,943,952
bytes. This was an admission refusal, not an OOM.

`serial_optimizer_save_workspace: true` now selects a save-only lifetime
correction. Its default remains false, retaining the old plan. The caller must
also select paper capacity, explicit `memory_admission_percent` and CUDA memory
telemetry. No batches, network widths, numerical operations or training updates
change. The native baseline and candidate must use the same value in paired runs.

The source lifetime is explicit: `Learner::save_optimizers` calls the world,
policy and critic saves synchronously, and `mr_adam_checkpoint` owns its two
`OutputArchive` objects on the stack of each call. The policy archive includes
both the encoder and decoder. Thus only one save's temporary archive objects
are live at a time. PyTorch 2.11's [OutputArchive implementation](https://raw.githubusercontent.com/pytorch/pytorch/v2.11.0/torch/csrc/api/src/serialize/output-archive.cpp)
calls `ExportModule` synchronously; the [serializer](https://raw.githubusercontent.com/pytorch/pytorch/v2.11.0/torch/csrc/jit/serialization/export_module.cpp)
writes records inside that call and obtains each tensor's writable storage in
the record loop. [Writable tensor conversion](https://raw.githubusercontent.com/pytorch/pytorch/v2.11.0/torch/csrc/jit/serialization/pickler_helper.cpp)
copies non-CPU storage to CPU for serialization. These source facts support
accounting for the largest individual save rather than all three concurrent
save workspaces. They do not prove that process RSS immediately falls after
destruction: allocator arenas can retain freed blocks.

| Save estimate component | Original | Opt-in |
| --- | ---: | ---: |
| Parameter values used for workspace sizing | All 18,206,596 | Largest optimizer: policy 9,116,477 |
| Archive limit used for workspace sizing | 3 × 512 MiB | 512 MiB |
| Workspace formula | `6 × max(1.5 GiB, total_parameters × 16) + 1 GiB` | `6 × max(512 MiB, largest_optimizer_parameters × 16) + 1 GiB` |
| Save workspace | 10 GiB | 4 GiB |
| Complete archive file cache | 1.5 GiB | 1.5 GiB |
| Pinned fresh-run peak | 65,241,943,952 B | 58,799,493,008 B |

The estimate retains the 6x plus 1 GiB margin. It also retains all three file
limits, all archive file cache, original optimizer restore estimates, live
parameters/Adam state, device-cache envelope, physics floor, unknown sampler
upper bound and every existing guard. Optional execution reserves still add
to every phase without discount. At the refused run's memory reading, the new
baseline leaves 5,940,985,968 bytes below the same budget; a test with an added
4 GiB candidate reserve remains admitted. Full-actor4096 remains far above the
same budget; this correction is not evidence that it fits.

CPU validation passed 38/38 narrow tests, including exact original/default-plan
identity, unchanged non-save phases and restore diagnostics, unchanged disk and
file-cache limits, strict JSON opt-in and inference projection, exact pinned
512-batch estimates, and rejection one byte below either required host or CUDA
free threshold. `moon info` and `moon fmt` completed successfully. These tests
allocate no training tensors and do not run CUDA or physics. GPU checkpoint
lifetime and guard observations remain runtime evidence to collect; passing
the estimate is not a guarantee against unobserved instantaneous peaks.
