# Bounded APIC bundle validation

`inspect_bundle` and `load` use the same bounded validator. `inspect_bundle`
does not load the adapter or initialize CUDA. The validator checks the existing
SDK, asset, actuator-capture and solver contracts before reading graph payloads.
The original N=2 `apic-export-20261024-h` manifest remains accepted; its unchanged
SHA256 is recorded in the CPU compatibility fixture.

The caller must explicitly select `capacity_profile=Paper4096` in both
`inspect_bundle` and `load` to consume a manifest declaring
`"capacity_profile":"paper-4096"`. Omission defaults to `Initial`; legacy
manifests without that field are Initial only. Present null, non-string, unknown
names, and caller/manifest mismatches fail before payload IO. A large manifest
cannot select its own larger reading budget: the caller's profile bounds the
manifest file before JSON decoding.

The fixed consumer limits are:

| Item | Initial (default) | Paper4096 (explicit) |
| --- | ---: | ---: |
| World count | 128 | 4,096 |
| Manifest JSON | 4 MiB | 64 MiB |
| Inventory files | 8,192 | 4,096 |
| Shared numeric regions | 8,192 | 8,192 |
| One graph, module or shared region | 256 MiB | 1 GiB |
| Adapter library | 256 MiB | 256 MiB |
| All inventory file sizes | 2 GiB | 4 GiB |
| Shared numeric allocation union | 2 GiB | 2 GiB |
| File hashing chunk | 64 KiB | 64 KiB |

Initial's historical consumer byte/count bounds are preserved. Its standalone
manifest world check now matches the existing Initial training/audit cap of
128, replacing the old loader-only permissive 1,000,000 check. Producer and
audit-CLI Initial inventory bounds are intentionally narrower in some cases;
consumers do not silently inherit those changes. Paper limits come from the
shared `learning_native_capacity` profile. These are bounded-format limits,
not a memory admission decision or evidence that 4,096 worlds fit.

The four graph roles must name distinct `.wrp` files in the SHA256 inventory.
Every inventory file is checked for size and the aggregate budget before any
payload hashing starts. Only the bounded manifest is read as a complete byte
array; graph/module/library digests stream through one file descriptor. Size,
modification time and change time are checked before and after hashing, and
the retained identities are rechecked before CUDA initialization and after
native graph loading, before the first graph operation. A hash mismatch aborts.

Relative payload paths reject traversal, empty components, control characters,
absolute paths and symlinked files/directories. Paths are limited to 4,096 UTF-8
bytes, 16 components and 255 bytes per component. The bundle directory is
canonicalized. Adapter and manifest final paths must be regular files.

Native APIC still opens the canonical graph/module paths itself. This validation
is not an atomic filesystem snapshot, and cannot defend against a malicious
writer swapping contents during native loading and restoring them afterwards.
The bundle and adapter must remain immutable for the lifetime of native replay.
No filesystem race protection beyond these checks is claimed.

Both inspection output and `NativeBatch.provenance` include `resources` with
format `moonrobo.apic-resource-lower-bound.v1`. It records the verified inventory
disk bytes, four graph sizes and hashes, shared numeric region count and bytes
by scalar type, and each component view's `[num_envs, width]`, strides, binding
size and last byte boundary. The manifest's logical shared numeric union is
counted once across the four graphs. Native graph loading may retain separate
device copies and copy values when switching graphs; this summary does not
measure or count those extra copies. It is a declared allocation lower bound,
not a measured GPU peak; disk bytes are not GPU bytes.

CUDA scratch, private graph allocations, opaque mesh resources and driver/JIT
allocations are explicitly `null` (unknown). `complete_peak_estimate` and
`replaces_training_memory_admission` are both false. The existing 24 GiB
physics reserve, 65% training memory admission rule and training batch/world
caps are still enforced independently by the caller. Accepting a valid bundle
does not prove runtime memory use or numerical behavior; those require a
separate machine gate with the corresponding artifact.

Selected-world audit still reads at most three unique rows and at most 4,096
scalar properties per row, transferred in 1,024-value property chunks. Initial
retains the old optional selected-audit ABI. Paper requires the new optional
`mr_apic_audit_capacity_v1` export, explicitly registering the 4,096 scene-world
limit before any selected readback. The native runtime defaults to 128 and
accepts only the fixed values 128 or 4,096; it never infers an audit limit from
scene size. Missing this export is an explicit Paper-audit error, with no
fallback. Regular graph loading and training do not require the extension,
so existing adapters remain usable there. Original N=2 readback/diagnostics
and all numerical tolerances are unchanged. The new extension has only been
statically compiled in this change; no new GPU adapter was deployed or tested.

`inspect_runtime_library(adapter_library, device_id=0,
capacity_profile=Initial)` independently hashes and identity-checks the library,
opens a temporary N=2 handle without graphs, queries current `cuMemGetInfo` free
bytes, checks the library identity again, and closes the handle. Paper first
requires the capacity/selected-view/selected-state/property symbols and confirms
`mr_apic_audit_capacity_v1(...,4096)` succeeds. That registration affects only
this temporary handle; it changes neither global physics settings nor files.
Initial does not require or claim the new capability. The result records actual
free bytes, `cuda_total_bytes:null` (the existing ABI queries only free bytes),
and explicit `no_graphs_loaded:true`/`physics_validated:false`. It does not load
N256/N4096 physics, establish memory admission, or measure a CUDA peak. CPU tests
cover invalid-device/missing-library refusal; a real CUDA inspection is a
separate deployment gate.

Narrow CPU regression coverage includes chunk boundaries, same-length payload
damage, rejection of an oversized late inventory member before hashing an
earlier damaged member, sparse oversized metadata, symlinks and traversal,
entry/byte limits, graph aliases, shared-union accounting, and unchanged legacy
h metadata. The tests never load a real adapter or allocate CUDA memory. The
legacy fixture contains metadata only; it does not certify the graph payloads.
Additional CPU cases cover strict profile parsing and mismatches before member
IO, valid synthetic 4,096-world metadata, rejection above each fixed world cap,
three-row selection bounds, Paper member/union/total/count limits, Int64 overflow
refusal, and sparse oversized 64 MiB metadata. The 20 package tests pass without
CUDA; C++ syntax checking uses actual Warp 1.17 and CUDA 13 headers. The later
no-graph inspector adds one CPU negative test (21 total), without another C++
ABI change.
