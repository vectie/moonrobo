# Isolated numerical gate for full versus split execution

This is a bounded, opt-in numerical experiment. The ordinary training CLI and
all existing checkpoints remain unchanged. It supplements the already completed
[combined N4 CUDA training/readback gate](MICROBATCH.md), which established
execution and checkpoint integration but did not compare full versus split
updates. The first actual full/split CUDA comparison completed both runs but
**failed its fixed numerical tolerance**; details and retained evidence are below.
NCCL numerical equivalence remains a separate question.

The `paper-cuda` profile uses Float32, CUDA device 0, the existing paper-width
world `[2048,2048,2048]`, policy `[2048,1024,512,256]` and critic `[256,128]`,
logical batch 4, model window 8, imagination horizon 32, history/preview 10,
and default 5 critic epochs × 4 minibatches. It takes two world optimizer
updates followed by two actor updates, each with the normal critic updates.
Full (`0/0`) and split (`2/2`) run in separate sequential processes with the same
seed, fixed input tensors, nonzero fixed sensor noise and supplied permutations.
The kinematics fixture contains one root and 14 repeated tracked bodies; no
simulator, APIC graph, dataset, NCCL operation or physical robot is executed.

Each update records all three networks' parameters and present Adam first/second
moments, optimizer options/steps, active model gradients after clipping, all five
normalizer means/variances/counts and metrics. Two additional, explicitly named
GAE probes use the production chunk rollout with no optimizer step, concatenate
detached trajectories in time-major order, and update a **separate copied critic
normalizer** before bootstrapping. They record raw critic input, rewards,
failures, values, GAE targets and the actor gradient before clipping. Their actor
objective and updated critic normalizer are checked against the immediately
following real production update. The probes are extra forward/backward work,
not extra training updates or a claim to intercept production-internal tensors.

Every numeric sidecar has shape, original dtype, exact byte length and SHA256.
Float32 values are expanded exactly to canonical little-endian Float64 bytes,
preserving signed zero. Snapshot transfer and comparison chunks are at most
64KiB; the existing initial shared-state digest uses its separate bounded
65,536-value (512KiB Float64) audit chunks. The comparator loads no model or
optimizer. Outputs use new directories/files
and cannot replace earlier evidence. Allow approximately 2GiB disk per paper
mode; the small CPU profile uses about 11MiB for the pair.

Before allocating a GPU learner, the gate requires readable Linux cgroup v2,
an actual 16GiB or 24GiB memory limit, zero swap and no OOM counters. An 8GiB
conservative estimate must fit 65% of the minimum host available, cgroup
remaining and actual CUDA free memory. This estimate is **not a measured peak**
or a CUDA allocator hard limit. The host coordinator must also pin the image,
plugin and executable, impose a timeout, and run an external memory watcher.
Use separate fresh cgroups for the two modes. Their memory measurements include
the diagnostic probes and bounded snapshot export. Do not extrapolate any
observed saving to larger batches or the production physics process.

Build once outside the measured containers:

```text
moon test src/learning_aligned_gpu/microbatch_gate_wbtest.mbt \
  --target native --release --build-only --warn-list -a
```

Run each mode in its own fresh bounded container, using the same built artifacts
and output mount. The output root must already exist; each `full` / `split`
subdirectory must be absent. Both math-control environment variables must be
set before starting the process; the gate verifies their requested settings.

```text
env MOONROBO_TENSOR_LIBRARY=/absolute/path/to/libmoonrobo_learning_tensor.so \
  MOONROBO_MICROBATCH_GATE_MODE=full \
  MOONROBO_MICROBATCH_GATE_PROFILE=paper-cuda \
  MOONROBO_MICROBATCH_GATE_OUTPUT=/gate/microbatch \
  NVIDIA_TF32_OVERRIDE=0 CUBLAS_WORKSPACE_CONFIG=:4096:8 \
  moon test src/learning_aligned_gpu/microbatch_gate_wbtest.mbt \
    --target native --release --frozen --warn-list -a
```

Repeat in a new container with `MOONROBO_MICROBATCH_GATE_MODE=split`. This gate is
not part of the ordinary test suite unless its explicit environment is provided.
An unset mode prints a skip and executes no GPU work. Require both `run.json`
files to have `completed:true`; a skipped test is not a successful gate. If
launching the prebuilt test executable directly, its selector is
`microbatch_gate_wbtest.mbt:0-1`. The MoonBit test protocol must be checked as well
as the completed run file: direct test executable exit status alone does not
prove that an individual test passed.

Compare on CPU, including verification of every sidecar digest:

```text
moon run scripts/compare_native_microbatch_gate.mbtx --target native -- \
  /gate/microbatch/full /gate/microbatch/split /gate/microbatch/comparison.json
```

The comparator requires identical configuration, input identity, initial shared
state, plugin/binary hashes, optimizer options/steps and normalizer counts. It
checks every finite scalar against the fixed rule
`abs(split-full) <= 2e-6 + 2e-4 * abs(full)`, preserving the original CPU tolerance.
Reports include each record's mismatches, maximum absolute difference, maximum
tolerance ratio and worst index/values. Any numerical mismatch is reported in a
new JSON before a failing exit; invalid or incomplete evidence also fails.
There is no automatic tolerance widening, sample omission or retry selection.

For local harness validation only, `cpu-smoke` selects tiny networks, keeps
B4/K8/H32 and runs entirely on CPU. The completed local pair at
`/tmp/moonrobo-microbatch-gate-cpu-20261024-b` compared **529,310 values with zero
out-of-tolerance values**, including both GAE probes and the two updates of each
model type. This result establishes harness behavior on the local CPU plugin;
it does not establish CUDA numerical parity, a measured GPU memory reduction,
physical equivalence, convergence or DDP correctness.

## Actual CUDA result: numerical comparison failed

The retained `native-microbatch-numeric-20261024-a` run used executable SHA256
`83cc114a2b69065019fcb84affc9b7f65ecb137abf410e167b8d3d4cb3d1113a`
and plugin SHA256
`a1176bb28ce4fb928006c7e5db20fbe1b693bcabab6d482e0f766a00ad802f1f`.
Both [full](../../output/spark-runtime-20261024/native-microbatch-numeric/runs/native-microbatch-numeric-20261024-a/microbatch/full/run.json)
and [split](../../output/spark-runtime-20261024/native-microbatch-numeric/runs/native-microbatch-numeric-20261024-a/microbatch/split/run.json)
record `completed:true`, with 2 world, 2 actor and 40 critic optimizer updates
each. Inputs and initial state matched exactly. The verified
[comparison](../../output/spark-runtime-20261024/native-microbatch-numeric/runs/native-microbatch-numeric-20261024-a/microbatch/comparison.json)
checked **234,377,294 scalar values** and found **27 out of tolerance**:

| Snapshot | Record | Shape | Out of tolerance | Maximum absolute difference |
| --- | --- | --- | --- | --- |
| actor-1 | critic-0-kind0 | [256, 914] | 11 | 4.579313099384308e-6 |
| actor-2 | critic-0-kind0 | [256, 914] | 16 | 5.191192030906677e-6 |

All other recorded arrays, including the extra GAE probes, passed the fixed
`2e-6 + 2e-4 * abs(full)` rule. That does not override the failed critic weights:
the gate reports `passed:false`, and the comparator's failing exit is a numerical
failure rather than failure to execute the two runs. Original inputs, snapshots,
reports and tolerances remain unchanged. The separate read-only coordinate
diagnostic below narrows the affected features; it does not establish successful
equivalence or justify a tolerance change.

The [full external watcher](../../output/spark-runtime-20261024/native-microbatch-numeric/runs/native-microbatch-full-20261024-a-memory/final-summary.json)
observed a cgroup peak of **3,372,023,808 bytes**; its coverage does not certify
the complete process-lifetime peak. The
[split watcher](../../output/spark-runtime-20261024/native-microbatch-numeric/runs/native-microbatch-split-20261024-a-memory/final-summary.json)
missed the live process, so its measured peak is **null**. Split `run.json`
contains a final point sample of **3,376,680,960 bytes**, explicitly marked
`point_sample_only:true`; it is not a measured whole-run peak. These cgroup
observations are not CUDA allocated/reserved allocator peaks. Therefore this run
supports **no memory-saving claim**, no larger-batch admission, no physics or
convergence claim, and no full/split numerical-equivalence claim.

## Read-only critic coordinate diagnostic

The [retained diagnostic report](../../output/spark-runtime-20261024/native-microbatch-numeric/runs/native-microbatch-numeric-20261024-a/critic-diagnostic.json)
was produced by [diagnose_native_microbatch_critic.mbtx](../../scripts/diagnose_native_microbatch_critic.mbtx).
It validates the frozen comparison and run identities, streams the selected
sidecars in 64KiB chunks, verifies their lengths and SHA256, and reproduces all
27 reported mismatch coordinates. It does not rerun the complete 234,377,294-value
comparison. This diagnostic ran on CPU without GPU access or training; its
successful exit means the selected evidence was verified, **not that the original
numerical gate passed**. The original `passed:false` and fixed tolerance remain.

All 27 occurrences are in zero-based input columns **146 and 147** of the critic's
first `[256,914]` weight matrix: `reference-relative-rotation6d[1]` and `[2]`.
The following measurements come from the retained imagined-trajectory probes:

| Quantity | actor-1 | actor-2 |
| --- | --- | --- |
| Largest raw input difference in these two columns | 3.332232267894142e-10 | 2.765130346915612e-10 |
| Largest reconstructed normalized input difference | 1.8664714218619664e-8 | 1.3990675284950508e-8 |
| Largest GAE target difference | 2.384185791015625e-7 | 0 |
| Reward and failure-probability differences | 0 | 0 |

These near-zero features have variance approximately `2.4e-17` to `2.9e-17`;
their normalization standard deviation is approximately `0.01`, dominated by
the existing normalization epsilon. The probe normalizer mean and variance
sidecars have exactly the same SHA256 as the corresponding production
normalizer sidecars, in both modes and both phases. The diagnostic therefore
does not show a probe-versus-production normalizer discrepancy.

At the failed coordinates the final bias-corrected Adam RMS is approximately
`0.03` to `0.17` times Adam's `1e-8` epsilon. Some very small first moments change
sign between modes. The maximum-tolerance-ratio coordinate in actor-1 is
`139074` (row 152, column 146): its weight difference is `3.284541890025139e-6`,
while its reconstructed final Adam update difference is only about `2.26417e-7`.
For actor-2, coordinate `202141` (row 221, column 147) has a weight difference of
`3.539840690791607e-6`, versus a final-update difference of about `4.98851e-8`.
The last update alone therefore does not explain the accumulated difference.

The evidence supports investigating small floating-point input/reduction
differences accumulating through normalization and repeated Adam updates.
**That causal explanation remains a hypothesis.** The review found no confirmed
input-order, normalizer-update-order or Adam-configuration error. Existing
snapshots retain only the final post-clip gradients and moments; they cannot
reconstruct the preceding 19 critic steps within each actor update. The GAE
records are extra probes, not captured inputs at every actual optimizer step.
Normalized inputs and final Adam updates in this diagnostic are reconstructed
using CPU Float64 from exported Float32 values; they are not bit-exact replays
of the Float32 kernels. These limits also preclude attributing the first
divergence specifically to a CUDA GEMM, world-model update or reduction kernel.

## Bounded actual-production trace

The implemented follow-up is one separately named, opt-in capture of the
first actor update's **20 actual production critic steps**, keeping all current
mathematics, permutations, initial state and tolerance. It should retain actual
critic inputs, normalization state, GAE targets and orders once, then first-layer
columns 146/147 for all 256 output rows before and after each optimizer step:
weights, gradients and Adam moments, plus the step index, loss and optimizer
options. This locates the first divergence without exporting all three large
networks at every step. A new run must preserve the failed run's evidence.

The interface is an explicit optional, call-local recorder passed by
the white-box diagnostic entry to an internal policy-update implementation.
The ordinary public entry passes `None`; the recorder is not a learner field,
environment-variable hook or process-global callback. Both existing full and
split critic loops call the same small capture helpers at their actual prepare,
before-step and after-step points. This adds observations to the existing loops
without copying either loop or introducing a second training implementation.
No RNG draws, additional normalization updates, optimizer steps or collectives
belong in the recorder.

The recorder immediately copies detached values, never retaining autograd graphs
or shared parameter/Adam views across a step. It permits only the first critic
update, one rank, B4/K8/H32, history/preview 10, five epochs and four minibatches.
It records all 914 actual normalized input features for each of the 20 forwards,
as well as the bootstrap forward. Parameter, gradient and moment capture is
restricted to the two selected input columns and at most 256 output rows.
The paper profile retains **911,436 Float64 values / 7,291,488 bytes**, below
the hard **1,048,576-value / 8MiB** numeric budget, in 251 records (limit 256).
Array and small optimizer/record metadata overhead is additional. CPU validation
uses an eight-row critic with the same 20-step schedule.

The synchronous update fills that bounded record, with transfers of at most
8,192 values / 64KiB. The asynchronous test writer emits SHA256 sidecars after
the update, using fresh directories and create-new files. Errors fail the
diagnostic rather than dropping a step. Scalar loss tensors retain their actual
source shape `[]` in metadata and are stored as a one-element binary array.
Absent initial Adam moments remain absent, with no fabricated zero sidecars.
The public `update_policy` and `Critic::forward` signatures are unchanged; their
ordinary paths request no recorder and perform no diagnostic host transfers.

The private forward observer captures the same normalized tensor that is passed
to the critic network; it does not calculate normalization again. The actual
per-minibatch indices, targets and loss are captured from the existing loop.
The current `Adam::step` clips internally and exposes no actual clip coefficient.
The trace captures gradients immediately before and after that existing call
and reports `clip_coefficient:null`. An optional later per-optimizer step receipt could expose the
value from the existing native clipping call, without clipping twice or changing
the update. Extracting both critic loops into a common helper is another possible
design, but is a larger refactor than the initial diagnostic requires and should
be validated separately before it is used as evidence about this frozen run.

The [independent opt-in test](critic_trace_gate_wbtest.mbt) requires the same
frozen plugin SHA256 `a1176bb28ce4fb928006c7e5db20fbe1b693bcabab6d482e0f766a00ad802f1f`
and verifies the exact original full/split `run.json` and actor-1 snapshot
metadata SHA256 before allocating a learner. It reuses the original fixture,
seed, math-control environment, two world updates and the first actual actor
update. It omits the old extra, non-mutating GAE probe. To check that neither
this omission nor recording changed the update, it streams all final model
parameters, Adam moments, active gradients and normalizers into raw Float64
digests and compares **every same-mode actor-1 record SHA256**, optimizer
metadata and normalizer count against the frozen snapshot. No large final-model
sidecars are written again. The frozen sidecar payloads are not re-read by this
trace; their previous verification and the now-pinned metadata remain the
provenance boundary.

The report is saved even when this exact same-mode comparison fails. A mismatch
then fails the test and disqualifies the trace as a reproduction of the frozen
actor-1 update. Successful same-mode matching would still not change the original
failed full-versus-split result or its tolerance. The new binary has its own
identity and is not represented as the original executable.

Build only the dedicated test, without requesting GPU execution:

```text
moon test src/learning_aligned_gpu/critic_trace_gate_wbtest.mbt \
  --target native --release --build-only --warn-list -a
```

For each mode, the coordinator must start a separate fresh 16GiB or 24GiB
zero-swap container with the same timeout and external memory-watch safeguards
as the original gate. Admission remains the existing 8GiB estimate at 65% of
actual host/cgroup/CUDA availability; this trace does not relax admission.
Provide a new existing output directory and the existing frozen `microbatch`
directory, each at a canonical absolute path:

```text
env MOONROBO_TENSOR_LIBRARY=/absolute/frozen/libmoonrobo_learning_tensor.so \
  MOONROBO_CRITIC_TRACE_MODE=full \
  MOONROBO_CRITIC_TRACE_PROFILE=paper-cuda \
  MOONROBO_CRITIC_TRACE_OUTPUT=/gate/new-critic-trace \
  MOONROBO_CRITIC_TRACE_BASELINE=/gate/frozen/microbatch \
  NVIDIA_TF32_OVERRIDE=0 CUBLAS_WORKSPACE_CONFIG=:4096:8 \
  moon test src/learning_aligned_gpu/critic_trace_gate_wbtest.mbt \
    --target native --release --frozen --warn-list -a
```

Repeat with `MODE=split` in another fresh container. For a prebuilt test
executable the selector is `critic_trace_gate_wbtest.mbt:0-1`; inspect its MoonBit
test protocol in addition to process exit status. No mode means an explicit skip
with no GPU execution. The outputs are `MODE/actual-critic-trace/trace.json` and
its small sidecars, `actor-1-final-summary.json`, `preflight.json` and `run.json`.
Local CPU tests
verified full/split recording-on versus recording-off bit equality of all shared
state, active gradients and metrics, actual permutation/normalized-input order,
bounded sidecar round trips, incomplete-record rejection and overwrite refusal.

### Actual first-actor CUDA trace and bounded CPU comparison

The coordinator subsequently executed both modes in fresh containers in
`native-actual-critic-trace-20261024-a`. Both processes exited 0 with empty test
failure protocol and `OOMKilled:false`; the full-mode external watcher missed
the live process, so this evidence does **not** certify a complete lifetime
memory peak. The split watcher observed a kernel peak of `1,456,488,448` bytes
and zero observed OOM counters, but its final cgroup read failed after exit;
its `complete_lifetime_peak_certified` is also false. The trace executable SHA256 was
`7d70b67539f8023ff35a50668c74b1e858f2c39e60ef929cf8066b99f294b163`.
Both modes matched every corresponding frozen actor-1 final record SHA256,
optimizer metadata and normalizer count. The original full-versus-split gate
remains **failed**, with the original tolerance unchanged.

The read-only CPU [comparison script](../../scripts/compare_native_actual_critic_trace.mbtx)
validates the pinned frozen metadata and those same-mode summaries before
interpreting the trace. It hashes all **502** actual sidecars and compares
**911,436** values, including actual inputs, targets and all 20 selected-coordinate
optimizer steps. Reads are limited to 64KiB; retained numeric caches are bounded
to 245,904 doubles (approximately 1.88MiB), with bounded JSON and result metadata
additional. It loads no tensor backend or model, invokes no process or network,
and writes nothing itself. A valid diagnostic exits 0 even when cross-mode values
differ; integrity, schema or same-mode reproduction failures reject the input.

```text
moon run scripts/compare_native_actual_critic_trace.mbtx --self-test
moon run scripts/compare_native_actual_critic_trace.mbtx \
  /absolute/native-actual-critic-trace-20261024-a/trace \
  /absolute/native-microbatch-numeric-20261024-a/microbatch
```

The preserved [comparison report](../../output/spark-runtime-20261024/native-actual-critic-trace/runs/native-actual-critic-trace-20261024-a/trace/critic-step-comparison.json)
was generated locally from the downloaded small sidecars. It establishes this
sequence, with steps and columns zero-based:

| Captured point | Confirmed difference |
| --- | --- |
| Raw critic input, before its first update | First bit difference at row 4, column 2: `5.921243356743489e-11` versus `5.921253765084344e-11`, approximately `1.04e-16` apart. |
| Before critic step 0 | Selected initial critic weights are bit-identical; actual normalized inputs and GAE targets already contain small differences. |
| After critic step 0 | Actual gradients, moments and weights differ. For row 0, column 146, post-clip gradients differ by `2.22690e-11`; weights differ by `3.72529e-7`, below the original tolerance. |
| After critic step 4, the fifth actual Adam update | First material difference: row 152, column 146, `0.0014726400841027498` versus `0.0014752020360901952`; absolute difference `2.5619519874453545e-6`, tolerance ratio `1.116548574985528`. |
| After critic step 19 | Exactly 11 selected weights exceed tolerance, matching the frozen actor-1 result; maximum absolute difference `4.579313099384308e-6`, maximum tolerance ratio `1.4557945625114808`. |

All actual full/split permutations are bit-identical. Each captured minibatch
target exactly matches its own GAE target gathered at the recorded index. In
both modes, every actual minibatch normalized input is bit-identical to the
corresponding recorded bootstrap input row. Each step's before weights and
moments exactly match the preceding step's after state. The data therefore show
no ordering, target-gather or repeated-normalization mismatch in this capture.
Unlike the earlier Float64 reconstruction, these values were captured from the
actual Float32 tensors used by the production loop.

The report counts 132,684 bitwise differences and 187 material occurrences over
all records. The latter includes repeated before/after measurements across
steps; it is **not** a count of distinct failed final weights. Only the captured
weights cross the original material threshold. That threshold has a `2e-6`
absolute term, so gradients or moments remaining below it does not establish
that their much smaller differences are inconsequential to Adam.

This capture confirms tiny upstream differences entering the critic and actual
optimizer-state/weight differences developing over its updates, crossing the
fixed threshold at the fifth step. It still does not identify the originating
CUDA kernel or prove which arithmetic operation caused the upstream difference.
There is no captured native clip coefficient and none is reconstructed. Per-step
weights/gradients/moments cover only columns 146/147 of the first critic layer;
the second actor update's 16 original failures are outside this trace. The
comparison revalidates all new small sidecars and pinned frozen summary metadata,
but does not re-read the old large model sidecars. No numerical tolerance or
production training behavior was changed to obtain this evidence.
