# Bounded policy input staging

`sample_policy_batch` selects every logical sample index first, then uses
`ReplayBuffer.with_sampled_start_blocks` to decode and consume at most 256
starts at a time. Its public signature and the complete `PolicyBatch` shapes
are unchanged. The host preparation of initial states, histories, references,
previews and future noise is divided into sample blocks of at most
`min(batch, 256)`.

For each block the runtime collects the required history indices plus the union
of overlapping `H+1` reference and `K` preview windows. It sorts unique global
frame indices, reads only those states, and consumes them in the original sample
and time order. Global frame order also groups reads by the immutable motion
catalog's clip order. Duplicate samples keep their full multiplicity; only
reference reads are shared. Clip-tail preview padding still uses the original
`future_frames` rule. No full-library `map`, eager conversion or body-FK cache is
introduced.

`goal_from_states` and the existing scalar `MotionLibrary.goal` share the original
Float64 formula and per-frame arithmetic order. The scalar method retains its
streaming reads. References are flattened and uploaded in sample blocks, then
concatenated into the original full-batch flat71 tensor before geometry decoding.
This retains the original geometry operation shapes and Float32 conversion
boundary. The complete reference/goal tensors remain resident on the selected
tensor device, just as before.

RNG consumption remains: all start selections; history noise in sample/history/
feature order; future observation noise in time/sample/feature order; then the
original per-epoch Fisher–Yates critic permutations. Reading, sorting and
encoding references consume no random values. Learner updates, normalization,
collectives and optimizer ordering are outside this change.

The cached working frame set must fit both existing `max_reference_frames` and
the motion store's materialization limit. If the union is larger, preparation
uses the original bounded scalar reads rather than caching that union. This
preserves previously legal tight limits on individual gathers. The cumulative
staging check remains mandatory. Default limits, CLI batch caps, stream-v2
checkpoint limits, 65% memory admission rule and physics reserve are unchanged.
The explicit runtime-only large-batch limit below does not enable a 4096 batch
in the CLI. Only the current sampled replay history block and one critic
permutation source array remain retained according to their declared bounds;
final future noise tensors span the full batch. A small batch may use more temporary frame
cache memory to avoid repeated IO; no measured peak-memory improvement or GPU
speedup is claimed. Tensor concatenation also has temporary device allocations.

CPU regression uses an independent copy of the prior preview and full-array
assembly paths. It compares every exported tensor value by IEEE754 bits, all
shapes/dtypes, the final RNG state and subsequent draws for Float32 and Float64,
all observation modes, noise on/off, a 256+1 tail, duplicate starts, padded
history and terminal-frame previews. It also checks unique sorted reads,
signed zero, the working-set limits and the tight-limit scalar fallback. It does not execute a GPU or learner
update at paper scale.

## Explicit paper input capacity

`BatchLimits::default()` still permits at most 131,072 reference frames and
16,777,216 logical tensor values. The opt-in `BatchLimits::paper_scale()` permits
135,168 reference frames and **127,016,960** logical tensor values. This exactly
covers the largest existing observation mode (Observable, 102 features) at
actor batch 4096, H32, history/preview 10, five critic epochs and noise enabled.
It also covers world batch 2048 with an eight-step window. It is a shape limit,
not an allocation admission decision or permission to launch training.

The pure functions `policy_batch_shape_usage(config, batch, mode, limits=...)`
and `world_batch_shape_usage(batch, window, limits=...)` validate dimensions and
perform checked Int64 products and sums before sampling or tensor allocation.
They retain the Int32 tensor-value indexing ceiling. Invalid, zero, negative or
overflowing dimensions fail closed. The production batch builders use these
same checks; callers can query them without loading LibTorch or touching a GPU.

For the paper dimensions with noise enabled:

| Observation mode | Logical uploaded values | Retained input tensor bytes, Float32 plus Int64 orders |
| --- | ---: | ---: |
| Paper, 93 features | 125,468,672 | 509,362,176 |
| SMC, 99 features | 126,500,864 | 513,490,944 |
| Observable, 102 features | 127,016,960 | 515,555,328 |

The logical value count is
`B * (133 + hist*D + (H+1)*(71+73*K) + H*D + epochs*H)`.
Noise contributes zero when disabled. Its Float64 source byte count is a
logical-content total: the runtime does **not** assemble that approximately
1GB host array. The retained device-byte count additionally includes nine
rotation values per reference, because the decoded reference component views
retain flat71 backing storage, and uses eight bytes for critic Int64 orders.
It excludes geometry temporaries, concatenation output overlap, autograd,
network/Adam storage, allocator reservations and physics.

For Observable at these dimensions, one source block assembles at most 500,224
numeric elements for initial state/history and one reference/preview slice.
The cached reference union contains at most 13,568 states, or 1,031,168 numeric
state elements, additionally bounded by the motion store's materialization
limit. Future noise assembles at most 26,112 elements per upload. The original
Fisher–Yates permutation retains one 131,072-element source array. The final
full-batch tensors and temporary concatenations remain on the selected device;
the largest individual concatenation output is 4,177,920 Float32 values.

The original `sample_starts` API remains available unchanged. The production
actor sampler instead enumerates the identical age-major/env-minor candidates,
makes all B random selections into a `FixedArray[Int32]`, then releases the
candidate directory before decoding. The selected-index payload is 4*B bytes
(16,384 bytes at B4096). Candidate enumeration happens once; its primitive
directory payload is bounded by `4 * replay_rows * num_envs` bytes, separately
from array headers and allocator overhead.

Each synchronous callback receives at most 256 starts. At history10 it holds
at most 2,816 compatibility `Transition` objects, containing 658,944 Float64
numeric elements, instead of all 45,056 objects / 10,543,104 elements at B4096.
The callback retains only uploaded tensor accumulators; starts, histories,
source arrays and its reference-state map do not escape into the next block.
The reference union remains a distinct working set with the limits above.
`BatchShapeUsage.sampled_transition_values` retains its original full logical
inventory meaning; admission uses the separately bounded live decoded count.
The direct `policy_batch_from_starts` API cannot release a caller-owned full
start array, which remains outside this sampler's block accounting.

World input preparation now samples and uploads at most 256 windows at a time.
`ReplayBuffer.sample_windows` performs exactly two random draws per sample and
does not build a candidate table, so this retains its complete old draw sequence
and masks. At B2048/W8, final world input is 3,358,720 values / 13,434,880 Float32
bytes. Each block retains at most 479,232 sampled transition numeric elements,
2,048 mask elements and 419,840 assembled upload elements. The direct
`world_batch_from_windows` API also chunks assembly, but any complete caller-owned
window array remains owned by that caller and is outside the sampler's block
accounting.

The RNG equivalence above concerns successful batch construction. If a tensor
upload fails in an early world/noise block, only that block's draws may have
occurred, whereas the former full-host assembly could already have drawn the
whole batch. The exception remains fatal to the training operation; this code
does not retry a partially constructed batch or claim identical RNG state after
an error.

All accounting describes numeric element counts, **not a certified peak**.
Dynamic array spare capacity, object headers, native FFI/LibTorch host conversion
copies and delayed allocator reclamation require additional allowances. No
existing 65% guard or physics reserve is reduced. No full-scale GPU allocation,
performance result, learning equivalence or resolution of the failed frozen
microbatch numerical gate is claimed by this input-staging change.

Additional narrow CPU regressions cover pure paper-shape arithmetic without
allocating paper tensors, one-value/one-frame limit shortfalls, Int64 overflow,
invalid dimensions, and Float32/Float64 world tensor/RNG parity for 256+1 samples
on wrapped multi-environment replay with terminated/discontinuous masks and
signed zero. The existing independent policy oracle covers the newly chunked
noise path as part of its whole-batch bitwise and RNG comparisons.

Actor decoder regressions compare exact transition field bits and metadata
against an independent legacy oracle at B1/256/257/4096 with history10,
wrapped replay, episode discontinuities and history padding. All B selection
draws must finish before the first consumer callback; subsequent callback RNG
draws cannot alter later selected starts. Real CPU tensor regressions compare
every output tensor and final/subsequent RNG values against the legacy full
assembly at B256/257/4096 with noise enabled. The B4096 tensor case uses a short
history/horizon to limit CPU test memory; the full history10 decode bound is
covered separately. These checks do not execute a GPU or prove CUDA optimizer
equivalence.
