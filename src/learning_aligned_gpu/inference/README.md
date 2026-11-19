# Native tensor actor inference

This package reads the native learner's `policy.pt` and the actor's saved
observation/goal normalizers. It holds frozen Float32 encoder/decoder views and
does not allocate a world model, critic, replay, or training graph. Loading a
training archive temporarily decodes its Adam state; the CLI includes that cost
in its memory admission check. Export writes a fresh native archive with empty
Adam state. The archive is consumed by this package, not TorchScript or ONNX.

The matching CLI is `src/learning_aligned_gpu/cmd`. Build it with the actual
MuJoCo headers when running evaluation; export itself does not load a simulator.
All commands below use a native executable built from that package. No Python
process or training update is started by these commands.

```sh
aligned-gpu export \
  --tensor-library /ABSOLUTE/libmoonrobo_learning_tensor.so \
  --checkpoint /ABSOLUTE/TRAIN/current.json \
  --output /ABSOLUTE/NEW_ACTOR_DIRECTORY
```

Export runs on CPU and publishes `actor.pt` plus `actor.json` into a fresh
directory atomically. Metadata contains architecture, saved normalizers, ordered
tensor hashes, the archive SHA256, training generation provenance and the input
and action contract. The original checkpoint files remain unchanged.

```sh
aligned-gpu evaluate \
  --tensor-library /ABSOLUTE/libmoonrobo_learning_tensor.so \
  --checkpoint /ABSOLUTE/TRAIN/current.json \
  --library /ABSOLUTE/libmujoco.so \
  --scene /ABSOLUTE/g1-scene.xml \
  --scene-assets-root /ABSOLUTE/IMMUTABLE_ASSETS \
  --manifest /ABSOLUTE/motion-manifest.json \
  --physics-library /ABSOLUTE/libmoonrobo_apic.so \
  --physics-artifact /ABSOLUTE/BUNDLE/manifest.json \
  --output /ABSOLUTE/NEW_evaluation.json
```

For an exported actor, replace `--checkpoint ...` with
`--actor /ABSOLUTE/NEW_ACTOR_DIRECTORY`. Omit the two physics arguments for a
checkpoint trained with CPU MuJoCo. Evaluation uses the checkpoint's device and
physics configuration; `--config` is optional and, when supplied, must equal the
saved config. All archive hashes and the immutable receipt are checked before
loading. Scene/assets, catalog, split, tensor runtime, MuJoCo and APIC identities
must match training. A new evaluator executable is allowed and its hash is
recorded separately. A single saved DDP rank can be evaluated independently;
this does not implement distributed training resume.

For sources with an explicit `allow_tf32` config, the matching CLI now requires
the saved verified `cuda_fp32_policy`, applies all three saved CUDA per-operation
settings before Actor tensors, and compares resolved Context/override evidence.
A conflicting environment or missing extension fails rather than silently
changing inference precision. Legacy sources with neither the config field nor
policy retain their prior behavior. CPU export/re-export preserves the policy
in `actor.json`'s `source.identity` and reports that it was carried, not applied;
export does not configure CUDA or execute policy matmul. The lower-level
`Actor::load_archive` API receives only architecture/normalizers and does not
enforce source policy itself; consumers outside this CLI must configure and
verify precision before constructing Actor tensors. See the
[CLI policy contract](../cmd/README.md#explicit-cuda-fp32-policy). The new wiring
has CPU contract coverage; it is separate from the older actual evaluation
evidence below and is not yet an integrated GPU training/evaluation result.

New evaluation reports also identify the actual loaded input under
`native_actor`: `loaded_archive_kind` distinguishes `native_training_checkpoint`
from `native_actor_export`; `loaded_archive_path` and `loaded_archive_sha256`
identify the verified `policy.pt` or `actor.pt`; `loaded_metadata_path` and
`loaded_metadata_sha256` identify `state.json` or `actor.json`. Checkpoint hashes
reuse the immutable receipt checks. The actor metadata hash covers exactly the
bounded bytes decoded by the loader. Export reports carry the same input record
under `input_archive`. Paths are the loader-resolved input paths, not portable
content identities. The earlier APIC evaluations below used the older evaluator;
the subsequent CPU stream-v2 storage gate deployed these provenance fields.

Checkpoint input accepts the original v1 format and the opt-in `stream-v2`
format produced by the trainer; v1 remains the training default. The loader
checks the complete immutable receipt in either case. For v2, it checks every
typed sidecar's name, size and SHA using bounded reads, then decodes only the
small state metadata and the catalog JSON needed for reference identity. Replay,
history, sampler and physical numeric payloads are not reconstructed for
inference. The three model/Adam archives retain their existing format. Limits
remain 4 MiB for v2 state metadata, 64 MiB for its catalog, and 512 MiB for the
combined state/sidecar payload; existing model archive and memory admission
limits still apply. A v2 checkpoint's APIC state remains a warm-reset/refill
checkpoint, not an exact simulator continuation.

The subsequent 2026-10-24 CPU gate on Spark `.179` saved and resumed v1 and v2
through iteration 2, then exported the v2 checkpoint and reloaded that actor for
a second export. The [recorded invocations](../../../output/spark-runtime-20261024/native-stream-storage/runs/native-stream-storage-20261024-a/export-invocations.jsonl)
both exited 0 with `OOMKilled=false` and no GPU device allocation. The
[export log](../../../output/spark-runtime-20261024/native-stream-storage/native-stream-export-20261024-a.log)
records `input_archive.loaded_archive_kind=native_training_checkpoint`; the
[re-export log](../../../output/spark-runtime-20261024/native-stream-storage/native-stream-reexport-20261024-a.log)
records `native_actor_export`, with verified archive and metadata hashes in
both. The [iteration-2 storage comparison](../../../output/spark-runtime-20261024/native-stream-storage/rank-local-iteration-2-verified.json)
confirms matching actor parameters, specification, source and saved normalizers;
only the serialized archive hashes differ. It also reports equal stored
rank-local numeric values across v1/v2. This was one CPU MuJoCo environment with
small networks, horizon 4 and model window 2. Export/re-export did not execute
actor forward or motion evaluation and does not establish stream-v2 GPU/APIC
resume, convergence or hardware readiness. The earlier APIC evaluation reports
remain unchanged.

By default every clip in the saved training catalog is evaluated from its first
frame at 50 Hz, with the full remaining duration and no training timeout,
autoreset, observation/action noise, reset noise or domain randomization.
`--clip-indices '[0,1]'` selects complete clips for a bounded initial check; it
never shortens them. The report distinguishes a subset from the full catalog
and explicitly describes these as training-motion results, not unseen-motion
generalization. Reports use the existing full-clip reward and reference-relative
termination protocol: total reward divided by `(frame_count - 1) * 0.1`, equal
clip and frame-weighted means, failed clip IDs, termination frames and completed
durations. Early failure retains the entire clip denominator. Engineering RMSE
gates are explicitly not run by this initial tensor evaluator.

Rewards are reduced after each clip; the complete catalog's per-frame rewards
are never retained together. Initial bounds permit up to 200,000 clips and
1,000,000 transitions per clip. Overlarge requests fail rather than truncate a
clip or silently change the evaluation denominator.

APIC artifacts have a fixed environment count. Evaluation measures slot 0 and
steps the other slots with the same action, recording their additional simulation
work. This is not a claim of evaluating multiple independent clips in one batch.
Inference uses the exact raw policy output, matching the preserved Python/scalar
evaluation; training's exploratory action clamp is not inserted into evaluation.

The CLI requires Linux memory/cgroup information. It keeps the 65% admission
limit, includes temporary archive loading and reference/physics reserves, and
checks memory again after opening the motion catalog. Use the same external
cgroup cap as training. Initial CPU checks passed archive/normalizer/action
roundtrip, absence of inference gradients and Adam slots in exported weights,
and full-duration/failure/replica accounting with tiny synthetic transitions.
They do not establish physical performance, convergence, APIC parity or Noetix
E1 hardware readiness.

On 2026-10-24, the Spark `.179` run exported the one-iteration native checkpoint
on CPU and evaluated both that checkpoint and the exported actor on CUDA with
the fixed two-environment APIC artifact. Both evaluation processes exited 0 with
Docker `OOMKilled=false`. The selected training clip was `dance1_subject1`,
index 0 of the 40-clip LAFAN catalog. Both policies terminated at step 41 of 6,573,
so both failed; zero clips completed their full duration. Normalized returns
were `0.0024423383298640563` and `0.0024423382789645`, retaining the entire
`6573 * 0.1` denominator. Each run measured 41 transitions and recorded 82
simulated transitions because the artifact has two fixed replicas. This is a
working checkpoint/export/evaluation path with an undertrained policy, not a
successful motion-tracking result or a full-catalog benchmark.

The [read-only comparison](../../../output/spark-runtime-20261024/native-apic/native-actor-evaluation-comparison-20261024-b.json)
verified matching source, actor specification (including saved observation and
goal normalization), runtime/physics protocol and selected clip identities. It
also reconstructed the export's ordered parameter digest and matched it to the
checkpoint's policy attestation. The two metric results differ by
`5.089955627118892e-11` in normalized return and are explicitly **not** recorded
as exactly equal. GPU physics reductions can differ between runs; this check
does not establish the cause of that difference or APIC/SDK numerical parity.
The comparison reads report/manifest JSON, not archive tensor bytes. The
existing evaluation reports record common training provenance rather than the
loaded archive kind; the [recorded Docker invocations](../../../output/spark-runtime-20261024/native-apic/ddp-a/179/native-apic-evaluation-invocations-20261024-a.jsonl)
distinguish `--checkpoint` and `--actor`, while loader hash checks supply
that part of the run evidence. Those reports remain unchanged by the new source
metadata fields described above.

The [actor memory monitor](../../../output/spark-runtime-20261024/native-apic/runs/native-apic-evaluation-actor-memory-20261024-a/final-summary.json)
observed a maximum kernel cgroup `memory.peak` of 1,598,849,024 bytes across 22
valid samples, with no observed OOM events. Its final sample followed cgroup
deletion, so it explicitly does **not** certify a complete-lifetime peak or a
separate GPU-memory peak. The checkpoint evaluator's monitor failed to start;
there is no measured memory peak for that run. The evaluator's memory plan is
an admission estimate, not a measurement.

Repeat the bounded JSON audit without a simulator or training using:

```sh
moon run scripts/compare_native_actor_evaluations.mbtx \
  CHECKPOINT_EVALUATION.json ACTOR_EVALUATION.json ACTOR_DIRECTORY/actor.json \
  NEW_COMPARISON.json
```

The script caps each JSON input at 16 MiB, verifies full-clip arithmetic and
counts, and reports numeric differences without applying a new tolerance. Its
output file must be new. Larger catalog reports require a streaming audit;
this small verification script does not silently truncate them.
For new reports, it additionally checks the two loaded archive kinds and their
recorded hashes against the checkpoint receipt and exact actor manifest bytes.
Legacy reports are explicitly marked as lacking that input-kind evidence;
partial records or mixed old/new provenance schemas fail the comparison.
