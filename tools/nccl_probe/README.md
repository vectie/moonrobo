# Bounded two-rank CUDA/NCCL numeric probe

This native MoonBit command with a small C FFI stub verifies a real two-rank
in-place float32 sum. It preserves the Python learner and uses the CUDA and
NCCL shared libraries from the installed, pinned training image. It does not
load a robot or a policy. No successful remote collective is implied by the
source/build checks.

The probe requires exactly NCCL `2.28.9` (`22809`) and CUDA Runtime `13.0`
(`13000`). It selects CUDA device 0 inside the container. It validates every
element after one warm-up and three timed reductions, refilling the input
each time. Rank `r` sends `(r+1) + (index % 101)/4`; the expected result is
`3 + (index % 101)/2`, exactly representable in float32. Incorrect values,
missing symbols, API failures and version mismatches exit unsuccessfully.

Specify 262,144 elements for the initial check: 1 MiB host buffer plus 1 MiB
device buffer per process. The hard maximum is 2,097,152 elements (8 MiB each,
16 MiB combined). CUDA/NCCL internal allocations are additional and are not
bounded by that payload limit. The command refuses CUDA free memory below
1 GiB; retain an external cgroup cap and the prerequisite runtime/memory
gates. This check is not a reason to bypass a training guard refusal.

## Build requirements

Build on Linux aarch64 with the installed MoonBit native toolchain, the
module's `moonbitlang/async@0.20.2`, a system C compiler and libdl. The stub
includes only `moonbit.h` and POSIX/libc headers; nvcc, CUDA/NCCL development
headers, CMake and Python are unnecessary. Its limited ABI declarations use
the [NCCL 2.28.9 public C API](https://github.com/NVIDIA/nccl/blob/v2.28.9-1/src/nccl.h.in)
and [CUDA Runtime 13.0 types](https://docs.nvidia.com/cuda/archive/13.0.0/cuda-runtime-api/group__CUDART__TYPES.html),
with exact runtime version checks. It does not declare internal driver or
communicator layouts.

From the MoonRobo root on the host:

```bash
moon -C tools/nccl_probe build --target native --release cmd
```

The executable is
`tools/nccl_probe/_build/native/release/build/cmd/cmd.exe`. Mount the built
binary into the exact pinned image; no compiler is needed in that image.
Run both ranks with the same binary hash and image ID. Discover and pass
absolute paths to the image's own `libnccl.so.2` and `libcudart.so.13`; do
not rely on a different host installation or a fallback `LD_LIBRARY_PATH`.
The CUDA library loads first with global visibility, then NCCL. Standard
NVIDIA container driver injection remains required.

## Bootstrap and bounded execution

Command arguments are:

```text
cmd.exe RANK ID_FILE LIBNCCL LIBCUDART FLOAT_ELEMENTS
```

All paths must be absolute. Rank 0 creates a new 128-byte ID file with mode
0600 using atomic rename, prints `NCCL_ID_READY`, and remains alive while
initializing the communicator. Transfer that file to rank 1 over the existing
SSH connection and start rank 1 immediately using its local copy. Rank 1
requires an existing regular file of exactly 128 bytes. Use a fresh ID path
for each run. Do not reuse an ID from an exited or timed-out rank 0:
`ncclGetUniqueId` creates live bootstrap state in that process. No custom
bootstrap sockets or SSH orchestration are implemented inside the probe.

The process starts a 55-second SIGALRM deadline before loading either library.
It exits with code 124 on timeout, including when communicator initialization
or stream synchronization blocks. As an additional outer limit, invoke the
binary through GNU timeout:

```text
timeout --signal=TERM --kill-after=2s 58s /absolute/path/cmd.exe 0 /absolute/new/id /absolute/libnccl.so.2 /absolute/libcudart.so.13 262144
```

The timeout begins with process launch, so it includes ID copying and rank
coordination. Stop and start a fresh pair if the coordination window expires.
The MoonBit orchestration wrapper
[`run_nccl_probe.mbtx`](../../scripts/run_nccl_probe.mbtx) invokes that same
timeout command and preserves stdout/stderr; it takes the binary path followed
by the five command arguments. It does not build or transfer files. GNU
timeout must be available wherever that wrapper runs.

Run only after the first physical runtime gate and fresh resource checks, in
a container with `--gpus all --network host`, `--memory=8g --memory-swap=8g`,
`--shm-size=1g`, `--device=/dev/infiniband --ulimit memlock=-1`, and the correct
readable binary/library and writable ID/output mounts. The 8 GiB cgroup cap
protects host memory but is not a proof of unified-memory containment on
GB10. A container-limit failure is a failed gate, not an invitation to remove
the limit. No privileged container or host driver changes are needed for this
probe.

## Transport and results

Set `NCCL_NET=IB` for the RDMA experiment or `NCCL_NET=Socket` for the explicit
socket comparison. Other or missing values are rejected. Supply the exact
HCA, IP-range and interface settings from
[`DGX_SPARK_CONNECTX7_RDMA.md`](../../docs/DGX_SPARK_CONNECTX7_RDMA.md).
Configure `NCCL_DEBUG=INFO` and `NCCL_DEBUG_SUBSYS=INIT,NET` externally and
capture each process's complete stdout/stderr, including NCCL's transport
and HCA selection lines. Successful output requires both ranks to exit 0,
both JSON reports to assert `all_elements_verified`, and reviewed logs showing
the intended transport. JSON records the requested transport; it does not
independently prove the selected hardware path or GPUDirect use.

The reported min/mean/max milliseconds cover `ncclAllReduce` plus stream
synchronization, exclude host/device copies, and use three post-warm-up
samples. They are a small correctness/latency check, not a saturation
benchmark or a measurement of the advertised 200 Gb/s link. Preserve the
reports, NCCL logs, image/binary/library hashes, device/runtime versions and
peak memory before advancing to actual distributed training.
