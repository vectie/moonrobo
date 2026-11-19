# BONES-SEED G1: compiled BF16 training

`src/learning_aligned_gpu/cmd` is the trainer. Its optional
`compiled_bf16_profile: "g1-corrected-v1"` loads six fixed GB10/Torch 2.11
packages. The legacy eager path is still the default. The benchmark
executable does not collect experience and must not be used to start a run.

Use `examples/learning/g1-bones-paper-partial-compiled-bf16.json` and pass
`--compiled-bundle /absolute/read-only/bundle --checkpoint-format stream-v2
--cuda-memory-telemetry` to both `preflight` and `train`. The recipe uses 256
APIC environments with self-collisions, world batch 2048/window 8, and one
unchunked actor batch 4096/horizon 32. Actor observations are the 99D SMC
variant. Parameters, Adam and geometry remain FP32; MLP matrix multiplies use
BF16. The heading chart used in physical reward, motion preview and imagination
is the corrected atlas. Reference FK is local to one sampled batch. Never
enable the whole-catalog device table for BONES. The dataset is the 137,289
paper-partial G1 motions, not the authors' exact selection.

The bundle directory contains the six relative directories named in
`bf16_packages()`. Each digest covers the sorted SHA256 inventory of
`manifest.json`, `native.spec`, all top-level `.so` and `.cubin` files (ASCII
filename order, standard two-space sha256sum records). The run identity
includes the package digests, trainer and tensor plugin, scene assets, physics,
dataset and configuration. A fresh process verifies the same bytes again on
resume. No dataset examples, weights, normalization constants or RNG draws
are imported from the benchmark fixture.

The bundle also contains `libmoonrobo_bf16_cap.so`, built from
`src/learning_tensor/compiled_allocator_guard.cpp` with the matching
libc10_cuda/libc10 and CUDA 13 SDK. Build example on the GB10:

```sh
g++ -shared -fPIC -std=c++17 -O1 -I torch-include -I /usr/local/cuda/include compiled_allocator_guard.cpp -L. -L/usr/local/cuda/lib64 -lc10_cuda -lc10 -lcudart -o ../bundle/libmoonrobo_bf16_cap.so
```

The trainer verifies its SHA256 before loading it. Before training tensors are
allocated it sets and reads back a process-wide **20 GiB native CUDA allocator
cap**. APIC and driver memory are outside this cap. Only on successful
readback does admission replace the generic eager device-cache estimate with
20 GiB plus 8 GiB for driver/modules/workspaces. All other admission
components and the 80% / 16 GiB test remain. A dedicated one-second host and
cgroup watchdog also covers catalog verification and checkpoint IO, with
32/24 GiB available/free on entry, 24/12 GiB thereafter, 84 GiB maximum
cgroup usage and zero swap or memory pressure events. Run in an isolated
100 GiB no-swap cgroup. A guard failure is a failed run; preserve its output.

For the short pipeline test, copy the long recipe, set `wm_only_iters=0`,
`iterations=4`, `checkpoint_every=2` and a distinct profile label and output.
Run to target 2; preserve the report before it is overwritten. Launch a new
process with the **same short configuration and binary**, target 4 and
`--resume RUN/current.json`. Newton restores weights, optimizer, normalization,
counters and sampler, but resets physics and refills replay. Do not call that
an exact physical continuation. Verify the two reports with:

```sh
moon run scripts/audit_bones_bf16_gate.mbtx -- resume initial-report.json resumed-report.json
moon run scripts/audit_bones_bf16_gate.mbtx -- panel
```

Use the returned indices with the formal `evaluate --checkpoint
RUN/current.json --clip-indices JSON` command and the same physics, catalog,
scene and tensor plugin. The acceptance panel is 40 evenly spaced catalog
indices, declared before looking at outcomes. Each motion runs from frame zero
until its end or the reference-relative failure criterion. Report both failure
count and normalized return; neither this panel nor an early training score
demonstrates convergence. The evaluation auditor requires complete accounting
and rejects promotion if every motion terminated early:

```sh
moon run scripts/audit_bones_bf16_gate.mbtx -- evaluation evaluation.json
```

The last command uses `jq --stream`: the original evaluation report can
include 137,289 motion names and checksums, but the gate only retains the
40 panel rows and the checkpoint identity it needs. The reported actor uses
the checkpoint's BF16 linear layers and FP32 master parameters. Training,
checkpoint parsing, and the physical evaluation do not depend on this
report-processing step.

Only after both audits pass, start a **fresh** long run with the unmodified
long recipe: 500 world-only iterations, 14,000 target iterations and a
checkpoint every 100. Do not use the short-gate checkpoint with a different
warm-up schedule. Preserve the prior generations and enforce disk admission
on every publication.
