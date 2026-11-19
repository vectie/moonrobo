# ConnectX-7 RDMA experiment for the two Spark training hosts

The bounded two-host native NCCL AllReduce probe passed over ConnectX-7
RoCE on 2026-10-24. Both ranks verified every output element, and their logs
selected `IB` with `NET/IB/0` channels. **GPUDirect RDMA was disabled (`GDR 0`)**;
NVIDIA documents that DGX Spark does not support it. A subsequent bounded
two-host Python learner iteration also passed over the same RoCE path.
Sustained throughput and convergence remain unverified. The existing socket launch template in
[`G1_SMC_178_179_DEPLOYMENT.md`](G1_SMC_178_179_DEPLOYMENT.md) remains available
for comparison.

The RDMA image has now been built on 179 and loaded on 178, with image ID
`sha256:989985f4b65447e4452fcfeeec70cfa3f48eb52637f8f96e41a736f11ab308cd`.
The shared base image ID is
`sha256:70d9f9b99a5cf08bbf0e43c2bc64eee1ce19e93f219c76d1f4fd9f2f911dd2c7`.
The combined 10,779,234,816-byte Docker archive was SHA-verified before
loading on 178; see the [runtime artifact record](DGX_SPARK_PINNED_RUNTIME_PLAN.md).
The loaded NCCL/CUDA versions in the successful two-rank probe were
`2.28.9`/`13.0`. Separately, the 128-environment, one-iteration physics/learner
gate on 179 completed with 8,448 physical transitions, 4,096 imagined steps,
one world-model update, one actor update and four critic updates. It took
68.152 seconds and wrote a roughly 217 MB checkpoint; no OOM was observed.
The earlier memory-guard refusals were retained and the guard was not bypassed.

The subsequent `gate-20261024-a` Python run completed one iteration on each
of two ranks, with 128 environments per rank, rendezvous at
`10.0.0.1:29500`, `NET/IB/0` and `GDR 0`. Each rank reported 8,448 physical
transitions, 4,096 imagined steps, one world-model update, one actor update
and four critic updates. Cgroup peaks were 5,337,329,664 bytes on 178 and
5,211,684,864 bytes on 179; each rank's reported PyTorch peak was
1,643,218,432 bytes. Both reported zero OOM events. The 80 GiB cap and
learner memory guard remained active. These are bounded execution results,
not a sustained bandwidth or convergence comparison; PyTorch's peak does
not account for all simulator allocations.

The native MoonBit Float32 CUDA learner also completed a bounded two-rank
iteration with CPU MuJoCo physics. In the later `native-ddp-20261024-d` run,
each rank used two environments and performed 36 physical transitions,
64 imagined transitions, one model update, one actor update and four critic
update operations. This is one synchronized iteration. Actual cgroup memory
peaks were **3,062,317,056 bytes on 178** and **3,065,729,024 bytes on 179**,
under independent 16 GiB limits with no extra swap; both recorded zero OOM
events and trainer exit code 0. NCCL again selected `NET/IB` and `GDR 0`.
The [178 read-only verification](../output/spark-runtime-20261024/native-ddp-attested/native-ddp-verify-existing-20261024-d.log)
and [179 read-only verification](../output/spark-runtime-20261024/native-ddp-attested/native-ddp-verify-existing-179-20261024-d.log)
passed after fixing the wrapper's distinction between explicit MoonBit
`Some` JSON arrays and optional record fields. The original failed wrapper
results are retained; verification did not rerun training or rewrite them.
Both trainers attested actual parameters, Adam moments/options/steps and five
normalizers before saving, with shared digest
`a7dccc685920a195887c2c80dbbb3af26aa6686066c4d28a6471c8eb147a4adb`.
Both newly saved checkpoints also passed
[CPU readback against those held-state attestations](../output/spark-runtime-20261024/native-ddp-attested/native-checkpoint-semantic-20261024-e.log),
including identity, iteration and shared-state equality. The read-only audit
used an 8 GiB cap, exited 0 and recorded `held_state_attestation_verified=true`
for each rank. Its initial optional-field decoder failure is preserved as
`native-checkpoint-semantic-20261024-d.log`; the corrected reader did not
modify either checkpoint or execute any training.

The preceding `native-ddp-20261024-c` checkpoints additionally passed a
[CPU read-only semantic comparison](../output/spark-runtime-20261024/native-checkpoint-semantic/native-checkpoint-semantic-20261024-a.log):
identity, iteration and all shared learner state were equal. That audit
exited 0 under an 8 GiB container cap without OOM-kill. Rank-local replay,
physics and RNG were intentionally not compared. These earlier CPU-physics results establish
small collective/update correctness, not full-data training, convergence,
native GPU physics, distributed resume or a speed advantage over two seeds.

## Native APIC GPU physics and two-rank learner gate

The later `native-apic-ddp-20261024-b` run completed one synchronized
iteration with **native APIC GPU physics and the MoonBit Float32 CUDA
learner on both hosts**. The [rank-0 report](../output/spark-runtime-20261024/native-apic/ddp-b/178/runs/spark-native-apic-ddp-gate-native-apic-ddp-20261024-b/rank-0/train/rank-0/report.json)
and [rank-1 report](../output/spark-runtime-20261024/native-apic/ddp-b/179/runs/spark-native-apic-ddp-gate-native-apic-ddp-20261024-b/rank-1/train/rank-1/report.json)
each record two environments, 36 physical transitions, 64 imagined
transitions, one model update, one actor update and four critic updates.
This uses the fixed 40-motion LAFAN1 manifest, not the full BONES corpus.
The [178 NCCL log](../output/spark-runtime-20261024/native-apic/ddp-b/178/runs/spark-native-apic-ddp-gate-native-apic-ddp-20261024-b/rank-0/nccl.spark-57f5.61.log)
and [179 NCCL log](../output/spark-runtime-20261024/native-apic/ddp-b/179/runs/spark-native-apic-ddp-gate-native-apic-ddp-20261024-b/rank-1/nccl.spark-368c.60.log)
confirm NCCL 2.28.9/CUDA 13, the expected HCAs, `NET/IB/0` and `GDR 0`.

Both trainers and containers exited 0 with `OOMKilled=false` and zero
observed OOM counters. The final in-container cgroup snapshots report
**3,176,099,840 bytes on 178** and **3,061,059,584 bytes on 179** under
48 GiB limits and no extra swap. These are cumulative kernel peaks observed
before helper exit; they include startup but do not certify the full
container lifetime. The 65% admission guard and 24 GiB physics reserve
remained active. The preceding `native-apic-ddp-20261024-a` refusal is
retained: 178 had 11,190,460,416 CUDA-free bytes and rejected the
32,004,453,920-byte estimate; 179 received the preparation failure and exited
without an OOM. File-specific cache advice on completed converted CSVs
preceded b; no global cache drop, file deletion or guard relaxation was used.
The [APIC execution record](DGX_SPARK_APIC_EXPORT_PLAN.md#two-host-apic-learner-gate-2026-10-24)
links the original failure, cache-advice and memory records.

The [CPU checkpoint comparison](../output/spark-runtime-20261024/native-apic/ddp-b/178/native-apic-ddp-checkpoint-audit-20261024-b.log)
decoded distinct rank-0 and rank-1 saved generations, with the latter copied
from 179 to 178. Both match their pre-save attestations, and identity,
iteration, parameters, Adam state and normalizers compare equal. Their
shared digest is
`850e22749fd10b718e5f1c24a5aa9ed498e8947bb93e6575af019ce8f2d94b1e`.
Rank-local replay, physical state and RNG were not compared. This establishes
the bounded GPU-physics/learner/collective execution path and saved shared
state consistency. It does not establish SDK numerical equivalence,
distributed resume, convergence, full-corpus training or a speed advantage.

## Bounded N4 microbatch two-host gate

The later `native-bounded-ddp-20261024-a` run combined native APIC GPU
physics, the Float32 CUDA learner, compact replay, bounded reference gather,
and microbatching on both hosts. It used the same 40-motion LAFAN1 catalog,
four environments per rank, logical world/actor batches of four and
`wm_microbatch=pi_microbatch=2`. The [178 report](../output/spark-runtime-20261024/native-bounded-ddp/178/runs/spark-native-bounded-ddp-gate-native-bounded-ddp-20261024-a/rank-0/train/rank-0/report.json)
and [179 report](../output/spark-runtime-20261024/native-bounded-ddp/179/runs/spark-native-bounded-ddp-gate-native-bounded-ddp-20261024-a/rank-1/train/rank-1/report.json)
record one synchronized iteration. Each rank performed 72 physical and 128
imagined transitions, one model update, one actor update and four critic
updates, then saved its own stream-v2 generation. The reports' `global_counters`
sum work across ranks (144 physical, 256 imagined, 2/2/8 update operations);
they do not mean two sequential synchronized learner iterations.

Both trainer and container exit codes were 0, with `OOMKilled=false`. The
[178 result](../output/spark-runtime-20261024/native-bounded-ddp/178/runs/spark-native-bounded-ddp-gate-native-bounded-ddp-20261024-a/rank-0/inside-result.json)
and [179 result](../output/spark-runtime-20261024/native-bounded-ddp/179/runs/spark-native-bounded-ddp-gate-native-bounded-ddp-20261024-a/rank-1/inside-result.json)
record cgroup peaks of **3,096,698,880** and **3,092,754,432 bytes**,
respectively. These kernel peaks were observed before helper exit, include
startup, and do not certify the complete container lifetime or CUDA allocation
peak. The [178 NCCL log](../output/spark-runtime-20261024/native-bounded-ddp/178/runs/spark-native-bounded-ddp-gate-native-bounded-ddp-20261024-a/rank-0/nccl.spark-57f5.61.log)
and [179 NCCL log](../output/spark-runtime-20261024/native-bounded-ddp/179/runs/spark-native-bounded-ddp-gate-native-bounded-ddp-20261024-a/rank-1/nccl.spark-368c.60.log)
show `NET/IB/0` with GPUDirect RDMA disabled (`GDR 0`).

An independent [CPU read-only archive comparison](../output/spark-runtime-20261024/native-bounded-ddp/178/runs/native-bounded-ddp-readback-20261024-a/stdout.log)
decoded the two distinct generations: identity and iteration matched,
`shared_state_equal=true`, and both saved archives matched their pre-save
held-state attestations. Their shared digest is
`983506230cbe4ce76350e1f51bf7da6b89f8935f8680c13af5068e040ac18505`.
Rank-local replay, RNG and physics state were not compared. This is a bounded
engineering gate, not a full-vs-split numerical comparison, memory-saving or
network-bandwidth benchmark, BONES-catalog DDP run, convergence result, or
distributed-resume validation.

A separate [single-host BONES N128 gate](NATIVE_BONES_SCALE_READINESS.md#bones-n128-全目录门禁)
later completed one iteration over the 137,289 accepted partial-filter clips
with independent CPU archive readback. It did not use two-host DDP and does
not change the transport or bandwidth claim above. A separate
[full-vs-split GPU comparison](../output/spark-runtime-20261024/native-microbatch-numeric/runs/native-microbatch-numeric-20261024-a/microbatch/comparison.json)
failed with 27 out-of-tolerance critic weight values among 234,377,294
compared values; no numerical-equivalence or memory-saving claim follows from
the bounded DDP gate.

## Verified collective and GPUDirect boundary

The native MoonBit/C executable was built on 178 and had SHA-256
`08d01b86205aac4e91b9e322340489ec26526672260c0995e31abb3ca2a06859`.
Each rank reduced 262,144 float32 values (1 MiB), checked every result after
one warm-up and three measured AllReduces, and completed within the probe's
bounded deadline. Mean AllReduce plus stream-synchronization time was
`0.610994 ms` on rank 0 (178) and `0.61247 ms` on rank 1 (179). Input/output
copies are outside that timer. These three small samples establish numerical
and transport correctness; they do not measure sustained bandwidth or prove
200 Gb/s application throughput. Logs are preserved under
[`output/spark-runtime-20261024`](../output/spark-runtime-20261024).

Both logs selected the expected HCA in the table below, reported
`Using network IB`, `NET/IB/0`, and `GDR 0`. This is a successful verbs/RoCE
path using a fallback through host memory, not a GPU-direct transfer.
The [NVIDIA DGX Spark CUDA porting guide](https://docs.nvidia.com/dgx/dgx-spark-porting-guide/latest/porting/cuda.html)
(updated 2026-10-21) states that Spark's UMA device allocations cannot be
coherently accessed by the NIC. It therefore excludes GPUDirect RDMA through
`nvidia-peermem`, DMA-BUF or GDRCopy and recommends capability checks plus a
host-memory fallback. A provider or driver upgrade alone does not remove
that documented architectural limitation. Do not force GDR or load a peer
memory module to reinterpret this passing result as GPU-direct.

Both hosts and the RDMA container report `libibverbs1`/`ibverbs-providers`
`50.0-2ubuntu0.2` (arm64). Both hosts run kernel `7.0.0-1019-nvidia` with
NVIDIA open kernel module `580.178.04`; `nvidia_peermem` is absent. The probe
also logged missing `MLX5_1.25` symbols
`mlx5dv_get_data_direct_sysfs_path` and `mlx5dv_reg_dmabuf_mr`.
The pinned [NCCL 2.28.9 symbol loader](https://github.com/NVIDIA/nccl/blob/v2.28.9-1/src/misc/mlx5dvsymbols.cc#L45-L59)
treats these two lookups as optional: absence produces an informational
message and symbol initialization still returns success. Its
[IB initialization source](https://github.com/NVIDIA/nccl/blob/v2.28.9-1/src/transport/net_ib.cc#L624-L707)
separates mlx5 Data Direct discovery from ordinary verbs initialization and
allows advanced mlx5 feature discovery to fail without disabling ordinary
IB/RoCE. Those messages did not prevent this collective. They are not proof
that replacing libmlx5 would enable GPUDirect on GB10. Keep the validated
image for comparison; no host driver or package changes were made.

## Observed host configuration

Read-only checks on 2026-10-24 found the following active Ethernet/RoCE ports:

| Host | IPv4 address | Network interface | Verbs HCA and port |
| --- | --- | --- | --- |
| 178 | `10.0.0.1/24` | `enp1s0f1np1` | `rocep1s0f1:1` |
| 179 | `10.0.0.2/24` | `enp1s0f0np0` | `rocep1s0f0:1` |

Both `ibv_devinfo` reports showed `PORT_ACTIVE`, Ethernet link layer,
`active_mtu=1024`, and firmware `28.45.4028`. The host `/dev/infiniband/uverbs*`
and `rdma_cm` device nodes were readable/writable by ordinary users. Each
host also had secondary P2 interfaces with carrier but no assigned IP; those
interfaces are outside this experiment. The NIC link reports 200 Gb/s. The
earlier archive-copy measurement (about 501 MB/s) used ordinary SSH/TCP and
does not measure RDMA.

## Derived container

The pinned Ubuntu-based kitless Dockerfile does not explicitly install
userspace verbs libraries/providers or pass the host verbs devices into a
container. [`Dockerfile.spark-rdma`](../docker/Dockerfile.spark-rdma) adds
[`libibverbs1`](https://packages.ubuntu.com/libibverbs1),
[`ibverbs-providers`](https://packages.ubuntu.com/ibverbs-providers), and
[`ibverbs-utils`](https://packages.ubuntu.com/noble/ibverbs-utils), all listed
for Ubuntu 24.04 arm64. The packages include libibverbs, the userspace hardware
providers and `ibv_devinfo`. No Python packages or host drivers are installed
by this layer. Package versions are recorded inside the image at
`/usr/local/share/moonrobo-rdma-packages.txt`.

The first derived image and its transfer are complete. For a rebuild, build
this separate tag on one host and transfer that same image to the other. The base
argument must refer to the exact validated image from Isaac Lab commit
`46d6cc3`; use a registry `name@sha256:...` reference if available, otherwise
check the local tag's image ID immediately before building. Record the
derived image ID and compare it on both hosts. Retained rebuild commands:

```bash
cd ~/moonrobo
docker image inspect moonrobo-isaaclab:46d6cc3-kitless \
  --format '{{.Id}} {{.Architecture}}'
docker build --platform linux/arm64 \
  --file docker/Dockerfile.spark-rdma \
  --build-arg ISAACLAB_BASE=moonrobo-isaaclab:46d6cc3-kitless \
  --tag moonrobo-isaaclab:46d6cc3-kitless-rdma docker
docker image inspect moonrobo-isaaclab:46d6cc3-kitless-rdma \
  --format '{{.Id}} {{.Architecture}}'
```

Use the same bounded builder settings as the original build. The apt package
selection is recorded rather than pinned by `uv.lock`; preserve this image
for repeat measurements. Before a collective test, verify the devices **inside**
the new container on 178:

```bash
docker run --rm --network host --memory=2g --memory-swap=2g \
  --device=/dev/infiniband --ulimit memlock=-1 \
  moonrobo-isaaclab:46d6cc3-kitless-rdma ibv_devinfo -d rocep1s0f1 -i 1
```

Use `-d rocep1s0f0 -i 1` on 179. Enumeration does not allocate training tensors
or prove memory registration/communication. Host interface discovery alone
does not establish that the image contains compatible providers.

## Repeating the collective and future training experiment

The lock selects `nvidia-nccl-cu13==2.28.9`, matching the loaded version
observed on both ranks. Its [environment variable documentation](https://docs.nvidia.com/deeplearning/nccl/archives/nccl_2289/user-guide/docs/env.html)
defines `=` as exact matching for HCA/socket names and supports an IPv4 GID
range. Keep `NCCL_IB_GID_INDEX` unset so address-based GID selection can work.
For this diagnostic experiment, `NCCL_NET=IB` requires the verbs transport
instead of accepting silent socket fallback. These settings request the
path; successful collectives and transport logs must verify it.

Retain all memory, source/data mounts, output ownership, config and training
gates from the existing DDP template. Use a distinct output directory, such
as `runs/g1-smc-stage-ddp-rdma`, including in `HOME` and `WARP_CACHE_PATH`, and
select `moonrobo-isaaclab:46d6cc3-kitless-rdma`. Add the following **Docker
options before the image name** on 178, replacing the existing socket/Gloo
interface options:

```bash
--device=/dev/infiniband --ulimit memlock=-1 \
-e 'NCCL_SOCKET_IFNAME==enp1s0f1np1' \
-e GLOO_SOCKET_IFNAME=enp1s0f1np1 \
-e 'NCCL_IB_HCA==rocep1s0f1:1' \
-e NCCL_SOCKET_FAMILY=AF_INET \
-e NCCL_IB_ADDR_FAMILY=AF_INET \
-e NCCL_IB_ADDR_RANGE=10.0.0.0/24 \
-e NCCL_NET=IB \
-e NCCL_DEBUG=INFO \
-e NCCL_DEBUG_SUBSYS=INIT,NET
```

On 179 substitute `NCCL_SOCKET_IFNAME==enp1s0f0np0`,
`GLOO_SOCKET_IFNAME=enp1s0f0np0`, and `NCCL_IB_HCA==rocep1s0f0:1`.
Keep `--network host`, `--memory=80g --memory-swap=80g --shm-size=8g`,
and the common `10.0.0.1:29500` rendezvous. The unlimited memlock setting
permits page registration; it does not remove the container memory cap or
the learner's memory guard. NVIDIA documents the container pinned/shared
memory requirement in its [NCCL troubleshooting guide](https://docs.nvidia.com/deeplearning/nccl/archives/nccl_2289/user-guide/docs/troubleshooting.html#memory-issues).

The bounded two-rank numerical/transport gate on this exact image has passed.
Repeat it after relevant image, driver or network changes and capture each
rank's NCCL version, transport/HCA/GID logs, collective correctness and memory.
The learner's TCP rendezvous and synchronized optimizer updates also passed
their separate one-iteration gate recorded above. A missing provider/device,
registration error, timeout, incorrect result or unexpected transport fails
this gate. Do not enlarge the training profile or remove the memory guard to
work around it. `NCCL_DEBUG`/`NCCL_DEBUG_SUBSYS` are temporary diagnostic
settings; omit them from a long run after preserving the gate evidence.
Retain the supported host-memory RDMA fallback on GB10; the official Spark
restriction above takes precedence over generic GPUDirect setup advice.

The [native MoonBit/C probe](../tools/nccl_probe/README.md) supplies this
bounded numerical check using the pinned image's libraries. It checks every
float32 result on both ranks, uses at most 16 MiB of explicit host/device
buffers per process, and has an internal 55-second deadline plus an outer
timeout. Its rank-0 process must remain alive while its ID file is copied to
rank 1. The recorded success above comes from actual two-host execution,
separately from the module's compilation checks.

Compare this experiment to the socket mode at matching global transition
budgets, batch sizes and seeds, recording normalized return/failures,
wall time, communication time and memory. Separate transport success from
any claim that two-node training converges better than independent seeds.
