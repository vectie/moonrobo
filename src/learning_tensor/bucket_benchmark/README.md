# Paired NCCL communication benchmark

This executable measures the communication critical path of the current paper
network parameter layout. It does **not** execute physical sampling, imagined
rollouts, gradient calculation inside the timed region, normalizer collectives,
clipping or Adam. Results must not be presented as whole-training speedups or
backward/communication overlap. The separate
[`bucket_probe`](../GRADIENT_BUCKETS.md#differential-probe) checks reductions,
clipping, Adam state and nonfinite rejection before performance runs.

The executable instantiates the actual `WorldModel`, `Policy` and `Critic`
constructors from `learning_aligned_gpu/networks.mbt`, using Paper93 observations,
10-frame history and goals, and default paper network widths. It checks each
ordered parameter shape against the fixed benchmark contract before connecting
NCCL. The policy includes its encoder followed by its decoder; the world includes
LayerNorm weights and biases in their real optimizer order.

| Optimizer group | FP32 elements | Parameter tensors | Reductions/update: original → 16 MiB buckets | Updates/schedule |
| --- | ---: | ---: | ---: | ---: |
| World | 8,822,854 | 14 | 14 → 3 | 10 |
| Policy | 8,993,597 | 20 | 20 → 3 | 1 |
| Critic | 267,265 | 6 | 6 → 1 | 20 |
| Total | 18,083,716 | 40 | **280 → 53 per schedule** | 31 |

Parameters total 72,334,864 bytes. Before every warmup or measured schedule,
deterministic rank-dependent mean losses generate constant gradients through
backward, and the executable synchronizes before a matching rank control
collective. This setup is outside timing. Parameter values never change. The
10/1/20 reduction calls within a schedule reuse the resulting gradients, so the
first call averages local gradients and subsequent calls reduce that common
average. Both routes see the identical sequence. There is no RNG sampling in
the measured region.

Each route warms up three full schedules. Ten ABBA blocks then produce 20
original and 20 bucket samples per rank. All three network phases and each full
schedule have monotonic nanosecond host measurements and CUDA-event spans.
The same completion call follows each phase on both routes; it finishes the
original route's last division or the bucket route's final scatter. Host timing
includes that synchronization and telemetry query; event timing ends before the
host counter query. CUDA-event intervals are current-stream elapsed time,
including host submission gaps and communication waits, **not active NCCL kernel
time**. Full-schedule host timing also includes phase marker/telemetry overhead.

At startup the executable requires 17 GiB + 16 MiB CUDA free. Throughout the run,
both allocated and reserved allocator peaks must stay within **1 GiB + 16 MiB**,
and CUDA free must remain at least 16 GiB at observation boundaries. One bucket
is 16 MiB. These are CUDA allocator/working-set bounds, not a claim that driver,
LibTorch, MoonBit host arrays or process RSS fit inside the same amount. Launch
in a fresh **8 GiB process cgroup, zero swap, at most four CPUs** and retain the
actual cgroup peak. The existing checkpoints/data/model services are not used.
For RDMA registration, set **`--ulimit memlock=1073741824:1073741824`** on
the Docker container. Both executables and the wrapper read `/proc/self/limits`,
record the limits, and require finite soft/hard limits between 1 and 8 GiB.
The default 8 MiB limit caused `ibv_reg_mr_iova2: Cannot allocate memory`
during two-rank initialization; this is a pinned-memory registration limit,
separate from a cgroup/GPU OOM. Keep the existing cgroup and CUDA reserve limits.
Native errors now report their operation stage, rank and underlying message.

Build:

```text
moon build src/learning_tensor/bucket_benchmark --target native --release
```

Run the helper **inside** each already bounded CUDA/RDMA container. It performs
no SSH or container creation. Select the verified ConnectX interface/HCA in the
container environment, set `NCCL_NET=IB`, and retain NCCL INIT/NET logs. The
helper records this environment but does not claim that settings prove the
transport actually selected.

```text
moon run --target native scripts/run_native_bucket_pairs.mbtx -- run /absolute/bucket_benchmark /absolute/plugin.so 0 /rendezvous/fresh-session.json fresh-session-at-least-16-chars /output/fresh-rank0
moon run --target native scripts/run_native_bucket_pairs.mbtx -- run /absolute/bucket_benchmark /absolute/plugin.so 1 /rendezvous/copied-session.json fresh-session-at-least-16-chars /output/fresh-rank1
```

Rank zero publishes a fresh ticket and stays alive in the handshake. Copy that
ticket to a **fresh `.partial` staging path** on rank one's filesystem within
60 seconds, finish the transfer, then atomically rename the staging file to
rank one's final ticket path before launching rank one. Do not SCP directly to
the final path: the reader can observe a partially written file. This occurred
in the first paired-run attempt; it failed the ticket-size guard and that
attempt was aborted. Use a same-filesystem rename and never reuse or overwrite
an old session ticket. Each rank leaves a consumption
record. The helper retains launch hashes, stdout/stderr, cgroup snapshots and
result status, and applies a 900-second process watchdog with a five-second kill
grace. Use fresh output directories and fresh ticket/session names for every
attempt. A native direct invocation has the same five positional arguments
after its executable, with a final fresh report path instead of helper output
directory; it still needs an external watchdog and process cgroup.

After collecting both rank directories:

```text
moon run --target native scripts/run_native_bucket_pairs.mbtx -- summarize /collected/rank0 /collected/rank1 /collected/fresh-paired-summary.json
```

The summarizer verifies equal binary/plugin hashes, session and network layout,
complete CUDA events, 40 ordered samples, process success, memory bounds and
zero OOM/swap evidence. For each corresponding sample it takes the maximum
host-complete duration of the two ranks. Within each ABBA block, it compares the
mean of its two original samples with the mean of its two bucket samples; it
reports all ten ratios, plus median/p90/min/max/mean. It does not sum the
per-network rank maxima to invent a whole-schedule duration. The actual matched
whole-schedule maxima are reported separately.

Local validation before GPU deployment: fixed shape/order/count CPU test (1/1),
native release build, and helper self-tests for statistics, max-rank pairing and
rank identity. No timing numbers have been measured by the implementation agent.
