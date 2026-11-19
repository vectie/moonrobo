# Native paper-capacity phase admission

This package estimates the implemented native training path for an explicit
`capacity_profile: "paper-4096"` **and** `stream-v2`. It does not change the
legacy planner, allocate replay/tensors, inspect a device, select microbatching,
or authorize a remote run. `Initial` or `v1` is rejected by this API so callers
must keep the original admission path for those cases.

`plan_paper_stream(Inputs)` uses the fixed `learning_native_capacity` contract
and the same checked shape accounting as `learning_aligned_gpu/runtime`.
`assess(plan, host_remaining, cuda_free)` compares its largest phase with
`floor(0.65 * min(host_remaining, cuda_free))` by default. An explicit
`memory_admission_percent=65..80` instead uses
`min(floor(free * percent / 100), max(0, free - 16 GiB))`, where `free` is the
smaller reading. Both observations must be positive, and
`Decision.require_accepted()` fails when the estimate does not fit. Host
remaining must already include the process's actual cgroup ancestors; missing
readings must not become an unlimited budget.

`Plan.required_remaining_bytes` remains the historical 65% baseline.
`Decision.required_remaining_bytes` is the actual selected-policy requirement:
`max(ceil(peak * 100 / percent), peak + reserve)`. Decisions record the percentage,
reserve and baseline separately. Absence of the optional percentage retains the
original behavior; explicitly choosing any value, including 65, adds the 16 GiB
reserve. The native training CLI requires `--cuda-memory-telemetry` with this
option and checks actual remaining memory at sampled stage boundaries. Saved
training policies are strictly validated and preserved by evaluate/export, but
are omitted from the temporary evaluation settings copy. Reports mark
`training_memory_policy_not_applied` for an explicit source policy; inference
keeps its separate existing budget checks. These checks are not continuous
observation or a guarantee against peaks between samples.

The estimate retains the **24 GiB physics floor**, **4 GiB reference floor**,
the existing network size bounds and the existing optimizer archive bounds.
It is a conservative engineering estimate, not a certified allocation bound.
Process memory/no-swap/time limits and live observation remain necessary.

## What is counted

The replay contains 234 F64 values, two I32 values and two U8 flags per record.
At 4096 environments × 1000 rows that is 958,464,000 F64 values and
**7,708,672,000 bytes** of primitive payload. The planner adds 1024-record slab
rounding and a directory/header allowance. It does not attach the old 128 KiB
JSON/object envelope to every primitive replay record.

That 128 KiB allowance is retained for decoded compatibility samples. The native
actor sampling path selects the full logical batch as compact I32 indices, then
decodes at most `min(B, 256) * (hist + 1)` transition objects at once. For B4096
and history10 this is 2,816 live objects versus 45,056 logical objects, plus
16,384 bytes of retained selected indices. The full replay-candidate scratch
allowance is still counted conservatively. World window construction stages at
most 256 windows at once. Host upload, reference-block, noise and permutation
storage are counted separately. Caller-owned objects passed directly to
`policy_batch_from_starts` are outside this training-path lifetime claim.

Microbatch zero means the full logical batch. A nonzero microbatch reduces only
simultaneously live actor/world BPTT graphs. Full logical input tensors remain:
for SMC99 at B4096/H32 the policy counts **126,500,864 numeric values**, including
five critic permutations, and references span 135,168 frames. Critic detached
inputs, full-batch normalization/bootstrap and the original critic minibatch
schedule are budgeted independently. No critic schedule is changed here.

The device working-set estimate includes configured layer widths as well as
the retained per-step activation allowance. Twice the largest device phase plus
256 MiB is retained as a cache/fragmentation envelope in **every** subsequent
phase. This deliberately avoids assuming released graphs return their memory
to CUDA. No `empty_cache`, synchronization or telemetry counter reset occurs.

## Phase and checkpoint boundaries

By default the seven returned phases are collection, world fitting,
actor/critic, optimizer archive saving, stream sidecar publication, optimizer
restore and staged runtime/environment restore. They share live
parameters/Adam, history, environment, reference, sampler, physics and
device-cache budgets.

A fresh training launch passes `include_restore=false` with zero requested
restore rows/archive bytes and retains the first five phases, including both
save phases. Nonzero restore inputs with this flag are rejected. Resume keeps
all seven phases; even an empty replay can require optimizer restoration.
`restore_phases_included` records the choice. The CLI resolves this once from
`--resume` and carries it through initial, post-catalog and DDP-ready admission.

Archive serialization happens before writing numeric replay sidecars. Likewise,
optimizer restore precedes isolated replay preparation. Their transient work is
not summed as if simultaneously live. File cache is retained conservatively,
including complete generation verification before restore. Save still budgets
three archives at the existing 512 MiB per-file bound; a previously observed
218 MB checkpoint is not a guarantee on future serialized size.

`plan_paper_stream(..., serial_optimizer_save_workspace=true)` is an independent
opt-in correction for save-only serialization lifetimes. `save_optimizers`
synchronously saves world, policy and critic archives in sequence. Each native
save owns its `OutputArchive` on that call's stack. The policy encoder and decoder
share one optimizer, so their parameter counts are combined. The save workspace
is therefore estimated as `6 * max(512 MiB, largest_optimizer_parameters * 16)
+ 1 GiB`, rather than applying the same factor to all three archive limits at
once. Both estimates retain the complete 1.5 GiB file-cache allowance. Restore,
device cache, physics, disk limits and training math are unchanged. The default
is false and preserves the original plan.

The training JSON option of the same name additionally requires explicit
`memory_admission_percent`, `capacity_profile: "paper-4096"` and
`--cuda-memory-telemetry`. It changes an engineering estimate, not an enforced
allocator bound: host allocation arenas may retain freed memory. The 6x plus
1 GiB workspace margin, 16 GiB free reserve and existing live guards remain.
For the pinned N256/full-actor512 test fixture, the fresh-run peak changes from
65,241,943,952 to 58,799,493,008 bytes, exactly 6 GiB. This does not admit
full-actor4096. The lifecycle evidence and CPU admission boundary checks are
recorded in [the memory audit](../../docs/NATIVE_MEMORY_ADMISSION_AUDIT.md).

For ordinary fresh-process resume use `restore_live_rows = 0` and the verified
saved row count. For an existing populated runner, pass its actual old rows;
these remain live until the staged replay is committed. The plan also reports
full-live/full-saved replacement as a separate diagnostic. Runtime/environment
staging does **not** turn CLI optimizer loading into a rollback transaction for
an already running learner: CLI startup restores into a fresh learner and
aborts on failure.

`counts["host_checkpoint_stream_publication_headroom"]` is the **additional**
host headroom needed before publication. It excludes replay, parameters and
other already-resident common components. Compare it to fresh host remaining
immediately before saving; do not add the entire process envelope again.

`minimum_output_free_bytes` includes one fresh generation plus 1 GiB of disk
headroom. `Plan.require_output_free()` expects actual `statvfs` `f_bavail` bytes
for the output filesystem. Existing generations are already used space and are
never treated as free or deleted. Recheck before creating a new `.partial`
generation, retain CreateNew/SHA/fsync/atomic-pointer publication, and leave the
old valid pointer intact on pre-commit failure. Other writers can still consume
space after a check; the filesystem errors must remain fail-stop.

## Inputs before and after data loading

The original motion manifest and the checkpoint's serialized catalog are
different objects:

| Input | Before detailed loading | After loading/verification |
| --- | --- | --- |
| `motion_manifest_bytes` | Actual open-file size, strictly 1..256 MiB; 256 MiB is the conservative unknown bound | Same validated original file size |
| `catalog_json_bytes` | 64 MiB | Actual serialized checkpoint catalog size, still ≤64 MiB |
| `state_json_bytes` | 4 MiB | Actual bounded state JSON size |
| `sampler_bins` | `unknown_sampler_bins_upper()` = 43,149,672 | Actual `motion.bins.length()` |
| APIC manifest/payload/union bytes | Zero selects the profile's fixed maximum for that field | Validated actual artifact sizes |
| `environment_payload_bytes` | Zero is allowed; a conservative N×(133×8+32) floor is always used | Actual numeric environment sidecar total, excluding sampler |
| `restore_live_rows` | Zero for fresh process | Actual existing runner rows if replacing it |
| `restore_saved_rows` | Zero for fresh training; replay capacity for worst-case resume | Verified saved rows |
| `restore_optimizer_archive_bytes` | Zero selects three ×512 MiB | Actual verified three-archive total |

The sampler upper bound follows the existing reader's Int32 total control-frame
ceiling, at most 200,000 clips and a reset bin per 50 control frames. It allocates
no bins. Numeric sampler data, temporary probability arrays, and a 64-byte-per-
bin object/directory allowance are separately counted. The 4 GiB reference
floor is `max(4 GiB, 16 * motion_manifest_bytes)`; APIC manifest decode separately
uses 16 times its actual/profile-bounded size.

For paper training, the pinned APIC manifest's bounded CPU validation precedes
whole-run admission, so an unknown artifact maximum does not block safe metadata
inspection. Sampler counts still use the unknown upper bound before the motion
loader verifies the data. Manifest `source_frames` declarations are not trusted
as actual bins. Deriving an authenticated count would otherwise require the
existing source/shard scan; this patch adds no second full-corpus CSV pass.
Moving the existing loader earlier requires a separately validated preparation
budget for retained catalog/bin objects and file cache; that remains follow-up
work. Actual `motion.bins.length()` is used in the post-catalog recheck.

## Pure arithmetic examples

The test fixture uses N4096, replay1000, Bw2048, Bpi4096, H32, W8, history and
preview10, SMC99, widths WM 2048×3, policy 2048/1024/512/256, critic256/128,
five critic epochs/four minibatches, full saved replay into an empty runner,
64 MiB catalog, 4 MiB state, and unknown APIC/archive sizes at their fixed
maximum. These are **estimates with artificial bin counts**, not measured
BONES sizes or N4096 execution results.

| Execution / bin assumption | Largest phase (bytes) | Required actual host and CUDA free (bytes) |
| --- | ---: | ---: |
| micro16, 1,000,000 bins, one rank | 64,647,803,456 | 99,458,159,164 |
| full batch, same bins | 196,803,834,432 | 302,775,129,896 |
| micro16, unknown-bin upper bound | 69,031,369,344 | 106,202,106,684 |
| micro16, 1,000,000 bins, DDP per rank | 65,721,545,280 | 101,110,069,662 |

The 1M-bin example requires 12,348,030,976 additional host bytes for publication
and 10,521,341,184 free filesystem bytes for a fresh generation plus headroom.
A 64 GiB process cap cannot satisfy these paper-scale estimates. A larger cap
alone is insufficient: the actual remaining host/cgroup and CUDA readings must
also pass the selected policy (65% by default, or the explicit percentage with
16 GiB retained). Two ranks each configured with B4096/N4096
execute twice that global workload; the capacity profile describes **per-rank
bounds**, not an automatic split of the paper's workload.

N128 telemetry observed a 341,745,664-byte allocator peak and no OOM for its
bounded run. That evidence does not validate N4096 physics, peak memory,
performance, convergence, or equivalence of independent trained weights.

## Validation

`moon test --target native src/learning_native_admission` runs bounded CPU
arithmetic tests, including exact slab/input counts, full-vs-micro behavior,
bounded actor decode accounting, fresh-vs-live restore, cache retention, default
65% and optional percentage/reserve boundary rounding, unknown metadata,
publication/disk headroom, legacy rejection and overflow. No test creates a
paper-size array, opens LibTorch, initializes CUDA, or runs physics.
