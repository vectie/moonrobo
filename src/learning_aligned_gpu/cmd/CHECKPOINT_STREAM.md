# Opt-in stream checkpoint format

Training defaults to `--checkpoint-format v1`. Select
`--checkpoint-format stream-v2` to write small typed metadata and separate
little-endian replay, history, sampler and physical-state files. The three Adam
archives retain their existing format. No Python entry point or old checkpoint
is removed.

Every sidecar has a dtype, shape, element count, byte length and SHA-256.
Publication verifies the complete file set, syncs a fresh generation, renames
it without replacing a generation, then atomically publishes `current.json`.
Failure before publication retains the previous pointer and staged evidence.
Files are read and hashed in at most 64 KiB chunks. V2 metadata is bounded to
4 MiB, catalog JSON to 64 MiB, and metadata plus sidecars to the existing
512 MiB payload envelope. Each optimizer archive retains its 512 MiB limit.

Streaming does not lower the current conservative memory admission estimate or
increase any environment, batch, replay, tensor-staging or 65% budget limit.
The catalog is still bounded JSON. Restore temporarily holds an isolated replay
and histories while validating them; it is not a zero-extra-memory operation.
Runtime values are staged before physical restoration and committed afterward.

Training reads both v1 and v2. Changing the executable, tensor library, scene,
catalog or configuration still fails the existing exact resume identity check.
Use the same binary for paired storage tests and their resumed runs. MuJoCo can
resume exact physical integration state. APIC continues to restore warm state,
reset physics and refill replay. Distributed resume remains unsupported.
Export/evaluation use the shared verifier and catalog projection; the CPU audit
verifies sidecars and compares actual parameters, Adam state and normalizers.
The audit does not compare rank-local replay or physical state semantically.

## Small CPU storage gate

`examples/learning/g1-native-tensor-stream-checkpoint-gate.json` uses the existing
CPU smoke restrictions: N=1, horizon=4, model window=2, batch=2, replay=64,
history/preview=10, and small networks `[32,32]`, `[32,16]`, `[16,8]`. All action,
observation and reset noise and domain randomization are disabled, matching the
existing CPU smoke policy. This is a storage correctness gate, not a paper-scale
model or performance/convergence comparison.

On the Linux host, stage one release trainer, its matching tensor library and
the audit executable in a fresh directory. Run each command in a bounded CPU
container without `--gpus`, using matching MuJoCo 3.15.0 headers/runtime and the
same actuated scene, manifest, configuration, binary and seed:

```sh
timeout --signal=TERM --kill-after=10s 600s /work/private/native-stream-gate/trainer train \
  --tensor-library /work/private/native-stream-gate/libmoonrobo_learning_tensor.so \
  --library /opt/isaaclab-venv/lib/python3.12/site-packages/mujoco/libmujoco.so.3.15.0 \
  --scene /work/data/g1_description/scene-no-self-collision.xml \
  --manifest /work/data/manifest.json \
  --config /work/examples/learning/g1-native-tensor-stream-checkpoint-gate.json \
  --output /work/runs/native-stream-storage-FRESH/v1 \
  --checkpoint-format v1 --iterations 1

timeout --signal=TERM --kill-after=10s 600s /work/private/native-stream-gate/trainer train \
  --tensor-library /work/private/native-stream-gate/libmoonrobo_learning_tensor.so \
  --library /opt/isaaclab-venv/lib/python3.12/site-packages/mujoco/libmujoco.so.3.15.0 \
  --scene /work/data/g1_description/scene-no-self-collision.xml \
  --manifest /work/data/manifest.json \
  --config /work/examples/learning/g1-native-tensor-stream-checkpoint-gate.json \
  --output /work/runs/native-stream-storage-FRESH/stream-v2 \
  --checkpoint-format stream-v2 --iterations 1
```

The configuration explicitly applies the same `self_collisions=false` setting to
both MuJoCo runs, matching the existing actuated scene; scene identity must also
be identical. This gate does not compare collision models.
Record each immutable generation name from its pointer before resuming. Run
`native-checkpoint-audit --tensor-library PATH --left V1_GENERATION --right
V2_GENERATION --max-host-mib 8192` to compare the actual saved shared state. For
each original command, use its matching format and output, add
`--resume OUTPUT/current.json`, and change only `--iterations 2`. Then audit
the new immutable generations. Preserve both generations, reports, logs,
container exit/OOM status and actual cgroup memory peaks. Missing measurements
are unknown; memory admission alone is not evidence of the runtime peak.

## Observed CPU storage result, 2026-10-24

Spark `.179` completed the paired v1 and stream-v2 first-save runs, then resumed
both from iteration 1 to iteration 2 using the same executable/configuration.
Both resumed reports record `resume_kind=exact`. All four training invocations
exited 0 with Docker `OOMKilled=false`, a 16 GiB cgroup cap, two CPUs and no GPU
device requests. Independent CPU archive audits of both iteration pairs decoded
the three model/Adam archives and five normalizers: identities, iterations and
actual shared-state digests matched, including held-state attestations. The
iteration-2 digest is
`bfc5ed6be516047144abb4446aa5b3e0d66eccdc355493d95c688a1ea820f6c4`.

An additional independent MoonBit byte decoder compared the downloaded v1 JSON
against all stream-v2 numeric sidecars. It checked every chronological replay
field, observation history, the 411-value MuJoCo integration vector, episode
indices, previous action/context/returns, initialization flags and all three
8,842-bin sampler arrays. Runtime/physical RNG, counters, fractional collection
accumulator, configuration and ordered 40-clip catalog also matched. The catalog
records source data at 30 Hz; control remains 50 Hz.

| Pair | Replay rows | Numeric elements compared | Bit mismatches | Signed-zero mismatches |
| --- | ---: | ---: | ---: | ---: |
| First save, iteration 1 | 18 | 32,220 | 0 | 0 |
| Resumed save, iteration 2 | 21 | 32,934 | 0 | 0 |

The stream-v2 iteration-2 actor was exported on CPU, then loaded from `actor.pt`
and exported again. Both invocations exited 0 with `OOMKilled=false` under an
8 GiB cap. The actor specifications, parameters' semantic digests, normalizers,
contract and training provenance match. Reconstructing the ordered parameter
digest also matches the source checkpoint's policy attestation. Archive byte
SHAs differ, as expected for independent LibTorch serialization; they are not
the equality criterion. This check did not execute an actor forward pass or
evaluate a motion.

The read-only monitor observed the following kernel `memory.peak` values:

| Invocation | v1 bytes | stream-v2 bytes |
| --- | ---: | ---: |
| First save | 883,060,736 | 892,702,720 |
| Resume | 656,183,296 | 624,861,184 |

All four monitors explicitly report `complete_lifetime_peak_certified=false`;
the cgroups disappeared before their final polling read. Observed OOM event
counters were zero, and Docker recorded no OOM kill. These samples do not prove
the final lifetime peaks or a RAM improvement from streaming.

Evidence is retained under
`output/spark-runtime-20261024/native-stream-storage/`: the two
`native-stream-storage-audit-{first,resume}-20261024-a.log` files contain actual
archive audits, while `rank-local-iteration-{1,2}-verified.json` contain the
independent local comparisons. The downloaded `runs/native-stream-storage-20261024-a/`
contains invocation receipts, reports, memory observations, state/sidecars and
actor metadata. Model and actor `.pt` files were not downloaded: the local
comparator explicitly records that it did not verify those archives, and relies
on the separate remote audit/export evidence for that part.

Reproduce a local comparison without a tensor library or simulator:

```sh
moon run --target native -j 1 scripts/compare_native_checkpoint_local_state.mbtx -- \
  --left-v1 V1_GENERATION_DIRECTORY --right-v2 V2_GENERATION_DIRECTORY \
  --output FRESH_REPORT_JSON \
  --actor ACTOR_DIRECTORY --actor-reloaded RELOADED_ACTOR_DIRECTORY
```

Omit the actor arguments for iteration 1. The comparator accepts only the small
N1/H4/K2, 40-clip, at-most-64-row, iteration-1-or-2 fixture, bounds JSON and file
sizes, verifies state/sidecar SHA and lengths, and reads binary payloads in at
most 64 KiB chunks. Its signed-zero and corrupt-SHA regression passes locally.
It mutates no input files and performs no training, physics, GPU or network
operation. These results do not validate GPU/APIC stream restoration, full
BONES training, paper-scale networks, convergence or transfer to Noetix E1.
