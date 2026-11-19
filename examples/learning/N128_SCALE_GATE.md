# Native N128 engineering gate

`g1-native-tensor-apic-n128-scale-gate.json` reaches the existing native limits
of 128 environments and 128 logical world/actor samples without changing those
limits. It uses microbatch 16, replay 256, SMC99 observations, history/preview 10,
world window 8, imagination 32, the existing full network widths, 10 world
updates and 5 × 4 critic updates. Microbatch accumulation preserves one optimizer
step per logical world/actor update; it does not redefine the sampled batch.

This is one engineering iteration after 64 warmup steps. `wm_only_iters=0`
deliberately exercises actor/critic immediately. It is not the SMC 500-iteration
world-only warmup or full training schedule, nor the paper/SMC 4096 actor batch,
2048 world batch or 4096 environments. Native precision remains Float32 rather
than SMC's bf16. No convergence or N128 execution result is claimed here.

The artifact SHA is deliberately absent: N128 requires a fresh N128 four-graph
artifact. The CLI hashes the supplied `--physics-artifact`, verifies every
listed member and binds its identity into the run/checkpoint. After actual
export, a deployment receipt must pin that real SHA; an N2/N4/N8 artifact fails
the exact environment-count check. The manifest of motions is also an explicit
CLI input: changing from the retained 40-motion LAFAN1 catalog to BONES is a
separate run identity. This profile does not silently choose a new dataset.

## Reproduce the static plan

From the repository root:

```sh
moon run scripts/plan_native_n128_scale.mbtx examples/learning/g1-native-tensor-apic-n128-scale-gate.json examples/learning/g1-apic-export-128env.json
```

This reads two files of at most 64KiB and prints arithmetic. It neither opens a
tensor library nor allocates GPU memory, invokes Docker, creates a ticket,
loads motion data or writes output. Production admission remains authoritative.

## Retained conservative memory plan

The arithmetic mirrors `src/learning_aligned_gpu/cmd/memory.mbt`. It deliberately
does not discount the graph envelopes for microbatching or compact replay.
There are 18,206,596 learned parameters in the configured networks.

| Component | Bytes |
| --- | ---: |
| Reference metadata and construction | 4,294,967,296 |
| Replay and checkpoint envelope | 4,294,967,296 |
| Parameters, gradients, Adam and allocator | 828,176,448 |
| Histories and live environments | 135,231,488 |
| Actor BPTT | 1,073,741,824 |
| World BPTT | 134,217,728 |
| APIC scene reserve, unchanged | 25,769,803,776 |
| Single-rank total | **36,531,105,856 (34.022GiB)** |
| DDP per-rank total, including 1GiB communicator envelope | **37,604,847,680 (35.022GiB)** |

The unchanged 65% rule requires **56,201,701,317 bytes (52.342GiB)** of actual
remaining memory for single-rank, or **57,853,611,816 bytes (53.880GiB)** on each
DDP rank. The input is the minimum of host/cgroup remaining memory and CUDA free
memory. A 48GiB container cannot pass. A dedicated **64GiB, zero-swap** training
container is a proposed hard ceiling, not evidence of enough remaining memory:
other processes, cache and the actual post-catalog check still affect admission.
Do not run the offline exporter concurrently. Stream-v2 checkpoint publication
also requires strictly more than **5GiB** of current host/cgroup headroom.

## Sampling, references and checkpoints

| Bound | N128 value | Existing maximum |
| --- | ---: | ---: |
| Policy reference-frame slots | 4,224 | 131,072 |
| Policy staging values, including five critic permutations | 3,953,152 | 16,777,216 |
| World staging values | 209,920 | 16,777,216 |
| Replay Double values at capacity | 7,667,712 | 16,777,216 |
| Replay records / candidate indices | 32,768 / 128KiB | Capacity × environments |
| Stream-v2 sidecars for APIC | 10 | 64 |

The policy input assembler still samples all starts once. With B128, its block
is 128 samples, below the 256-sample block cap. At most 6,784 unique reference
frames are cached for arbitrary valid histories: 4,124,672 bytes of numeric
state payload, excluding object/map overhead. Sampled replay histories add at
most 2,635,776 numeric bytes, excluding object overhead. Complete logical-batch
device inputs and concatenation temporaries still exist. RNG order, Float64
preview arithmetic, duplicate weights, clip-tail clamping and history padding
are unchanged. These byte counts are not a process-peak estimate.

The motion library retains clip/reset-bin metadata and reads fixed-size states
through bounded storage. It does not materialize the full frame/body library.
Both the source CSV and existing f64 cache are nevertheless completely hashed
on every startup and every rank. `motion_cache_advice=true` requests cache
release after verified files; it cannot skip integrity reads, guarantee eviction
or eliminate file-open/metadata costs. A cold cache also requires CSV conversion
and cache writing. Use the explicit data-ready barrier before issuing a short
NCCL ticket when running DDP over a large catalog.

Run this profile with **`--checkpoint-format stream-v2`**. At full replay, the
three replay sidecars occupy 61,669,376 bytes. Histories, their lengths and APIC
context bring the fixed payload to **62,717,440 bytes**. Add **20 × reset-bin
count**, actual catalog bytes (≤64MiB) and state metadata (≤4MiB); their total
must remain ≤512MiB. At maximum catalog and state sizes, this permits at most
20,142,515 bins. The 200,000-clip/Int32-frame catalog guards alone do not prove
this condition: the real catalog/bin inventory must still be checked. The
three optimizer/model archives are separately capped at 512MiB each and fully
hashed; their actual sizes are not inferred from the raw parameter count.
The conservative checkpoint memory envelope is unchanged.

Normal first-iteration counters per rank are 8,448 physical transitions,
4,096 imagined transitions, 10 world updates, one actor update, 20 critic
updates and 10,240 model-fit slots. Actor readiness may add `e=0,8,...,256`
collection steps, so physical transitions are `128 × (66+e)` and replay rows
are `min(66+e,256)`. DDP adds rank counters for reporting; it does not double
each rank's batch. APIC resume remains warm-reset/refill and DDP resume remains
unsupported.

## N128 artifact authoring and admission

`g1-apic-export-128env.json` differs from the 8env export config only in
`num_envs=128` and `/gate/g1-128env-apic`. The producer passes this count through
the fixed G1 scene recipe, builds all per-world views and context indices, and
captures `step`, `reset`, `context`, `refresh` from the real SDK. Its count guard
and the audit's selected-world trace support N128. A manifest number edit or
reused smaller graph cannot substitute for this capture.

Keep export/oracle/replay in their existing separate **16GiB, zero-swap, ≤4CPU**
container and bounded watchdog. The parent launcher supports explicit
`--num-envs 128`; no configuration here changes that resource boundary. There is
no proven N128 capture/JIT/serialization peak. The producer still hashes some
serialized files with whole-file reads; four capture owners and SDK scratch may
also coexist. On admission/capture/OOM failure, retain the evidence and stop;
do not automatically raise the cap or delete the previous artifacts.

The later audit is stricter than the general training loader:

| Check | Replay audit | Training loader |
| --- | ---: | ---: |
| Largest file / numeric region | 256MiB | 256MiB |
| Bundle bytes | 1GiB | 2GiB |
| Logical numeric-region union | 512MiB | 2GiB |
| File / region counts | 8,192 each | 8,192 each |

The replay audit additionally budgets
`8 × shared + 2 × bundle + 2 × largest + 1GiB`, bounded by the existing 8GiB
explicit host/device plan and 65% actual availability. The metadata's logical
shared-region union is only a lower bound: native four-graph loading can keep
multiple device copies; CUDA scratch/JIT/driver allocations are unknown.
It never replaces the 24GiB training reserve or proves an export peak.

After export succeeds, retain the real manifest SHA and resource receipt, run
the SDK oracle/native replay gate within its unchanged limits, then run native
training `preflight` and one fresh N128 iteration. A training invocation must
explicitly supply the approved tensor/physics libraries, actuated scene,
motion manifest, new artifact and output directory; the CPU/N2 launchers must
not be reused with silently substituted configuration. No remote commands or
GPU work were performed to prepare this profile.
