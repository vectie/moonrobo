# Explicit checkpoint capacity

Checkpoint publication, restoration, generation verification, actor export and
the standalone CPU audit resolve capacity from the saved
`identity.config.capacity_profile`. Only the exact strings `initial` and
`paper-4096` are accepted. A missing field retains Initial; missing identity or
configuration, explicit null, unknown strings and implicit upgrades based on
dimensions are rejected.

Initial retains N/B128, replay256, 16,777,216 replay values and 512 MiB combined
state plus numeric/catalog sidecars. Paper4096 requires stream-v2, validates
N4096/world2048/actor4096/replay1000 and 958,464,000 values, and permits an 8 GiB
member and 10 GiB combined stream payload. Both profiles retain catalog64MiB,
state4MiB and model-archive512MiB bounds. Catalog bytes count exactly once.
Every required member remains subject to exact length, type/shape and SHA
verification. There is no large replay decode in inference or audit.

The publication path checks the live runner dimensions before staging or
serializing. Initial retains the old conservative host publication envelope.
Paper4096 requires a separate admitted
`MemoryPlan.components["host_checkpoint_stream_publication_headroom"]` of at
least 1 GiB; it fails closed when absent. This value is the additional host
headroom needed at save time, not the on-disk payload size. The memory planner
owns its conservative phase calculation; merely selecting a capacity profile
does not provide that admission. The 65% guard and physical reserve are not
changed here.

Paper publication also requires the admitted positive
`components["minimum_output_free_bytes"]` and checks actual available space in
the output directory before creating staging. This is an observation, not a
disk reservation. Failure retains the last valid checkpoint pointer. Initial
retains its previous disk-check behavior.

Restore still validates all metadata/files, stages replay and histories in an
isolated structure, restores the environment and commits the one-use runtime
token. Budgeting must include simultaneous old and staged live replay; the
sidecar byte limits alone are not a restore memory plan. APIC remains a warm
restart, and native distributed resume remains unsupported. No optimizer,
normalizer, sampling or training mathematics changed.

Validation uses tiny descriptors carrying large logical counts without any
large payload allocation, plus the existing small atomic-publication and
integrity regressions. No Paper4096 training or checkpoint was executed as
part of these changes.
