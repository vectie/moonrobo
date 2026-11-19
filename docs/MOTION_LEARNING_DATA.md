# Motion Learning Data Slice

Implemented: 2026-10-23. This is the first SM-1 development slice, using an
original synthetic numeric fixture. The [G1 CPU provider](G1_CPU_PHYSICS.md)
now also supplies physics-generated transitions to this reader. Robot retargeting
is subsequent work. Completed G1 feedback datasets now have
[MoonData experiment registration](LEARNING_EXPERIMENT_REGISTRY.md). A first
[differentiable dynamics fit](G1_DYNAMICS.md) now consumes these numeric windows.
The [full-body reference slice](G1_FULL_BODY_REFERENCE.md) adds nine successful
physics-derived clips, a 338-channel reference representation and actual
re-tracking evidence. All 63 source/replay episodes pass this same native reader;
their full-body goals require a new policy encoder rather than the old 29-goal
actor. The [reference platform integration](G1_REFERENCE_PLATFORM.md) now seals
the clips, compact policy physics and checkpoints as learning-experiment payloads.
A general motion-library index and broader motion sources remain open.

The latest [six-cycle replay integration](G1_REFERENCE_REPLAY_PLATFORM.md)
retains 927 paired physical episodes / 284,781 transitions over those same nine
known references: 603 reused episodes and 324 new. Every archive passes the
native reader and independent reconstruction. This completes usable data for
the bounded development study; it does not supply a large source-motion library,
an unseen-motion evaluation split or real-robot training data.

## Run

From the repository root:

```sh
moon run cmd/motion_dataset --target native -- examples/learning/synthetic-motion.json train 2
moon run cmd/motion_dataset --target native -- examples/learning/synthetic-motion.json test 2
moon test -p src/motion_learning
```

The first command produces two length-two windows; the second produces one.
Success writes a complete JSON batch to stdout and exits zero. Errors print a
message and exit 2; check the exit status before consuming redirected output.
Inputs are read in memory. This initial reader neither scales large datasets nor
provides a streaming contract.

The [sustained-state workflow](G1_SUSTAINED_MODEL_STUDY.md) now validates source
chunks and exports compressed shards for larger inputs. A whole-blob native
export crashed on an approximately 697 MiB input; this remains a reader limit,
not a general streaming implementation. Its 32-shard manifest is consumed by
the numerical provider with verified logical hashes, shapes and layout.

## Dataset And Reader

`src/motion_learning` owns `MotionDataset`, `Episode`, `Transition`, the JSON
reader `parse`, and `MotionDataset::windows`. The fixture shows the concrete
`moonrobo.motion-dataset.v1` format.

Ordered axis arrays specify each vector's channel name and unit. The dataset
declares model identity, provenance, frame convention, and cadence in seconds.
These are caller declarations; loading validates numeric structure, not physical
calibration or source authenticity. Model refs may later resolve through MoonData;
the synthetic model label is deliberately not a registered robot model.

Each episode declares a source family, one of `train`, `validation`, or `test`,
context, and transitions. Each transition includes state, observation, actually
applied action, next state, goal, reward, time, and separate terminal/truncation
flags. State/observation/action axes must be nonempty. Goals and context may have
zero channels. Every vector must match its axes and contain finite values.

The reader checks every episode before split selection. Reusing a source family
across splits is rejected. Episode IDs must be distinct. A transition marked
terminated or truncated must end its episode; a reset starts another episode.
This does not determine source families automatically or compute normalization.

## Numeric Batch Layout

`moonrobo.training-batch.v1` retains axes and dataset metadata in `layout`, with
its episode array empty. `windows` records episode ID and starting step. For N
windows, length K, and channel dimension D, `state`, `observation`,
`applied_action`, `next_state`, and `goal` are flat numeric arrays in `[N,K,D]`
order. Context is `[N,C]`; time/reward and both flags are `[N,K]`. Dimensions
come from the corresponding axis counts, window count, and `window_length`.

Windows advance one starting step by default. Optional positive `stride`
spaces starts more coarsely while retaining the final complete window even
off the stride grid. The CLI accepts `[STRIDE]` after `WINDOW_LENGTH`.
Adjacent source timestamps must match
`dt_s` within relative 1e-6 tolerance for a window to be emitted. Gaps exclude
crossing windows without interpolation; episode boundaries are never crossed.
An empty split or a window longer than its episodes produces zero windows.
There is no terminal relabeling: a truncated recording remains distinct from a
physical terminal, so the trainer must explicitly choose bootstrap semantics.

The package is a concrete numeric reader/window materializer. The dynamics
provider now implements tensor conversion and train-only normalization.
Full dataset lineage and broader motion datasets remain on the
[delivery plan](SUPERMIMIC_PHASE_PLAN.md).
The synthetic fixture verifies data flow; it supplies no locomotion or learning
performance evidence.

Verified on 2026-10-23: four package tests and all 879 repository tests passed;
the CLI produced two train windows and one test window from the checked-in
fixture. `moon info` completed without errors, and the new packages were
formatted. Existing toolchain deprecation warnings remain. Subsequent integration
also accepted 596 eight-step windows from the actual G1 CPU physics experiment;
see its guide for the failure results and remaining baseline work.
