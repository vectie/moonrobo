# Native training entry point

This executable uses MoonBit collection/training code and native LibTorch tensor
operations. The Python and scalar MoonBit entry points remain available. The
default profile is Float32 only, with at most 128 environments and 128 samples per
local model/actor batch. CUDA training can use CPU MuJoCo physics or a separately
validated Newton APIC artifact; CUDA learner execution does not imply GPU physics
or execution on a real robot.

Build with MuJoCo headers matching the runtime library exactly. `CPATH` must
contain the directory which contains `mujoco/mujoco.h`, and the C stub must be
rebuilt if a previous build did not have those headers. The trainer reports both
the compiled header ABI and loaded runtime version and rejects mismatches.
`--scene` must name an actuated MJCF scene, such as the generated
`scene-no-self-collision.xml`. A bare kinematic robot XML with zero actuators is
not a runnable training scene.

The `preflight` subcommand uses the same flags as `train`, reads Linux host/cgroup
availability and actual CUDA free memory, and checks conservative resource
envelopes before model/replay allocation. It does not run a training step or
verify convergence. Actual training rechecks memory after bounded motion-cache
loading. Host replay/checkpoint JSON and NCCL staging have separate reserves.
The memory plan is an estimate; use a container memory limit and a process
watchdog as additional runtime bounds. Heavy tests are not part of this CLI.

Explicit `capacity_profile: "paper-4096"` opts into fixed per-rank bounds of
4096 environments, world batch2048, actor batch4096 and replay1000. It requires
Isaac/APIC CUDA, `--checkpoint-format stream-v2`, a matching explicit capacity
declaration in the artifact, and a pinned `physics_artifact_sha256`. It does not
implicitly change any batch size or choose microbatching. The default limits
and old Python/frozen artifacts are retained. See the [capacity contract](../../learning_native_capacity/README.md),
[phase memory estimate](../../learning_native_admission/README.md), and
[checkpoint rules](CHECKPOINT_CAPACITY.md). Training and evaluation recheck
actual host/CUDA availability; checkpoint publication also rechecks additional
host headroom and output filesystem free space. These larger serialization
limits have CPU boundary and build evidence, not N4096 execution evidence.

The [paper-batch throughput configuration](../../../examples/learning/g1-native-tensor-paper-n256-b2048-b4096.json)
selects world batch2048, actor batch4096 and microbatch256 explicitly. Its
physical environment count is separately set to256; native artifact validation
and fresh memory admission remain required. The older N128/micro16 configuration
is retained as an engineering reference, not a recommended throughput setting.
See the [measured batch comparison](../../../docs/NATIVE_BATCH_THROUGHPUT.md):
at unchanged B128, full-batch update phases were about6.36x faster than
micro16 on179, with no OOM in the four short runs.

The later [measured Paper93 micro512 configuration](../../../examples/learning/g1-native-tensor-paper-n256-b2048-b4096-util80-micro512.json)
keeps logical batches2048/4096 and N256. It explicitly opts into
`memory_admission_percent: 80`, capped at 80% of actual remaining memory while
retaining at least16 GiB. The default remains65%. This option requires
`--cuda-memory-telemetry`, a finite container cap and zero swap; every recorded
phase checks remaining CUDA, host and cgroup memory. The checks are at phase
boundaries, not continuous protection. Micro512 completed ten iterations and
a checkpoint on179, increasing update throughput47.4% relative to micro256 in
the same paper-batch experiment. Micro1024 was refused at preflight and did not
train. The linked configuration is a throughput gate, not a convergence schedule.

`memory_admission_percent` describes training admission only. Evaluation and CPU
actor export accept a valid saved request after checking its integer range
65..80 and explicit paper capacity. Evaluation removes it only from a temporary
runtime settings copy, alongside disabling distributed execution; the saved
source config and identity remain unchanged. Existing `inference_memory` and
`evaluation_reserve` checks still govern inference independently. CPU export
continues to use the original CPU-only actor archive path without configuring
CUDA. When the source has an explicit training policy, both reports include
`training_memory_policy_not_applied: true` and the saved percentage. Legacy
sources without the field retain their report/identity semantics.

An optional `--config` on either evaluate or export must equal the complete
saved configuration before any temporary projection. Do not remove the memory
field or change batch/physics parameters in a replacement config. Invalid saved
percentages or capacity declarations are rejected rather than silently filtered.

The subsequent [world2048/actor512 execution configuration](../../../examples/learning/g1-native-tensor-paper-n256-b2048-b4096-util80-wm2048-pi512.json)
also completed ten iterations and checkpointing with the same frozen trainer,
limits and inputs. It keeps the logical batches 2048/4096 and raises only world
execution chunk 512 to the full 2048. Combined update time fell another 8.36% in
the short comparison. It is the latest measured throughput candidate; actual
memory still has substantial headroom and the actor 1024 refusal remains.

Optional config fields `wm_microbatch` and `pi_microbatch` default to `0`,
which preserves complete-batch execution. Positive values must not exceed the
unchanged logical `wm_batch` and `pi_batch`; they split the world or actor
update without changing the logical batch, horizon, sample counts or any
admission cap. The effective `batch_execution` is included in preflight output,
durable run identity, distributed launch identity and training report, so a
different plan cannot silently join a rank or resume a generation. This is an
execution option, not a claim that the conservative memory envelope or 65%
guard has fallen. The learner's [microbatch notes](../MICROBATCH.md) describe
the validated numeric scope. Evaluation/export of older checkpoints continues
to use their stored actor and identity; those commands do not require a
`batch_execution` field in old checkpoint metadata. Training resume is stricter:
an older generation without this durable identity field is rejected by the new
trainer, even when both effective microbatch values are zero.

## Explicit CUDA FP32 policy

Optional config field `allow_tf32` is a strict Boolean. If it is absent, the
trainer preserves legacy behavior: it does not query/set the optional precision
extension or add a precision field to durable identity. Explicit `true` permits
TF32 for CUDA matmul, cuDNN convolution and cuDNN RNN; explicit `false` selects
IEEE for all three. Both explicit choices require CUDA and the optional verified
LibTorch 2.11 extension; omit the field for the legacy CPU profile. Float32
storage and `amp=none` remain unchanged.

The setting occurs immediately after opening the tensor backend, before
preflight, any model tensor, or NCCL control. The CLI acknowledges startup scope
only at that call site. Unsupported versions, missing symbols, CPU execution,
runtime override conflicts or unconfirmed readback fail explicitly. The stable
`cuda_fp32_policy` records the requested Boolean, the three actual Context
settings, environment overrides and permission classifications. The transient
startup lock is excluded. This evidence enters preflight output, durable run
identity, DDP launch identity, both checkpoint formats, and the training report.
The existing exact identity check rejects a different request or resolved
runtime policy on resume; ranks also cannot silently use different policies.

Evaluation validates the saved policy against its source config, applies it
before Actor creation and requires exact resolved-policy agreement. It refuses
to infer historical precision from an old explicit config that lacks verified
policy evidence. A legacy source with neither field stays on the legacy path.
CPU export/re-export validates and preserves the source policy in
`actor.json`'s `source.identity`; its report says `cuda_fp32_policy_applied=false`
and does not configure CUDA or execute policy matmul. Evaluation reports
`cuda_fp32_policy_applied=true` only for an explicit successfully applied source
policy. These permissions do not prove any particular kernel used TF32.

The separate opt-in config
`examples/learning/g1-native-tensor-paper-n2-tf32-method-gate.json` adds
`allow_tf32: true` and a new profile label to the preserved paper N2 gate. It does
not change any batch, update, physics or memory setting. Use a fresh output and
the verified extension; the previous paper config and its evidence stay intact.

Seven narrow CPU contract checks passed, including old-plugin compatibility,
missing capability, strict parsing, stable identity, mismatch refusal and export
metadata semantics. The [independent four-mode CUDA probe](../../learning_tensor/TF32.md#actual-spark-gpu-probe--2026-10-24)
has passed on node 179. A subsequent [integrated preflight and training gate](../../learning_tensor/TF32.md#actual-integrated-cli-training--2026-10-24)
also passed there on 2026-10-24 at 09:45 Beijing time: Paper93, N2/B2, complete
batches, 40 LAFAN1 clips, episode context and the new self-collision-enabled APIC
artifact. The [actual report](../../../output/spark-runtime-20261024/native-paper-tf32/runs/native-paper-tf32-method-20261024-a/train/report.json)
records all three settings as `TF32`/`LibraryMayUse`, 36 physical and 64 imagined
transitions, 10 world-model updates, one actor update and 20 critic updates.
An independent [8 GiB CPU checkpoint readback](../../../output/spark-runtime-20261024/native-paper-tf32/runs/native-paper-tf32-method-20261024-a/checkpoint-readback.json)
verified network/Adam/normalizer state and the held-state attestation; it made no
cross-rank or resume-equivalence comparison.

The training container retained 48 GiB/zero-swap/four-CPU limits, the 65% guard
and 24 GiB physics reserve and exited zero without OOM. Its nine-sample
synchronized telemetry window recorded allocator peaks of 282,415,104 allocated
and 316,669,952 reserved bytes; the helper observed a 2,305,785,856-byte cgroup
peak before exit. These are distinct scopes, not a total-device or full-lifetime
memory certificate. The gate does not establish kernel-level TF32 dispatch,
speed, convergence or N4096 execution. Actual GPU evaluation and explicit-policy
resume behavior remain separate validation work. Previous frozen training,
evaluation and microbatch artifacts do not gain TF32 evidence retroactively.

## Two-rank launch

Use the same native executable, tensor and MuJoCo libraries, config, actuated
scene/asset tree and relative-path motion manifest on both hosts. The ordered
motion hashes are also checked before training. `--scene-assets-root` defaults to
the scene directory; it must contain only the immutable robot assets (regular
files/directories, at most 8192 files and 16 GiB), including referenced meshes and
included XML. Symlinks are rejected. Local library, output and cache paths can
differ when their hashed contents and config agree. A configured cache path in
the common JSON must be the same string on both ranks; omit it to use rank-local
defaults.

Start with `examples/learning/g1-native-tensor-ddp-runtime-gate.json`. Its two
environments and batch size two are **per rank**, giving four environments and a
global actor/model batch of four. The seed in the common config is the base seed;
rank one collects with base+1, while model parameters and normalization are
synchronized. Do not manually change the config seed by rank.

Both ranks require an external timeout (example commands below assume GNU
`timeout`). NCCL operations have a polling timeout, but a stuck vendor/driver
call cannot be bounded by polling alone. Select the intended ConnectX-7 interface
using the verified NCCL environment configuration for the hosts; the CLI does
not silently substitute a transport. A successful NCCL handshake alone is not
evidence that RDMA, rather than sockets, was selected; retain NCCL logs.

Start rank zero with a fresh session string and an ID path which does not exist:

```sh
timeout --signal=TERM --kill-after=10s 600s /ABSOLUTE/aligned-gpu.exe train \
  --tensor-library /ABSOLUTE/libmoonrobo_learning_tensor.so \
  --library /ABSOLUTE/libmujoco.so.3.15.0 \
  --scene /ABSOLUTE/g1_description/scene-no-self-collision.xml \
  --manifest /ABSOLUTE/manifest.json \
  --config /ABSOLUTE/g1-native-tensor-ddp-runtime-gate.json \
  --output /ABSOLUTE/new-run \
  --distributed --rank 0 --world-size 2 \
  --session-id native-ddp-20261024-UNIQUE1 \
  --nccl-id-file /ABSOLUTE/fresh-nccl-id.json --nccl-timeout-ms 60000
```

Start rank one with the same session/timeout and `--rank 1`. Its local ID path
initially must not contain a previous rendezvous. After rank zero logs
`nccl-rendezvous-published`, copy that file to a temporary path on rank one's host
and rename it atomically to rank one's `--nccl-id-file`. Both processes must stay
alive. The file expires after the configured timeout; clocks may differ by at
most 10 seconds into the future. A copied file is only a connection ticket: the
NCCL handshake still requires the live rank-zero process. Durable `.consumed`
records and CreateNew publication prevent accidental reuse. A failed launch
requires a new session, ID path and output directory.

For a large catalog whose source/cache hashing can take different amounts of
time on the two hosts, enable the optional bounded data preparation barrier.
Start the existing forwarder first with
`--data-ready-timeout-seconds 21600`, and pass exactly the same option to both
native trainers. Allowed values are 60–21600 seconds. The coordinator clock
starts before either trainer: slow loading consumes this budget, rather than
starting an unbounded new wait when a rank finishes. This does not increase
`--nccl-timeout-ms` or the NCCL ticket's 1–60 second validity.

Each trainer completes motion loading, source/cache identity checks and memory
preflight, then atomically publishes an immutable rank-ready record beside its
ID path. The forwarder checks both rank records and their effective launch
identity hashes, publishes a bounded common release on rank one's host first,
then publishes the local rank-zero release. Only then does rank zero issue the
ordinary short-lived NCCL ticket. Each rank rechecks actual host/cgroup/CUDA free
memory after the potentially long wait and before connecting or allocating its
learner. The release itself expires after 60 seconds; stalled transfer requires
a fresh session rather than extending an old ticket.

The optional protocol uses records suffixed `.data-ready-coordinator.json`,
`.rank-N.data-ready.json`, `.data-ready-release.json` and, on failure,
`.rank-N.data-ready-failed.json` / `.data-ready-aborted.json` beside the ID file.
Every record is bounded to 4 KiB and published without overwriting existing
files. Rank failure marks abort the preparation wait through the live forwarder;
network/coordinator failure remains bounded by the recorded deadline. Retained
records are evidence, not proof that a peer is still alive: the subsequent NCCL
handshake establishes connectivity. Use an external process watchdog covering
the preparation budget plus transfer/training time.

The existing small-gate wrapper and forwarder's default invocation keep their
current 180-second startup behavior. They do not automatically opt into a
six-hour preparation wait. The fixed gate still uses two CPU MuJoCo environments
and a 16 GiB container; it is not a launcher for APIC artifacts or large profiles.

For the verified 178-to-179 route, start
`scripts/forward_native_nccl_id.mbtx /home/wlc003s/moonrobo SESSION` on 178 before
either trainer. It requires the existing `private/ssh-179.sock` control connection
to `wlc004s@10.0.0.2` and waits for `private/SESSION.id.json`. It checks the complete
bounded JSON ticket, copies through a temporary file, and atomically publishes
with a hard link which refuses an existing destination. It waits at most 180
seconds for publication, uses bounded SSH/rsync operations, and exits within a
220-second overall deadline. Start trainers after its `forwarder ready` log.
Before that log it atomically publishes `SESSION.forwarder-ready.json` to both
hosts using the existing SSH connection. This bounded, expiring receipt records
startup ordering; it does not certify that the forwarder stays alive.
Both trainers must use the corresponding `private/SESSION.id.json` paths. A
durable `.forwarder-started` marker prevents accidentally reusing the session.

NCCL begins only after each host's bounded catalog/cache preparation and memory
checks. Prepare caches beforehand or account for startup skew when launching;
one rank which finishes preparation too late must fail rather than join an old
session. The initial CLI supports exactly two ranks and does not support native
distributed resume. `--resume` with any distributed flag is rejected before
loading the tensor backend or allocating GPU memory.

Each host writes `rank-N/` and atomically publishes complete immutable native
generations containing three Adam archives, normalizers, replay, RNG, histories,
physical state and identity. All ranks then exchange receipt hashes and retain
an immutable distributed manifest pointing at each generation's `receipt.json`.
Each rank has a `distributed-current.json`; rank zero also publishes a convenient
root pointer. These receipts describe consistent artifacts on their respective
hosts and explicitly record `resume_supported=false`.

Reports identify local and global work counters, the actual learner and physics
devices, rank/world size, and `robot_hardware_execution=false`. Completing the
requested gate iterations does not establish convergence, paper-result parity,
or ConnectX-7 throughput. Numerical/full training comparisons remain separate
validation work.

For the fixed Spark runtime gate, use
`scripts/run_spark_native_ddp_gate.mbtx CANONICAL_REPO RANK SESSION` after the
forwarder announces readiness. The rank-specific repositories are
`/home/wlc003s/moonrobo` (rank 0) and `/home/wlc004s/moonrobo` (rank 1). Start both
launchers promptly with the same fresh session. They require the existing pinned
RDMA image and staged `private/native-tensor-nccl/trainer` and
`private/native-tensor-nccl/libmoonrobo_learning_tensor.so`; they create no SSH
authentication and pull no images.

This launcher fixes each container to 16 GiB with no additional swap, four CPUs,
the verified rank-specific NIC/HCA and `NCCL_NET=IB`. The trainer deadline is 240
seconds followed by a five-second termination grace; attach has a separate
285-second bound. A copy of the launcher executable runs a restricted `--inside`
mode and captures actual kernel cgroup limits, `memory.peak`, `memory.events`
and CPU quota before the container exits. Missing metrics fail verification;
if the helper is killed before its final snapshot, retained Docker OOM/exit
evidence must not be described as a measured memory peak.

Evidence is retained under `runs/spark-native-ddp-gate-SESSION/rank-N/`, including
launch arguments, readiness receipt, trainer logs, cgroup snapshots, Docker
state, NCCL logs and `launcher-result.json`. Training reports and immutable
checkpoints are under `train/rank-N/`. A passing gate requires local physical/
imagined/model/actor/critic counts 36/64/1/1/4 and global counts 72/128/2/2/8,
CUDA-resident Float32 learning, CPU MuJoCo physics, actual NET/IB channel logs
without NET/Socket channels, and complete native checkpoints. GPU Direct RDMA
is reported separately from NET/IB and is not inferred from it.

Before saving a generation, every rank hashes its actual held model parameters,
three Adam states and five normalizers in bounded 65,536-value chunks and checks
that their shared-state digests agree. The digest is stored in state, receipt and
report; a supported single-rank restore checks the loaded state against it.
Distributed startup additionally checks the effective iteration cap and
checkpoint cadence, including CLI overrides, so mismatched collective schedules
fail before learner allocation. These launch-only options do not alter the
durable run identity used when extending a single-rank run.
