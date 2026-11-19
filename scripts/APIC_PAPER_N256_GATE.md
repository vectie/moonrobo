# N256 collision-on APIC gate

`run_spark_apic_paper_n256_gate.mbtx` is an **inside-container** helper for three
separate, sequential `export`, `oracle`, and `replay` invocations. It never
starts Docker, SSH, training, or robot hardware. The N256 collision-on export,
SDK oracle and native GPU replay have now run on node 179. The fixed replay
passed on **2026-10-24 at 10:43 Beijing time**; the evidence and limits of that
result are recorded below.

The new config is `examples/learning/g1-apic-export-paper-n256.json`. It fixes
256 worlds, `capacity_profile:"paper-4096"`, true self collisions, and the same
USD, scene, SDK revisions, solver, four 5 ms substeps and 20 ms control interval
as the paper N2 artifact. The v2 tape must contain 27 operations/eight control
steps and selected worlds `[0,128,255]`. All 256 worlds simulate those steps;
only three rows are scored, giving 2,048 simulated world steps. No tolerance or
physics kernel is changed.

## Executed N256 result

Attempt `b` exported the artifact and recorded the SDK oracle successfully.
Its first native replay stopped at JSON integer decoding
(`Int64::from_json: expected number in string representation`), before producing
a numerical comparison. That failed report remains intact. Attempt `c` used
the repaired audit executable, SHA256
`9fe2341592bd0db1c97175522fa66191a649f23480ac1413be20dc53a42986fc`,
and passed with the **same** manifest, tape, oracle and runtime library hashes
as attempt `b`. No reference trace, physics kernel or comparison tolerance was
replaced to obtain this result.

The [native replay report](../output/spark-runtime-20261024/paper-n256-evidence-20261024-c/replay-report-paper-n256.json)
records 27/27 operations, eight control steps and selected worlds `[0,128,255]`:

| Check group | Vector checks | Failed | Largest recorded absolute error |
| --- | ---: | ---: | ---: |
| Native versus SDK | 675 | 0 | `3.469446951953614e-18` |
| Reset, refresh, context and isolation self-checks | 380 | 0 | `4.5776367230132564e-7` |

All **1,055** checks passed. The largest SDK error occurs at
`step-4 / sdk/state71/255`; the largest self-check error is
`reset-world255 / reset-state/255`. These are maxima across mixed fields, not
a single position error in metres. SDK comparisons retain the elementwise
rule `abs(actual - expected) <= 1e-5 + 1e-5 * abs(expected)`; self-checks retain
their existing operation-specific tolerances. The reported state change
during stepping is `0.21233787573873997`, so the trace is not a no-op.

All 256 worlds were simulated for 2,048 world steps, but only three selected
worlds were read back and scored. The result validates this pinned executed
trace; it does **not** establish general physical equivalence, long-run
stability, N4096 operation, or a training result. Previous numerical gaps and
failed attempts remain recorded.

| Successful phase | Attempt | Docker exit / OOMKilled | Observed cgroup `memory.peak` before helper exit |
| --- | --- | --- | ---: |
| Export | b | `0 / false` | 2,823,532,544 bytes |
| SDK oracle | b | `0 / false` | 2,629,156,864 bytes |
| Native replay | c | `0 / false` | 480,014,336 bytes |

Each phase used a fresh 64 GiB cgroup, zero swap and four CPU cores with the
unchanged 65%/32 GiB admission below. These cgroup observations are not CUDA
allocator peaks or certified whole-container-lifetime peaks. The replay
[Docker final state](../output/spark-runtime-20261024/paper-n256-evidence-20261024-c/replay-docker-final.json)
records UTC `02:43:35.344519377`–`02:43:56.829650328`, exit zero and
`OOMKilled=false`; its [helper summary](../output/spark-runtime-20261024/paper-n256-evidence-20261024-c/replay-evidence/summary.json)
retains admission and peak scope. The earlier
[b replay failure](../output/spark-runtime-20261024/paper-n256-evidence-20261024-b/replay-report-paper-n256.json)
remains available alongside successful b export/oracle metadata.

Verified input SHA256 values shared by b and c are:

- Manifest: `40e166ab973ba7ae11c2587a9e26d990f52b77d10ef230caee303e06203ae2e8`.
- Tape: `d34e9722f74d1b896bb797e74832e29e8bae07ba5268ac31a2a65c27d8a55860`.
- SDK oracle: `2e2f434dd18ca9237200d9e5ab740d3e639b8040a0ee060b831eaf398b387481`.
- Runtime library: `f6eb6a4c4e52aee7ecb300c0f49024cf32311b2e272698039ecfde9acd5c2913`.

The [c metadata-only archive](../output/spark-runtime-20261024/paper-n256-evidence-20261024-c.tar.gz)
has SHA256 `6dc3cb6fcf7f0296ffde90558182ce28f98279d251d3a048cb334e1312063719`.
It contains metadata and the replay evidence, not the graph payload or model
weights. The full exported bundle remains on the training node.

## Resource gates

Each phase requires a **fresh 64 GiB memory cgroup, zero swap, and at most four
CPU cores**. Actual `memory.max`, `memory.current`, `memory.swap.max/current`,
`cpu.max`, `memory.peak`, and OOM counters are checked inside the container.
Any previous/new OOM makes the gate fail; the raw peak is retained, not clamped.

Before parsing bounded metadata, a host/cgroup-only check reserves 32 GiB.
After input SHA verification, the pinned new audit executable runs
`inspect-runtime` under a 35-second external timeout (30-second internal
watchdog). It opens a temporary N2 context, requires the new optional Paper
selected-audit API, confirms capacity registration, reads actual CUDA free
bytes, and closes the context without loading a graph. Its identity and
timestamps must match; a sample older than 15 seconds is rejected.

Immediately afterwards the helper requires:

```
available = min(Linux MemAvailable, memory.max - memory.current, CUDA free)
budget = floor(available * 65 / 100)
budget >= 24 GiB physics reserve + 8 GiB SDK/host/capture reserve
```

The minimum free quantity is **52,861,135,951 bytes (about 49.231 GiB)**. Host
and CUDA memory are not added on Spark's unified-memory system. This is a
conservative admission estimate, not a proven vendor scratch/peak bound. The
successful N256 trace above does not establish that 64 GiB is sufficient for
longer traces, training or N4096. The host operator must check current
processes and actual free memory immediately
before running one phase at a time. No automatic retry, cap increase, or swap
fallback occurs.

Replay additionally retains the audit executable's independent manifest-based
projection and fixed maximum 16 GiB planned host/device audit caps. The new
32 GiB pre-launch reserve does not override those existing guards. Export has
a 900-second child timeout; oracle and replay have 600 seconds, with replay's
internal watchdog at 590 seconds. All failures and partial artifacts remain.

N128's old collision-off export observed a roughly 2.52 GB cgroup peak; its
oracle/replay monitor missed live sampling. Neither those figures nor the old
N2 observations certify N256 GPU memory. Record the new container's actual
exit/OOM state and memory-monitor coverage. `memory.peak` is a cgroup statistic,
not a CUDA allocator peak.

## Caller-owned pins and mounts

Compile this `.mbtx` to a Linux native executable and record its SHA. Build the
new producer and audit executable from the reviewed capacity/inspection
sources. Old executables do not supply the required Paper contract. Binary
and image hashes are supplied by the caller, never silently inherited from
the old N2 helper. The scene and USD SHA values below are intentionally fixed.

The same mounted `/gate` directory holds the three phases' artifacts, but each
phase uses a new container/cgroup. `/gate/export-evidence`, `oracle-evidence`,
and `replay-evidence` must not already exist before that phase. All inputs must
remain immutable during a phase. The repo and pin files should be read-only
mounts. Do **not** assume the authoring image's old `/opt/.../apic-runtime` was
updated: `runtime_adapter` must point to the newly built library mounted from
the repo (and its matching Warp dependencies must resolve in that image).

Example **export** pin file; replace all angle-bracket placeholders with
verified canonical paths/hashes. `adapter_sha256` is the authoring bridge hash
for export/oracle, and the runtime adapter hash for replay.

```json
{
  "format": "moonrobo.apic-paper-n256-gate-pins.v1",
  "executable": "/workspace/moonrobo/private/<new-producer>/producer",
  "executable_sha256": "<verified-new-producer-sha256>",
  "expected_image_id": "sha256:<verified-authoring-image-id>",
  "adapter_sha256": "<verified-authoring-bridge-sha256>",
  "audit_executable": "/workspace/moonrobo/private/<new-audit>/audit",
  "audit_executable_sha256": "<verified-new-audit-sha256>",
  "runtime_adapter": "/workspace/moonrobo/private/apic-paper-capacity-runtime-20261024-a/libmoonrobo_aligned_apic.so",
  "runtime_adapter_sha256": "f6eb6a4c4e52aee7ecb300c0f49024cf32311b2e272698039ecfde9acd5c2913",
  "scene_sha256": "b9f8b0e0cbfa4a82c125ac330b38e1a8bf4c825252caf2c3d0dffe678ca5f7af",
  "usd_sha256": "7bba6e39dd3da53e5d0b8fa1466c2551f953066bb213d84decdb576eae159c1b"
}
```

The runtime SHA above identifies the bounded build used in the executed N256
replay; the hash alone is not a physics validation. Helper code does not
hard-code it; it verifies the actual file against the caller pin and against
the fresh inspection report. The C++ API is
`mr_apic_audit_capacity_v1`, together with all three selected/property readback
exports. Missing any required symbol fails before the physics subprocess.

For **oracle**, use the same new producer and authoring image/bridge pins and
add `tape_sha256` and `manifest_sha256`, taken from the actual new files:

- `/gate/tape-paper-n256-v2.json`
- `/gate/g1-paper-n256-self-collision-apic/manifest.json`

For **replay**, set `executable`/`executable_sha256` equal to
`audit_executable`/`audit_executable_sha256`, set `adapter_sha256` equal to
`runtime_adapter_sha256`, use the verified runtime image ID, and additionally
provide `oracle_sha256` for `/gate/sdk-oracle-paper-n256.json`. The new runtime
build image is `sha256:c76815627562a180052cef8e7e07edb37fe8547d83158eed6182ebd99bb8385d`;
the host must verify the selected local image actually has that ID. The helper
records `expected_image_id` but cannot independently inspect its own Docker
image ID from inside the container.

## Host invocation template

The host owns these commands; the helper does not execute them. Set the task
paths to canonical existing host directories. Build/copy the native helper to
the shown repo path, or replace that argument with its verified path. Use a
fresh unique container name for every phase and retain containers until their
final state and memory evidence are recorded.

```bash
docker run --name UNIQUE_N256_EXPORT --init --gpus device=0 \
  --memory=64g --memory-swap=64g --cpus=4 --network=host \
  --mount type=bind,src=HOST_CANONICAL_REPO,dst=/workspace/moonrobo,readonly \
  --mount type=bind,src=HOST_FRESH_GATE_DIR,dst=/gate \
  --mount type=bind,src=HOST_PIN_DIR,dst=/pins,readonly \
  --entrypoint /usr/bin/timeout VERIFIED_AUTHORING_IMAGE_ID \
  --signal=TERM --kill-after=10s 1020s \
  /workspace/moonrobo/private/paper-n256-gate/helper export /pins/export.json
```

This outer timeout encloses hashing, inspection, the child watchdog and result
capture. For **oracle**, change the container name, outer deadline to `720s`,
and final arguments to `oracle /pins/oracle.json`; retain the authoring image
and host network. The SDK default ground-plane USD and its dependencies are
remote assets, as in the successful N2 export/oracle. The first N256 attempt
with `--network=none` failed resolving that ground-plane USD before simulation;
it exited with code 1 and `OOMKilled=false`. Its artifacts remain in
`runs/apic-paper-n256-20261024-a`. Restoring asset access does not change the
ground geometry or other physics parameters.
For **replay**, use `--network=none`, a fresh name, `720s`, the verified runtime image, and final
arguments `replay /pins/replay.json`. Keep the same mounts/resource flags.
No host GPU processes are stopped by these commands. If dependencies do not
resolve in the authoring image, fix the read-only deployment and rerun under a
new attempt directory; do not substitute an old adapter.

Generate the tape **once** with the same pinned new audit executable, as a
separate bounded CPU-only invocation (no `--gpus` needed):

```text
audit emit-tape --num-envs 256 --capacity-profile paper-4096 \
  --output /gate/tape-paper-n256-v2.json
```

Hash it and include that SHA in both oracle and replay pins. Do not regenerate
the tape or replace an oracle to select a successful comparison. Start the
existing `watch_container_memory.mbtx` host monitor for each container and keep
its full coverage report, raw logs, Docker final state and all failed reports.

## Local checks

`moon check ... --target native` and `--target wasm`, the native script test,
and `--self-test` exercise command construction, exact 32 GiB/65% integer
boundaries, cgroup refusal, runtime SHA/capability matching and stale/future
sample rejection. They do not start a subprocess, CUDA or SDK simulation.
Actual producer capture, N256 graph loading, native/SDK numerical comparison
and observed cgroup peaks for the recorded attempts are covered in the executed
result above. Changes to those pinned artifacts, longer traces, training and
larger environment counts still require their own deployment gates. Previous
numerical gaps are retained even when this later attempt passes.
