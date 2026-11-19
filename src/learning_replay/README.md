# Recorded experiment poses

`moonrobo.pose-replay.v1` is a complete world-space pose channel shared by
recorded playback and a future live MuJoCo session. `learning_replay` is portable:
it imports no physics runtime. The separate `producer` package reads native
MuJoCo model geometry and reconstructs full archived states with `mj_forward`.
It never evaluates a policy or advances physics time.

The native command is explicit and refuses to replace an existing `replay.json`:

```sh
moon run src/learning_replay/cli --target native -- reference-study \
  --library target/learning-venv/lib/python3.12/site-packages/mujoco/libmujoco.3.3.7.dylib \
  --scene target/mujoco_menagerie/unitree_g1/scene_mjx.xml \
  --study target/learning/g1-reference-feedforward-initialization/report.json \
  --references target/learning/g1-reference-feedforward-initialization-registration/collection/reference \
  --seed 0 --start-step 1000 --clip-ids '["pose-offset","joint-sines-high"]' \
  --limit 2 --output target/learning/replay-feedforward
```

The optional C bindings must be rebuilt with the headers matching the exact
MuJoCo library (`CPATH` can point to that installation's `include` directory).
Both C handles compare `mj_version()` with `mjVERSION_HEADER` before dereferencing
model structures. The shared library may reside in a Python environment, but the
producer uses `dlopen` directly and never loads or invokes CPython.

The output directory contains `replay.json` plus `assets/<sha256>.obj` files for
only the compiled meshes referenced by visible geometry groups 0–2. The native
extractor uses compiled vertices and compiled geom transforms, including the
compiler's centering/rotation compensation; it does not reapply source mesh
scale or offsets. Mesh bytes, the visible model descriptor, selected scene,
study report, reference manifest and each trajectory are separately SHA-bound.
The scene digest covers the selected XML file; the visual model digest covers
the extracted geometry, not all simulation parameters in included MJCF files.

Each physical clip retains its true initial state at elapsed time 0 and every
`next_state` through the terminal frame. The reference starts at the same stored
`origin_step` and can continue after physical failure. No physical frames are
invented to fill the remaining reference duration. `source_start_time_s` records
absolute reference phase; each frame's `time_s` is elapsed episode time. The
producer checks full state dimensions, joint/body order, source hashes, pinned
MuJoCo version and trajectory continuity before publication.

`Model` contains parent-first bodies and body-local visuals. `PoseFrame` contains
every body, with absolute world-space positions in meters and unit quaternions in
`w,x,y,z` order in a right-handed Z-up frame. The renderer must not accumulate
parent transforms over these already absolute poses. Primitive box sizes are
full extents; cylinder/capsule lengths are the full straight segment along local
Z. Mesh `asset` is exactly its lowercase SHA256 plus `.obj` or `.stl`, with a
positive optional scale. External textures, URLs and source filesystem paths
are not part of the pose asset channel.

`validate_json` rejects incomplete/duplicate/nonfinite poses, unordered parents,
non-unit quaternions, unsupported geometry, nonmonotonic timestamps and bounded
resource-limit violations. Future real-time code can call
`producer.capture_frame(runtime, elapsed_time_s)` after its own state update and
validate/send the same `PoseFrame`; capture itself never advances or alters the
runtime. Model identity and session ordering must be bound by the live transport.

The current producer supports full reference-initialization and reference-learning
NPZ archives. A metrics-only aligned evaluator result is not a pose recording;
it must first retain complete states or complete body poses before this viewer
can show its actual trajectory. Tests and interactive/runtime verification are
performed only when explicitly scheduled by the parent task.
