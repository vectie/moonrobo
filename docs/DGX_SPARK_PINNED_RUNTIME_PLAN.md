# DGX Spark runtime for the G1 aligned CUDA trainer

This records the installed runtime and remaining training gates as checked on
2026-10-24. It applies to Linux aarch64 / GB10 hosts 178 and 179. The small
single-host physics/learner gate passed on 179. The native NCCL AllReduce
probe, bounded two-host Python learner gate and separate two-host MoonBit
Float32 CUDA learner gate passed over RoCE with GPUDirect disabled. Long-run
training results remain pending.
Both have staged the fixed Isaac Lab source archive at
`~/moonrobo/isaaclab-46d6cc3-source.tar.gz` and extracted it to
`~/moonrobo/IsaacLab`. The archive SHA-256 was checked on each host:
`8278fc60c636b314c5e85a46a69ae78fda2212094020da796aa7eb4070ce4d33`.
The archive has no `.git`, so an on-host `git rev-parse` is not a provenance
check. Both hosts now have the same pinned base and RDMA images. Source bundle v2 was
hash-verified and extracted on both nodes (see the deployment guide). The 40 LAFAN1 CSVs,
manifest, G1 MJCF and meshes are at `~/moonrobo/data`. The USD was converted
on 179; its complete eight-file output tree was transferred to 178 and all
file hashes compared successfully. Both nodes have the hash-verified
BONES-SEED G1 archive and all 142,220 extracted CSVs. Full MoonBit conversion
completed on 178 using a release build under an 8 GiB virtual-memory limit:
the unfiltered `~/moonrobo/private/bones-seed/aligned-g1-v1` catalog contains
142,220 clips and 124,554,605 source frames. Partial paper filtering has not
started; transfer of the converted catalog to 179 is not yet evidenced.
The CUDA training entry point is the preserved
`providers/motion_learning/aligned/train.py` with `--backend isaac`. The
independent-seed and two-host commands live in
[`G1_SMC_178_179_DEPLOYMENT.md`](G1_SMC_178_179_DEPLOYMENT.md).

## Verified runtime artifacts and current gate

The images built on 179 and loaded on 178 have these image IDs:

| Image tag | Image ID |
| --- | --- |
| `moonrobo-isaaclab:46d6cc3-kitless` | `sha256:70d9f9b99a5cf08bbf0e43c2bc64eee1ce19e93f219c76d1f4fd9f2f911dd2c7` |
| `moonrobo-isaaclab:46d6cc3-kitless-rdma` | `sha256:989985f4b65447e4452fcfeeec70cfa3f48eb52637f8f96e41a736f11ab308cd` |

The Docker archive containing both images is 10,779,234,816 bytes, SHA-256
`b8087904996ebedc8870d97b90c557149518ae21563d6c0ebdc6384055692cd9`.
That archive was hash-verified before loading on 178.

The actual 179 import/device probe passed with torch `2.11.0+cu130`, CUDA
`13.0`, GB10, NCCL `2.28.9`, Newton `1.8.0.dev0`, MuJoCo and MuJoCo-Warp
`3.15.0`, Warp `1.17.0`, isaaclab `41.0.0`, and isaaclab-newton `10.0.0`.
This verifies that runtime on 179; the same image's presence on 178 is not a
substitute for its own device/runtime check.

The first 128-environment, one-iteration gate on 179 was refused **before
physics or learner updates** by the memory guard: estimated peak 26.21 GiB,
CUDA-reported free memory 9.75 GiB, allowed budget 6.34 GiB. These are planning
values, not measured training peaks. File-specific advice on this task's
completed archives raised reported free memory to about 39.3 GiB; the same
65% rule still requires approximately 40.4 GiB for this estimate. The guard
has not been bypassed. A bounded helper for the idle, extracted source tree
is [`evict_training_file_cache.mbtx`](../scripts/evict_training_file_cache.mbtx).
It requires an explicit canonical root ending `/source/g1/csv` and a positive
maximum CSV count, uses GNU `dd iflag=nocache,nofollow count=0` per regular CSV,
and neither reads payload bytes nor changes files or global cache settings.
Cache advice does not guarantee reclaimed memory; re-measure before retrying
the unchanged gate. Do not run it against the source tree while conversion
actively consumes that tree.

After task-specific cache management, the unchanged 128-environment,
one-iteration gate passed on 179: 8,448 physical transitions, 4,096 imagined
steps, one world-model update, one actor update and four critic updates in
68.152 seconds, with a roughly 217 MB checkpoint and no observed OOM.
The [report](../output/spark-runtime-20261024/report.json) and
[runtime log](../output/spark-runtime-20261024/g1-runtime-gate-179.log) preserve
the evidence. This verifies one small execution, not a long-run peak-memory
bound or learning quality. Both hosts subsequently completed the distributed
gate below, including 178's physical and learner updates.

The native MoonBit/C NCCL probe subsequently passed on both hosts using the
same RDMA image and CUDA 13.0 / NCCL 2.28.9 libraries. Both logs show the
expected HCA, `Using network IB`, `NET/IB/0` and `GDR 0`. All 1 MiB results
were verified across one warm-up and three timed operations. The
[RDMA record](DGX_SPARK_CONNECTX7_RDMA.md) separates this successful RoCE
collective from GPUDirect, which the official Spark porting guide excludes,
and from sustained throughput.

The bounded Python distributed gate `gate-20261024-a` then passed on both
hosts with 128 environments per rank and one learner iteration. Rendezvous
used `10.0.0.1:29500`; NCCL selected `NET/IB/0` with `GDR 0`. Each rank
recorded 8,448 physical transitions, 4,096 imagined steps, one world-model
update, one actor update and four critic updates. The recorded cgroup peaks
were 5,337,329,664 bytes on 178 and 5,211,684,864 bytes on 179; the reported
PyTorch peak was 1,643,218,432 bytes on each rank. Both reported zero OOM
events under the unchanged 80 GiB caps. These counters cover this bounded
gate, not the full training profile, and PyTorch's allocator statistic does
not include every Newton/Warp allocation. No matched throughput or
convergence comparison with independent seeds has been completed.

The separate native MoonBit Float32 CUDA learner also passed a 2-env gate on
179, using **CPU MuJoCo physics**, then resumed through iteration 2. The first
iteration recorded 36 physical / 64 imagined transitions and 1 model / 1 actor
/ 4 critic updates; the resumed cumulative counts were 42 / 128 and 2 / 2 / 8.
It ran under a 16 GiB container cap without observed OOM; peak memory was not
measured. The runtime reported exact checkpoint resume, but a CUDA bitwise
comparison against uninterrupted execution has not been performed. The native
image, binary, matching MuJoCo header ABI and actuator-equipped scene hashes
are recorded in the [native execution boundary](BONES_SEED_PAPER_FILTERS.md#current-execution-paths).
This result does not establish native Newton/APIC GPU physics or bf16. A
subsequent [178 rank-0 report](../output/spark-runtime-20261024/native-ddp/178/runs/native-ddp-gate-20261024-c/rank-0/report.json)
and [179 rank-1 report](../output/spark-runtime-20261024/native-ddp/179/runs/native-ddp-gate-20261024-c/rank-1/report.json)
record a separate two-host, one-iteration native DDP gate with 2 environments
per rank, Float32 CUDA learning and CPU MuJoCo physics. Per rank, the gate
performed 36 physical transitions, 64 imagined transitions, one model, one
actor and four critic update operations. Summed global work was 72 physical,
128 imagined and 2/2/8 rank-local model/actor/critic operations; this remains
**one synchronized update iteration**. The logs show `NET/IB` and `GDR 0`;
both containers exited 0 with `OOMKilled=false`. Actual peak memory was not
measured and distributed resume is unsupported. This is a runtime gate, not
evidence of convergence or full-data throughput.

The later `native-ddp-20261024-d` iteration recorded actual cgroup peaks of
3,062,317,056 / 3,065,729,024 bytes and zero OOM events, and both trainers
attested identical parameters, Adam state and all normalizers before save.
The original native gate's checkpoints also passed a separate CPU semantic
comparison. The [RDMA evidence record](DGX_SPARK_CONNECTX7_RDMA.md) links both
rank verifications and the semantic comparison; the original wrapper JSON
decoding failure remains preserved alongside its read-only corrected result.

## Version boundary

Use the Isaac Lab source checkout at
[`46d6cc3d7b115906fad12efd372fbf69f4e3d3ed`](https://github.com/isaac-sim/IsaacLab/commit/46d6cc3d7b115906fad12efd372fbf69f4e3d3ed)
and its committed [`uv.lock`](https://github.com/isaac-sim/IsaacLab/blob/46d6cc3d7b115906fad12efd372fbf69f4e3d3ed/uv.lock).
That lock explicitly includes Linux aarch64 and selects Python 3.12,
`torch==2.11.0+cu130`, Newton Git revision
`71eeba16a717d4dcf0b9dd7056a7b6f863054dc3`, MuJoCo and MuJoCo-Warp
`3.15.0`, and Warp `1.17.0`. Its MuJoCo-Warp wheel is architecture-neutral;
MuJoCo and Warp each have aarch64 wheels in the lock. The pinned
[`Dockerfile.kitless`](https://github.com/isaac-sim/IsaacLab/blob/46d6cc3d7b115906fad12efd372fbf69f4e3d3ed/docker/Dockerfile.kitless)
uses `uv sync --frozen` and does not include Isaac Sim / Kit. Its aarch64
build, the 179 import probe, and the small 179 Newton/gradient-update gate are
verified, as is the subsequent bounded two-host learner iteration. That
evidence does not yet cover the full-scale profile.

Do not install this checkout on top of
[`providers/motion_learning/requirements.txt`](../providers/motion_learning/requirements.txt):
that separate CPU environment pins `torch==2.9.1` and `mujoco==3.3.7`, which
conflict with the Isaac Lab lock. Do not run `pip install -r` from this repo
inside the pinned Isaac runtime. Use the runtime's locked interpreter for the
aligned trainer. The adjacent `../smc` project builds the same Isaac Lab commit
and then a small derived image with compiler/tmux/ffmpeg; its reported RTX PRO
6000 result is not a DGX Spark benchmark.

NVIDIA's [Isaac Lab 3.0 installation guide](https://docs.nvidia.com/isaaclab/3.0/isaac-lab/installation)
explicitly lists Linux aarch64 / DGX Spark, requires CUDA 13 or newer with a
matching PyTorch build, and provides a standalone kit-less Newton image. Its
current release guidance is broader than this **older exact commit**; do not
replace the commit or lock with the public `3.0.0-kitless` image without a
separate compatibility evaluation. [NVIDIA's Spark container-runtime guide](https://docs.nvidia.com/dgx/dgx-spark/nvidia-container-runtime-for-docker.html)
says the NVIDIA Container Toolkit is preinstalled on DGX Spark, but each host
needs user access to Docker and a device/runtime check. Docker access is
working on both hosts; the pinned GPU import probe has passed on 179.

## Read-only host checks, one host at a time

SSH password access has already allowed basic inspection. Both hosts reported
one GB10, driver 580.178.04 and CUDA 13.0, with no compute process at that
time. The following checks can be repeated before image work; they do not
start a model service or change 175–177:

```bash
uname -m
cat /etc/os-release
nvidia-smi
docker version
docker info --format '{{.Architecture}} {{.Runtimes}}'
id -nG
df -h /
git --version
```

Expected architecture is `aarch64`; check driver compatibility against the
pinned CUDA 13 stack. Isaac Lab 3.0 lists Linux driver `580.65.06` or newer,
but the **installed** driver and firmware decide whether this image runs. If
Docker access fails, resolve that on the target account; do not silently use
`sudo` or change host groups. NVIDIA documents the GPU container check as:

```bash
docker run --rm --gpus=all --memory=80g --memory-swap=80g \
  nvcr.io/nvidia/cuda:13.0.1-devel-ubuntu24.04 nvidia-smi
```

This pulls an image; treat it as a separate runtime validation once the node
is available. On Spark, `nvidia-smi` may report GPU `Memory-Usage: Not
Supported` because the GB10 uses unified memory; that field alone is not a
failure ([NVIDIA known issues](https://docs.nvidia.com/dgx/dgx-spark/known-issues.html)).

## Image rebuild procedure

Use the already extracted source at `~/moonrobo/IsaacLab`, independent of
`../smc` and of the MoonRobo Python package environment. Do this only when
the training hosts are available; record the resulting image ID from both
hosts. The build requires outbound access to GitHub for Newton and rl_games and to PyPI,
NVIDIA PyPI and the PyTorch CUDA index, plus enough disk for the dependency
graph. No exact image-size or build-time claim is made. Verify the archive
again before building; do not substitute a mutable Git branch:

```bash
cd ~/moonrobo
sha256sum isaaclab-46d6cc3-source.tar.gz
test -f IsaacLab/uv.lock
test -f IsaacLab/docker/Dockerfile.kitless
docker build --platform linux/arm64 \
  --file IsaacLab/docker/Dockerfile.kitless \
  --tag moonrobo-isaaclab:46d6cc3-kitless IsaacLab
docker image inspect moonrobo-isaaclab:46d6cc3-kitless \
  --format '{{.Id}} {{.Architecture}} {{.Os}}'
```

The `sha256sum` output must equal the verified digest above. Build from the
same extracted commit/lock on both nodes. The image's default user is uid
1000. Mount readable code/assets and a writable output/cache directory with compatible
ownership. The image places its Python at `/opt/isaaclab-venv/bin/python`.

### GitHub transport fallback without changing the lock

The curated `all` extra also selects `rl_games` at
`5cf4f9ff07e9a01bbefd167cf19b6804b294b51c`. If either GitHub fetch stalls,
use [`prepare_isaaclab_offline_git.mbtx`](../scripts/prepare_isaaclab_offline_git.mbtx)
on a host with GitHub access. It requires a new output directory, verifies the
exact source `pyproject.toml`, `uv.lock` and Dockerfile hashes, fetches both
complete Git histories at their fixed revisions, runs `git fsck`, and rejects
unmirrored submodules. It generates an additive Dockerfile and an archive of
bare repositories. The original source files remain untouched. Example on the
workstation, using a fresh output path:

```bash
moon run --target native scripts/prepare_isaaclab_offline_git.mbtx \
  /Users/kq/Workspace/moonrobo/target/isaaclab-source \
  /Users/kq/Workspace/moonrobo/output/isaaclab-offline-git-new
```

The completed `output/isaaclab-offline-git-20261024-v2/` package is 427 MiB.
Its `isaaclab-offline-git.tar.gz` SHA-256 is
`922aff4c0be9cc5e1558e0d07451070a5e19417e1f75adf78e3212e452efe7c9`;
the adjacent `provenance.json` records both commit/tree identities and the
source/overlay hashes. A local fetch into empty repositories using uv's fetch
arguments, with `GIT_ALLOW_PROTOCOL=file`, succeeded for both dependencies.
After transferring the archive and checking its digest on the training host:

```bash
cd ~/moonrobo
sha256sum isaaclab-offline-git.tar.gz
tar -xzf isaaclab-offline-git.tar.gz -C IsaacLab
sha256sum IsaacLab/uv.lock IsaacLab/Dockerfile.kitless.offline-git
```

The lock must remain
`44534d4d3c84575686e1f31f192a5ab3c21612c6f8db6da43fa1b56a2b79535e`,
and this generated Dockerfile must be
`fd2c23d7d8f38089d4bda82d0a6227b52027420c0b185be39f9b421d315d7734`.
Build with the same resource, platform, frontend and base-image arguments as
the original build, replacing only its file argument with
`--file IsaacLab/Dockerfile.kitless.offline-git`. The six added lines copy the
Git mirrors into the builder and configure exact HTTPS URL replacements with
local `file://` URLs. The frozen dependency graph, selected extras, and Git
commit identities are unchanged; OCI layers, apt and wheel downloads still
require network access. This is a Git transport fallback, not a fully offline
installation.

`uv.lock` pins the application package graph but does not make this complete
image bit-reproducible. Upstream uses a mutable Ubuntu tag, apt repository
state, seeded pip, and build-backend version ranges (Newton uses
`uv_build>=0.11.0`; rl_games uses `poetry-core>=1.0.0`). Record the immutable
base/frontend digests, final image ID, installed Python distribution list,
and OS package versions. Mirror substitutions must retain the official OCI
digests. Do not resolve these build limitations by regenerating the project
lock or changing its package versions.

For the separate ConnectX-7 RDMA experiment, the derived
[`Dockerfile.spark-rdma`](../docker/Dockerfile.spark-rdma) adds userspace verbs
packages to this exact base without touching Python dependencies. Its device
mapping, memory limits and per-node interface settings are documented in
[`DGX_SPARK_CONNECTX7_RDMA.md`](DGX_SPARK_CONNECTX7_RDMA.md). Host RDMA
enumeration is not evidence of a working NCCL collective.

The adjacent [`smc` Dockerfile](../../smc/docker/Dockerfile) adds a compiler
because `smc` explicitly uses `torch.compile`. The current aligned trainer does
**not** call `torch.compile`, so that wrapper is not an installation
requirement for this baseline. Add a compiler only if a measured runtime path
requires one; do not import the `smc` wrapper's x86 benchmark assumptions.

After the image exists, the first container import check can use its locked
interpreter. The cap limits cgroup memory/swap for this initial validation;
it is not a measured GPU-memory peak or proof that all GB10 unified-memory
allocations are contained:

```bash
docker run --rm --gpus all --memory=80g --memory-swap=80g \
  moonrobo-isaaclab:46d6cc3-kitless \
  /opt/isaaclab-venv/bin/python -c \
  'import torch, isaaclab.sim, isaaclab_newton.physics, newton, mujoco, mujoco_warp, warp; print(torch.__version__, torch.version.cuda, torch.cuda.is_available(), torch.cuda.get_device_name(0))'
```

This imports packages and probes the GPU, but does not load the robot, step
Newton physics or run any optimizer. It should be followed by the smaller
runtime gates below. The actual trainer container mounts the real
`~/moonrobo` source/data tree and writable `~/moonrobo/runs` as shown in the
[deployment guide](G1_SMC_178_179_DEPLOYMENT.md), still subject to runtime
and asset gates.

The USD importer ran successfully on 179, and the complete eight-file result
was hash-verified after transfer to 178. The following is the retained
conversion procedure for rebuilding assets, with the same initial
memory/swap cap as the stage run. Transfer the **entire resulting USD
directory** and verify all payload hashes when regenerating it:

```bash
cd ~/moonrobo
mkdir -p data/g1_usd runs/asset-import-cache
docker run --rm --gpus all --memory=80g --memory-swap=80g \
  --user "$(id -u):$(id -g)" \
  -e HOME=/workspace/moonrobo/runs/asset-import-cache \
  --mount type=bind,src="$PWD",dst=/workspace/moonrobo \
  --workdir /workspace/moonrobo moonrobo-isaaclab:46d6cc3-kitless \
  /opt/isaaclab-venv/bin/python -m providers.motion_learning.aligned.assets \
  --mjcf /workspace/moonrobo/data/g1_description/g1_29dof.xml \
  --usd-output /workspace/moonrobo/data/g1_usd
```

Before training, compare the generated USD and all payload hashes across
hosts, inspect its 29-joint order, and retain the exact asset paths in the
checkpoint identity. This conversion command is not a physical stepping test.

## Gates before scale training

1. The pinned import/device gate passed on 179. Repeat on 178 and record
   `python --version`, `torch.__version__`,
   `torch.version.cuda`, `torch.cuda.get_device_name(0)`, and distributions for
   `newton`, `mujoco`, `mujoco-warp`, `warp-lang`, `isaaclab`,
   `isaaclab-newton`. Confirm `torch.cuda.is_available()` and import
   `isaaclab.sim`, `isaaclab_newton.physics`, `newton`, `mujoco_warp`, `warp`.
2. Verify the already staged 40 CSVs, robot URDF/meshes and compiled MJCF on
   both hosts. The USD/payload hash comparison has passed; retain its payloads
   beside it. Use
   [`preflight_g1_smc_node.mbtx`](../scripts/preflight_g1_smc_node.mbtx)
   to compare file hashes, including the robot catalog, after the asset and
   image are present. Inspect the converted asset's 29-joint order; a file hash cannot prove
   simulator semantics.
3. The separately labelled **128-environment**, one-iteration Isaac physical
   rollout and world-model / actor / critic update gate passed on 179 as
   recorded above. Both ranks also passed the distributed gate, with the
   recorded memory peaks. Establish sustained memory behavior before
   considering a larger run. This actual Newton/Warp/autograd result is
   distinct from earlier CPU and source checks. The trainer presently rejects unmeasured `>512` environments
   or model/actor batch and rejects a planning peak above 65% of available
   cgroup/CUDA memory; a refusal is a stop condition, not a reason to disable
   the guard.
4. For two-host data parallel, independently verify TCP rendezvous and NCCL
   connectivity between 178 and 179, then preserve rank-specific reports and
   checkpoints. The direct ConnectX-7 interfaces are `enp1s0f1np1` at
   `10.0.0.1/24` on 178 and `enp1s0f0np0` at `10.0.0.2/24` on 179. Both
   reported a 200 Gb/s link, ICMP about 0.3–0.5 ms, and 178 could reach 179's
   TCP port 22. A subsequent bounded native AllReduce verified both NCCL
   ranks and RoCE selection, with GDR disabled. The subsequent bounded
   Python gate verified port 29500 rendezvous and synchronized learner
   updates. Sustained throughput remains **unverified**.
   The [deployment template](G1_SMC_178_179_DEPLOYMENT.md)
   binds each rank's `NCCL_SOCKET_IFNAME` and `GLOO_SOCKET_IFNAME` to its own
   interface and uses `10.0.0.1` for rendezvous; those socket settings alone
   do not force NCCL's data path over RDMA. A passing single-host runtime is
   insufficient evidence for cross-host collectives. Compare normalized
   return and failures at matched global physical and imagined transition
   budgets, as well as wall time and GPU-hours; the current distributed config
   doubles the global batch.

On 2026-10-24, the first 179 build failed fetching the Dockerfile frontend
from Docker Hub. A new build uses the DaoCloud mirror with the same official
frontend digest `sha256:4edf897a3ffa55b89f906fc8cc78afdb3f1834cc9c7083565e611a8a7d5fe99e`
and Ubuntu 24.04 digest
`sha256:68ee22004a9109b44973313b02ff7b1de250f1de0f5ecb628d73f579aaff33ac`.
Both digests were independently read from Docker Hub on the workstation.
The subsequent pinned build completed on 179 and was saved/transferred to
178 together with the RDMA layer. The build used Buildx
`--resource memory=16g --resource memory-swap=16g --resource cpu-quota=400000`
per build step; these are build limits, not training memory measurements.
The original mirror-build log is `~/moonrobo/isaaclab-build-mirror.log` on
179. Image imports and USD conversion are complete as detailed above.
The small 179 physical rollout and model/actor/critic updates, plus a separate
two-host numerical NCCL/RoCE collective and bounded Python distributed
learner gate, have now passed. The separate two-host native Float32 CUDA
learner/CPU-MuJoCo gate also passed one synchronized iteration. Full
unfiltered BONES-SEED conversion completed on 178; paper filtering,
learning-quality evaluation and sustained training throughput remain
pending. No 200 Gb/s result is claimed. The separate
[genuine APIC export](DGX_SPARK_APIC_EXPORT_PLAN.md) now produced all four
graphs on 179 in bounded run h, approximately 40 MiB, with exit 0 and no OOM.
Its manifest SHA-256 is
`38d67d87cb0c9294fc7c9cb7635b6b9a88587f23a0036bdeb3cb6de2d1fb9b51`.
The subsequent native replay audit passed 20 operations on two worlds under
an 8 GiB cap, exit 0 and no OOM, including reset isolation, context values
and refresh invariants. The subsequent two-environment native APIC/CUDA
learner also completed one iteration, saved a checkpoint and passed CPU
readback against its pre-save learner-state attestation. The sampled kernel
peak was 2,588,884,992 bytes under a 48 GiB cap, with no OOM observed; the
monitor does not certify the final lifetime peak after cgroup deletion.
Independent eager SDK numerical comparisons retain a failure, despite
passing against a second SDK repeat. Numerical equivalence and full
training remain unverified; the [APIC evidence](DGX_SPARK_APIC_EXPORT_PLAN.md)
preserves both passing and failing comparisons without changing tolerance.
