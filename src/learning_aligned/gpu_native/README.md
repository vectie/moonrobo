# Aligned GPU artifact preflight

`inspect_bundle(bundle_manifest, expected_asset_sha256,
self_collisions=?, expected_manifest_sha256=?, adapter_library=?,
capacity_profile=Initial)` validates the
complete four-graph Newton/Warp bundle and its file hashes without opening CUDA.
It returns the manifest digest, fixed world count, asset/SDK/solver contract and
optional adapter library digest. `load` uses the same validation before it
opens the GPU runtime.

Paper artifacts require `capacity_profile=Paper4096` and the matching explicit
manifest field. Initial remains the default; file size never upgrades it.
See [bounded bundle validation](BUNDLE_VALIDATION.md) for fixed byte/world
limits, the separate optional Paper selected-audit extension, and the unchanged
three-row readback bound. Profile limits do not replace memory admission.

For the two reserved training nodes, run the preflight locally on each node
against the exact MJCF hash used by its training configuration. The manifest
and adapter library digests must match across nodes; each worker must have its
own output/checkpoint path and random seed. A successful preflight establishes
artifact identity only. CUDA loading, physical behavior, numerical learner
throughput and training convergence require separate machine checks.

The scalar training entry uses CPU Float64 learning numerics. The separate
`learning_aligned_gpu/cmd` entry supports native LibTorch GPU learning with this
physics adapter. Small runtime gates do not establish 4,096-world capacity or
paper-scale convergence.
