# B4096 history preparation: read-only candidate design

Status: design only, 2026-10-24. No production source, frozen G2 candidate,
configuration default or numerical gate is changed by this note. Wait for the
six-optimization B4096 paired measurement and its remaining preparation cost
before implementing another option.

The [G profile configuration](../output/spark-runtime-20261024/smc-native-4096-optimization-20261024-g/profile-evidence/run/native-config.json)
sets `resident_reference_cache=false`. Its [accepted profile attribution](../output/spark-runtime-20261024/smc-native-4096-optimization-20261024-g/profile-evidence/profile-attribution.json)
therefore describes the **original route**, not residual work with all six
optimizations enabled. In diagnostic iterations 21–24, mean actor preparation
is 1429.269 ms; reference/history preparation is 1359.680 ms, including
570.259 ms of named upload scopes and 44.337 ms of validation. The remaining
745.084 ms includes reading, packing and other unseparated work. These are host
elapsed scopes, not transfer-only or GPU-kernel times, and this independent
startup diagnostic is not the paired throughput comparison.

## What the existing resident reference option already removes

Each logical actor batch is prepared once, then sliced for eight actor
microbatches; it is not prepared eight times. With B4096, H32 and history10:

| Work per logical actor batch | Original reference route | Resident reference route |
| --- | ---: | ---: |
| CPU reference goal encodings | 33 × 4096 = 135,168 | 0 during sampling |
| Reference/history preparation uploads | 16 × (4 + 33 × 2) = 1120 | 16 × 4 + 1 = 65 |
| CPU history observations | 4096 × 10 = 40,960 | 40,960 |
| Decoded sample blocks | 16, each at most 256 starts | 16, each at most 256 starts |

The resident route replaces per-sample goal/flat-reference encoding and payload
upload with one time-major index upload and table gathers. It still constructs
four base fields for every block, performs four final concatenations, gathers
33 reference/goal pairs and decodes their quaternion state. See
[`stage_resident_policy_input_blocks`](../src/learning_aligned_gpu/runtime/resident_references.mbt#L204)
and the retained [original block route](../src/learning_aligned_gpu/runtime/reference_blocks.mbt#L203).
History reference lookup remains bounded per block and uses the original CPU
Float64 references. Neither these static counts nor the original profile
quantifies the resident route's remaining cost.

## Smallest next candidate: direct bounded history packing

Proposed independent flag: `history_compact_pack=false`. It is **not present
in the current CLI or implementation**. Keep all sample selection, reference
lookup, padding, RNG order, per-block finite validation and upload ordering.
For each existing block of at most 256 starts:

1. Preallocate just its `[count, history, observation_dimension]` Double array.
2. Compute the fixed noise-width array once per logical actor batch.
3. Write observation components directly from the already-decoded replay state,
   using the existing quaternion/matrix functions and their arithmetic order.
4. Apply the original `obs[j] + (draw * 2 - 1) * width[j]` expression in the same
   history/sample/component order. Validate the completed block at the same
   boundary and upload the same four fields in the same order.

Currently [`observation_with_noise`](../src/learning_aligned_gpu/runtime/batches.mbt#L214)
creates a raw observation, a noise-width array and a noisy observation on every
history row; [`unflatten_state`](../src/learning_aligned/kinematics.mbt#L23)
also copies six state fields before the observation is constructed. Direct
packing could remove these temporary arrays and dynamic append growth. It must
retain the original [observation formulas](../src/learning_aligned/mdp.mbt#L51)
and [rotation operations](../src/learning_aligned/rotations.mbt#L60), including
their order. Replacing CPU references with cached Float32 features would alter
rounding and is outside this design.

The proposed additional reserve is deliberately conservative: add
`8 × min(B, 256) × history × observation_dimension + 65,536` bytes to every
phase, without discounting an existing envelope. At B4096/history10/Smc99 this
is **2,093,056 B**. No full-batch decoded history cache or extra GPU-resident
table is needed. At most one 256-start packing array exists at a time; existing
GPU output tensors keep their existing admission accounting.

Required gates before a performance run: all three observation modes and
Float32/Float64 uploads; signed zero, near-zero quaternions and nonfinite error
boundaries; complete policy tensors and subsequent RNG draws; resident/original
reference composition; actual full and eight-microbatch learner updates,
including Adam and normalizer state. No tolerance change, RNG reseeding,
reduction change or inferred speedup is permitted. A resident-enabled profile
and fresh-process paired full-iteration comparison must determine its value.

## Larger follow-up, not part of this candidate

[`decode_start_block`](../src/learning_aligned/replay_start_blocks.mbt#L32)
constructs history10 plus one current `Transition` per sample: 45,056 objects
for B4096. [`transition`](../src/learning_aligned/replay_storage.mbt#L145)
copies 233 Double array values per object, totaling **83,984,384 B of copied
array payload** per logical batch. This is not live RSS. The `s1` and `a` fields
are unused by actor history/current inputs: their 100 Doubles account for
**36,044,800 B** of those copies.

A future read-only policy-fields visitor could avoid these unused fields while
retaining sample-directory ordering, ring continuity, history padding and the
256-start lifetime bound. It changes the replay API and lacks its own isolated
timing evidence, so it should follow the smaller candidate only if measurements
justify it. Neither design is implemented or included in G2's acceptance scope.
