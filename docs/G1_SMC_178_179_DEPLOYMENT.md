# G1 SuperMimic training on 178 and 179

Topology supplied on 2026-10-24 02:00 Asia/Shanghai: `192.168.2.176` and
`192.168.2.177` serve Qwen inference; `192.168.2.178` and `192.168.2.179`
are online with that model stopped. The requested comparison has two runs:
one **independent seed per host**, then one **two-host data-parallel** run.
Neither mode uses 175–177. The two modes use separate output directories and
must not share a checkpoint.

SSH reaches both hosts through `lunanexa-access`. The supplied Linux accounts
are `wlc003s` on 178 and `wlc004s` on 179:

```bash
ssh -J lunanexa-access wlc003s@192.168.2.178
ssh -J lunanexa-access wlc004s@192.168.2.179
```

As checked on 2026-10-24, the jump host accepts this workstation's key, and
both target accounts accept interactive password authentication. They reject
the workstation's public key, so unattended SSH/scp is not yet available.
Both hosts are DGX Spark with one NVIDIA GB10, driver 580.178.04, CUDA 13.0,
and approximately 115 GiB available system memory at inspection. Neither host
had a compute process in `nvidia-smi`. Each account has staged aligned source
at `~/moonrobo`, 40 LAFAN1 CSVs and G1 MJCF/meshes at `~/moonrobo/data`, and
the pinned Isaac Lab source at `~/moonrobo/IsaacLab`. The source archive
`~/moonrobo/isaaclab-46d6cc3-source.tar.gz` was SHA-256 verified on both nodes
as `8278fc60c636b314c5e85a46a69ae78fda2212094020da796aa7eb4070ce4d33`;
it was extracted without `.git`, so its provenance is the verified archive,
not an on-host `git rev-parse`. The data archive was also checked before
extraction. The refreshed MoonRobo source, memory guard, importer and
distributed configuration are staged on both nodes in
`~/moonrobo/g1-smc-training-code-20261024-v2.tar.gz`; its verified SHA-256 is
`a2e73e2ce1f80835c1cd952c4bf739e0af7bb73369b3c3ab8c112ef15d6839b1`.
The pinned base and RDMA training images are installed on both hosts; the
179 runtime import/device check passed. The converted G1 USD and complete
eight-file output tree were generated on 179, then transferred and
hash-verified on 178. Image IDs and the verified Docker-archive SHA-256 are
recorded in the [runtime plan](DGX_SPARK_PINNED_RUNTIME_PLAN.md).
PyTorch/Isaac Lab are used through the container interpreter, separately from
system Python. The 128-environment, one-iteration gate on 179 was refused
before simulator steps or updates because CUDA-reported available memory
did not satisfy the unchanged 65% memory budget. After task-specific cache
management, the same gate passed on 179 with 8,448 physical transitions,
4,096 imagined steps, one world-model update, one actor update and four critic
updates in 68.152 seconds. It wrote a roughly 217 MB checkpoint without an
observed OOM; the guard remained enabled. This is a small runtime validation,
not a completed training run. Both hosts now hold the 23,499,973,647
byte BONES-SEED G1 archive from the `bones-studio/seed` ModelScope mirror. Its
SHA-256 is `52580ea8bced72ea9e2ff1e7b68f01c51c7f1099581e9a46b7c87e1dec106d8a`
on both hosts, matching the mirrored LFS pointer. A complete tar scan found
142,220 CSVs, 51,527,587,825 uncompressed bytes and no unsafe paths or file
types. Extraction completed on both hosts; independently counted 142,220 CSVs
and 51,527,587,825 file bytes on each. A one-clip MoonBit conversion produced
36 columns and 701 frames with physically plausible units. Full MoonBit
conversion then completed on 178 under an 8 GiB virtual-memory limit with
per-clip atomic writes and resume support: the unfiltered
`~/moonrobo/private/bones-seed/aligned-g1-v1` catalog contains 142,220 clips
and 124,554,605 source frames. The partial paper-feasibility filter has not
started, and a converted-catalog transfer to 179 is not yet evidenced. The
staged 40-clip LAFAN1 data remains a
separate, already extracted comparison set.

The machines also have a direct ConnectX-7 link. Read-only checks found
`10.0.0.1/24` on 178's `enp1s0f1np1` and `10.0.0.2/24` on 179's
`enp1s0f0np0`. Both links reported `200000Mb/s` and carrier, ICMP round
trips were about 0.3–0.5 ms, and 178 reached TCP port 22 on `10.0.0.2`.
An `rsync --append-verify` transfer of the remaining approximately 11.77 GB of
the G1 archive from 178 to 179 over this direct address finished in about
23.5 seconds (approximately 501 MB/s), followed by a full archive SHA-256
check on 179. This is a file-copy measurement, not a distributed training
benchmark.
The `192.168.2.x` route uses a different interface, so future DDP rendezvous
uses `10.0.0.1`. The link and file-copy checks do **not** measure training
throughput or validate collectives. Subsequently,
a separate native numerical AllReduce passed on both hosts using NCCL 2.28.9,
the expected verbs HCAs and `NET/IB/0` channels. Both logs reported `GDR 0`.
The [RoCE validation record](DGX_SPARK_CONNECTX7_RDMA.md) contains the exact
binary identity, 1 MiB/three-sample timings and the official Spark restriction
on GPUDirect RDMA. The bounded distributed learner gate also passed on both
hosts, including port 29500 rendezvous and gradient synchronization; its
counters and memory observations are recorded below. Sustained bandwidth
and long-run learning quality have not been measured.

The GPU training entrypoint for this same-method baseline is the preserved
`providers/motion_learning/aligned/train.py` with Isaac Lab/Newton physics and
PyTorch model, policy and critic updates. Its source remains available for
repeat measurement. Node-specific paper-scale targets are
[`g1-smc-178.json`](../examples/learning/g1-smc-178.json) (seed 178) and
[`g1-smc-179.json`](../examples/learning/g1-smc-179.json) (seed 179). Apart
from the seed, they match [`g1-smc-scale.json`](../examples/learning/g1-smc-scale.json):
4096 environments, 500 world-model-only iterations, 8-step model fitting,
32-step imagination, 10-frame history/preview, 2048-wide world model, SMC
99-dimensional observations, and bf16 learner updates. These paper-scale
targets are **blocked by the memory guard** until smaller runs establish
measured Newton/Warp peaks. The safe starting profile uses
[`g1-smc-spark-stage-178.json`](../examples/learning/g1-smc-spark-stage-178.json)
and [`g1-smc-spark-stage-179.json`](../examples/learning/g1-smc-spark-stage-179.json):
128 environments, 128-step replay, 128 model/actor samples, disk-mapped
references, while retaining the 8/32 horizons and network widths. The common
two-rank stage config is
[`g1-smc-spark-stage.json`](../examples/learning/g1-smc-spark-stage.json).
These are sizing probes, not comparable to the paper-scale return at the same
iteration count. Use an `80g` container memory and swap cap as an initial
host-protection limit; the trainer separately rejects a planned peak above
65% of currently available cgroup/CUDA memory. Neither guard proves that
Newton/Warp device allocations will fit. Stop and review a guard refusal;
do not bypass it to start the 4,096-env profile.
The [Spark runtime plan](DGX_SPARK_PINNED_RUNTIME_PLAN.md) pins the separate
Isaac Lab image and its CUDA/PyTorch dependencies.

## Remaining gates before launch

Refresh both `~/moonrobo` source trees to the same revision that contains the
staged configs, memory guard and distributed trainer. Preserve the Python
sources for repeat measurement. Compare source and file hashes across nodes;
do not use the previous tar verification as proof that later code edits were
also staged. The 40-clip LAFAN1 catalog is `~/moonrobo/data/manifest.json`;
check its CSV, URDF and mesh hashes with
[`preflight_g1_smc_node.mbtx`](../scripts/preflight_g1_smc_node.mbtx) once the
runtime and complete assets exist. The script currently expects a Python
executable and MoonBit CLI in the same filesystem view, so its old host
example with `/opt/smc-env/bin/python` was invalid for a container-only
runtime. The USD now exists, but passing the complete preflight still needs
to be recorded. The container commands
below use the real `~/moonrobo` tree and the image interpreter instead.

The pinned kit-less image has been built on 179 and loaded on 178 as recorded
in the [Spark runtime plan](DGX_SPARK_PINNED_RUNTIME_PLAN.md). The USD was
converted offline from `~/moonrobo/data/g1_description/g1_29dof.xml` into
`~/moonrobo/data/g1_usd/g1_29dof/g1_29dof.usda` using that pinned importer.
Inspect the expected 29-joint order in the loaded runtime. Its payload files must remain
alongside the `.usda`; checkpoint identity binds the selected USD path and
SHA-256. A changed USD at the same path is rejected on resume. The small
Newton/model/actor/critic gate passed on 179, and both a separate two-rank
NCCL collective and the bounded distributed trainer gate passed over RoCE.
Both ranks executed physical and learner updates. Sustained memory behavior
and matched-budget learning evaluation remain necessary before comparison
of the long runs. The catalog is the 40-clip LAFAN1 comparison, not the paper's
BONES-SEED scale or a held-out-motion claim.

The separate MoonBit APIC bundle inspector
[`inspect_g1_apic_bundle.mbtx`](../scripts/inspect_g1_apic_bundle.mbtx) can
check graph hashes once a real four-graph bundle exists. None is installed on
these hosts, and the Python/Isaac trainer does not consume it.

## Independent seeds: future 128-env launch

The following is a **future command**, not one already executed. Use it on
178 only after the pinned image, USD, refreshed source and small update gate
are verified. It keeps the actual host tree at `~/moonrobo`; the container
sees it at `/workspace/moonrobo`. The `80g` cgroup limit is a starting host
protection cap, not a measurement of peak usage or a guarantee for unified
GPU allocations.

```bash
cd ~/moonrobo
mkdir -p runs/g1-smc-stage-seed178
docker run --rm --gpus all --memory=80g --memory-swap=80g --shm-size=8g \
  --user "$(id -u):$(id -g)" \
  -e HOME=/workspace/moonrobo/runs/g1-smc-stage-seed178 \
  -e WARP_CACHE_PATH=/workspace/moonrobo/runs/g1-smc-stage-seed178/warp-cache \
  --mount type=bind,src="$PWD",dst=/workspace/moonrobo \
  --workdir /workspace/moonrobo moonrobo-isaaclab:46d6cc3-kitless \
  /opt/isaaclab-venv/bin/python -m providers.motion_learning.aligned.train \
  --config examples/learning/g1-smc-spark-stage-178.json \
  --backend isaac --device cuda:0 \
  --motion-dir /workspace/moonrobo/data/lafan1_g1 \
  --motion-manifest /workspace/moonrobo/data/manifest.json \
  --scene /workspace/moonrobo/data/g1_description/g1_29dof.xml \
  --usd-path /workspace/moonrobo/data/g1_usd/g1_29dof/g1_29dof.usda \
  --output /workspace/moonrobo/runs/g1-smc-stage-seed178
```

On 179 use `g1-smc-spark-stage-179.json` and
`runs/g1-smc-stage-seed179` consistently in the command. Each process uses
its own `cuda:0` and needs no rendezvous. The trainer refuses to overwrite an
existing checkpoint; use `--resume` with the same inputs to warm-restart.
The Isaac physical state cannot be resumed exactly: learner weights,
optimizers and sampler restore, then new physical episodes refill replay.
Evaluate only after recording the run's environment count and physical work;
evaluation steps all allocated slots while measuring one at a time.

## Two-host data parallel: separate experiment

For the bounded one-iteration gate, use
[`run_spark_ddp_gate.mbtx`](../scripts/run_spark_ddp_gate.mbtx) separately on
each host with its canonical repository path, rank and the same fresh run ID:

```bash
moon run --target native scripts/run_spark_ddp_gate.mbtx /home/wlc003s/moonrobo 0 gate-20261024-a
```

On 179 use `/home/wlc004s/moonrobo 1 gate-20261024-a`. Confirm those home paths
on the host; the script requires a canonical path and does not SSH or deploy
itself. It uses the already loaded immutable RDMA image ID, 128 environments
per rank, original network widths/bf16 and 8/32 horizons, but only one model,
one actor and four critic updates. Skipping model-only warmup iterations here
exercises every optimizer and is not the paper training curriculum. Outputs
are fresh `runs/spark-ddp-gate-<id>/rank0000` or `rank0001` directories; reusing
an existing rank output is refused. Source/assets are mounted read-only.

The gate preserves the 80 GiB cgroup cap, 8 GiB shared memory and learner
memory guard. Static rendezvous at `10.0.0.1:29500` has a 60-second timeout,
automatic restarts are disabled, and the container command has a 420-second
deadline with a five-second kill grace. The launcher also limits the attach
to 450 seconds and removes only the container ID it created. It preserves
launch arguments, stdout/stderr, torchrun/NCCL logs and container state,
then checks the rank report/checkpoint and a clean non-OOM exit.
It requires `moonbitlang/async@0.22.5` for shell-free command orchestration.

The actual `gate-20261024-a` run passed on both hosts. Each rank recorded
8,448 physical transitions, 4,096 imagined steps, one world-model update,
one actor update and four critic updates, with `NET/IB/0` and `GDR 0`.
The recorded cgroup peaks were 5,337,329,664 bytes on 178 and 5,211,684,864
bytes on 179. Each rank's reported PyTorch peak was 1,643,218,432 bytes;
this allocator statistic excludes some simulator allocations. Both had
zero OOM events under the unchanged caps. This verifies bounded distributed
execution, not superior speed or convergence. Use a new run ID for a repeat;
the launcher refuses to overwrite the completed gate output.

The preserved trainer has no CLI process-group timeout option. Its NCCL
watchdog monitoring is supplemental; the launcher does not mislabel the
60-second heartbeat setting as a collective-operation timeout. The hard
container deadline bounds the complete run. See the pinned
[PyTorch static rendezvous implementation](https://github.com/pytorch/pytorch/blob/v2.11.0/torch/distributed/elastic/rendezvous/static_tcp_rendezvous.py#L92-L118)
and [PyTorch 2.11 NCCL environment variables](https://docs.pytorch.org/docs/2.11/torch_nccl_environment_variables.html).

Use the **same** 128-env stage config on both machines. `num_envs=128`,
`wm_batch=128`, and `pi_batch=128` are per rank, so the two-host global
collection and learning batches are 256 each. Rank-specific seeds separate
physics and replay streams. Rendezvous must be reachable between the training
hosts; `10.0.0.1:29500` passed the bounded gate and must be available for the
new run. This is a future long-run command. On
178:

```bash
cd ~/moonrobo
mkdir -p runs/g1-smc-stage-ddp
docker run --rm --gpus all --network host \
  --memory=80g --memory-swap=80g --shm-size=8g \
  --user "$(id -u):$(id -g)" \
  -e HOME=/workspace/moonrobo/runs/g1-smc-stage-ddp \
  -e WARP_CACHE_PATH=/workspace/moonrobo/runs/g1-smc-stage-ddp/warp-cache \
  -e NCCL_SOCKET_IFNAME=enp1s0f1np1 \
  -e GLOO_SOCKET_IFNAME=enp1s0f1np1 \
  --mount type=bind,src="$PWD",dst=/workspace/moonrobo \
  --workdir /workspace/moonrobo moonrobo-isaaclab:46d6cc3-kitless \
  /opt/isaaclab-venv/bin/torchrun --nnodes=2 --nproc-per-node=1 \
  --node-rank=0 --master-addr=10.0.0.1 --master-port=29500 \
  -m providers.motion_learning.aligned.train --distributed \
  --config examples/learning/g1-smc-spark-stage.json \
  --backend isaac --device cuda:0 \
  --motion-dir /workspace/moonrobo/data/lafan1_g1 \
  --motion-manifest /workspace/moonrobo/data/manifest.json \
  --scene /workspace/moonrobo/data/g1_description/g1_29dof.xml \
  --usd-path /workspace/moonrobo/data/g1_usd/g1_29dof/g1_29dof.usda \
  --output /workspace/moonrobo/runs/g1-smc-stage-ddp
```

Run the same command on 179 with `--node-rank=1`,
`NCCL_SOCKET_IFNAME=enp1s0f0np0`, `GLOO_SOCKET_IFNAME=enp1s0f0np0`, and the
same `10.0.0.1:29500` rendezvous. Check the route and port from inside both
containers before training. Socket interface binding selects the TCP
bootstrap/Gloo path; it does not itself prove that NCCL's data transport uses
ConnectX-7 RDMA. Start both ranks within the torchrun rendezvous timeout. Each rank
keeps its own physical environment and replay; model, actor and critic
gradients are reduced before their optimizer steps. Preserve both rank reports
and checkpoints. A distributed checkpoint is not interchangeable with an
independent-seed checkpoint. Do not infer convergence speed from the number of
iterations alone: compare aggregate physical/imagined transitions, normalized
return and termination failures, wall time, and GPU-hours. The two methods
also have different global batch sizes under this unchanged per-rank config.
The two ranks average their adaptive reset difficulty estimates between outer
iterations; episode completions within an iteration first update each rank's
local sampler. This is a distributed extension of the `smc` sampler, not an
exact globally pooled sampler at every reset.

The separate [ConnectX-7 RDMA experiment](DGX_SPARK_CONNECTX7_RDMA.md)
records the verified numerical collective and host verbs devices and provides a derived image
with userspace providers, device passthrough and exact per-node NCCL HCA/GID
selection. Its bounded collective and two-host learner gates passed with
GPUDirect disabled, in separate output directories. The socket
command above is unchanged. Neither the small collective nor the earlier
file-copy rate establishes NCCL/RDMA training throughput or 200 Gb/s bandwidth.

## MoonBit training boundary

[`run_g1_aligned.mbtx`](../scripts/run_g1_aligned.mbtx) now launches the
MoonBit learner, and [`src/learning_aligned/cmd`](../src/learning_aligned/cmd/main.mbt)
can select an actual CUDA APIC physics adapter. Its numerical learner currently
requires `device=cpu`, `amp=none` and reports `moonbit-scalar-f64`. The native
CUDA APIC adapter requires a real four-graph bundle and matching shared
library. Both have now been built/exported on 179: bounded export h produced
the approximately 40 MiB bundle with manifest SHA-256
`38d67d87cb0c9294fc7c9cb7635b6b9a88587f23a0036bdeb3cb6de2d1fb9b51`,
exit 0 and no OOM. Its next native replay audit passed 20 operations on two
worlds under an 8 GiB cap with exit 0 and no OOM. Independent eager-SDK
numerical parity and full training with native GPU physics remain separate
verification steps; see the [APIC plan](DGX_SPARK_APIC_EXPORT_PLAN.md).
The parallel `src/learning_aligned_gpu/cmd` now integrates a Float32 LibTorch
tensor learner and bounded runtime. After fixing missing pinned MuJoCo build
headers and selecting the actuator-equipped scene, its 2-env GB10 CUDA
learner with CPU MuJoCo physics passed and resumed through iteration 2.
This does not verify native Newton/APIC GPU physics or uninterrupted-versus-
resumed CUDA numerical equality. A subsequent two-host native DDP gate also
passed with 2 environments per rank and one synchronized iteration; its
[rank-0](../output/spark-runtime-20261024/native-ddp/178/runs/native-ddp-gate-20261024-c/rank-0/report.json)
and [rank-1](../output/spark-runtime-20261024/native-ddp/179/runs/native-ddp-gate-20261024-c/rank-1/report.json)
reports record 36 physical and 64 imagined transitions per rank, plus one
model, one actor and four critic rank-local update operations. Their global
work counters sum to 72/128 transitions and 2/2/8 rank-local operations;
there was still only **one synchronized update iteration**. NCCL selected
`NET/IB` with `GDR 0`; both containers exited 0 without OOM-kill. Peak memory
was not measured for that first gate. A later native gate measured
3,062,317,056 / 3,065,729,024 bytes of actual cgroup peak memory and zero OOM
events, and attested equal shared learner state before saving. A separate
CPU audit also verified the first gate's saved weights, Adam and normalizers;
see the [RDMA evidence record](DGX_SPARK_CONNECTX7_RDMA.md).
AMP/bf16 and distributed checkpoint resume remain unsupported. See the
[execution-path/build boundary](BONES_SEED_PAPER_FILTERS.md#current-execution-paths).
The native paths are **not yet equivalent substitutes for the Python Newton
GPU baseline**. A subsequent two-environment native APIC physics/CUDA learner
iteration passed on 179, including checkpoint readback, but its independent
SDK numerical comparison retains a failure. See the [native GPU execution
and numerical evidence](DGX_SPARK_APIC_EXPORT_PLAN.md). The distributed commands above use the preserved Python/CUDA learner;
the native DDP gate is a separate CPU-MuJoCo physics/CUDA learner execution.

Completed work now includes SHA-verified raw BONES-SEED staging on both hosts,
the pinned base/RDMA image build and transfer, a successful runtime import
probe on 179, and USD conversion with all transferred asset hashes verified.
Full MoonBit data conversion completed on 178 for 142,220 unfiltered clips and
124,554,605 source frames; partial paper filtering is running under a 16 GiB
CPU-only container limit and has not yet published its result. The unchanged small
runtime gate subsequently passed on 179, and the native two-host AllReduce
passed with verified values over RoCE. GPUDirect remained disabled, consistent
with NVIDIA's Spark architecture guidance. The bounded Python distributed
learner iteration also passed on both ranks. No evaluation score or sustained
training throughput has been verified. The
independent-seed and two-host long-run commands above remain future launch
templates subject to the remaining gates. Separately, the small native MoonBit
Float32 CUDA learner with CPU MuJoCo physics passed on 179 and continued from
its checkpoint. The separate native two-host learner gate also passed one
synchronized iteration. Those CPU-physics results and the later single-host
APIC execution gate do not establish GPU-physics equivalence, cross-host
resume, convergence or full BONES-scale training.
