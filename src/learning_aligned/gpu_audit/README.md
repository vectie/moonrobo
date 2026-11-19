# Bounded native APIC replay audit

This executable replays a pinned input tape through the actual native APIC
adapter and optionally compares it with the original eager Isaac Lab/Newton SDK
oracle. It is an audit of a short executed trace, not training or a proof of
global physics equivalence. The previously observed SDK/native numerical gap
remains unresolved; every failed comparison must be retained. No tolerance or
physics kernel is changed by the v2 extension.

## Protocols

| Protocol | Simulated worlds | Observed worlds | Generated operations |
| --- | --- | --- | --- |
| v1 | 2 | 0, 1 | unchanged 20 operations / 8 control steps |
| v2, default `initial` capacity | 4..128 | 0, floor(N/2), N-1 | 27 operations / 8 control steps |
| v2, explicit `paper-4096` capacity | 4..4096 | 0, floor(N/2), N-1 | unchanged 27 operations / 8 control steps |

The default `emit-tape` remains v1. Its JSON bytes retain SHA-256
`cb4ffbf27aac69d5b539484f85d94273252f1496d5df9796b8c9f4564a1db860`.
Use `--num-envs 4` or `--num-envs 8` explicitly for v2. The v2 tape, oracle, and
report declare `selected_worlds`; each per-world readback array uses that order.
Result names still use actual world IDs, so N4's row 1 is reported as world 2.
`ground_friction` remains the complete bounded list of static ground shapes.

V2 initializes every world, advances four control steps, independently resets
and changes context for each selected world with paired refreshes, applies an
empty reset, advances four more steps, and refreshes twice. Reset and context
isolation are checked only for the observed worlds. Other worlds are simulated
but not asserted equivalent. Every control step is four 0.005 s physics steps.
Comparison tolerances remain `atol=1e-5`, `rtol=1e-5` per component; isolation and
refresh invariants remain exact. `diagnose` remains v1/N2 only.

## Resource and ABI limits

The additive `mr_apic_audit_view_selected` and `mr_apic_audit_read_selected`
exports accept at most three unique world IDs. Their default capacity remains
128 worlds; explicit `paper-4096` additionally requires the new optional native
`mr_apic_audit_capacity_v1` extension and a matching validated manifest profile.
An older adapter cannot silently use the larger audit capacity. They read
registered primitive rows only. C staging is bounded by
4096 scalars; MoonBit copies property indices in chunks of 1024 scalars, with
at most 4096 scalars in each reported property row. Existing v1 audit exports
and old plugins remain usable by the N2 path; v2 fails explicitly if the new
symbols are absent. The state conversion preserves the existing XYZW/COM to
WXYZ/root-link-velocity arithmetic.

Input tapes and manifests are capped at 4 MiB in the default `initial` capacity,
or 64 MiB under explicit `--capacity-profile paper-4096`. External SDK oracle
traces remain capped at 16 MiB because only three worlds are observed. Operations
remain at most 64 (v2 at most 16 control steps). These are schema limits,
not permission to launch every allowed size. Before graph loading, replay
checks actual file sizes, bounded inventories, host/cgroup available memory,
CUDA free memory, the existing 65% budget, and the explicit host/device caps.
Vendor private scratch is not fully represented by the manifest, so retain
the external memory cgroup/watchdog. N4/N8 must each pass their own preflight.

Capacity selection uses the fixed shared `learning_native_capacity` contract.
The audit retains its original, stricter Initial limits: 256 MiB per payload,
1 GiB total payload, 512 MiB logical shared numeric union and 8,192 file
entries. Paper permits 1 GiB per payload, 4 GiB total, 2 GiB numeric union and
4,096 file entries. Both profiles retain the separate 8,192 shared-region limit.
The native training consumer's historical Initial total differs;
selecting the audit does not relax its own 1 GiB bound. Sums are checked before
addition. The projection remains `shared*8 + payload*2 + largest*2 + 1GiB`, and
the existing 2..16 GiB explicit host/device planning caps, 65% availability rule
and external 5..600 second watchdog remain unchanged. A permitted N4096 schema
may therefore still fail the unchanged budget; it is not a promise of admission.

The manifest's top-level `capacity_profile` must be exactly `initial` or
`paper-4096` and match the CLI selection. An absent field means Initial for old
bundles; null, unknown strings, mismatches and duplicate CLI profile flags fail.
An external SDK oracle uses the same explicit-profile rule; old missing-profile
oracles remain Initial. Tape, manifest and oracle hashes describe the same
bounded byte buffers that are parsed, rather than a separate later file read.
The tape v2 schema itself is unchanged: profile selection cannot waive all-world
reset coverage, full-batch 29-joint step inputs or the exact first/middle/last
observed-world selection. A same-N tape remains byte-identical across profiles.

JSON reads check the size and read that exact length through one file descriptor,
then verify its final length. Reads larger than 4 MiB require conservative 16x
JSON construction/decoding headroom within 65% of actual host/cgroup availability.
Generating a tape above 128 worlds requires headroom for the profile's maximum
JSON size before constructing its arrays, and checks actual encoded size before
publishing the fresh file. Payload hashing remains 64KiB streaming. These checks
do not establish a certified process or device peak.

## Commands

`inspect-runtime` opens a temporary N2 CUDA/Warp context without loading any
graphs. It queries current free device bytes through the adapter's actual
`cuMemGetInfo` path. Total device bytes are `null`, because this ABI exposes only
free bytes. Under explicit `paper-4096`, it confirms the capacity extension and
selected-readback symbols on that temporary context, then closes it. Initial
reports both Paper capability checks as false (not checked), not unsupported.
It does not validate a bundle, simulate N256, grant memory admission, or establish
physics equivalence. It does not change old `run`, `diagnose`, or `emit-tape`.

```text
gpu_audit.exe inspect-runtime --adapter /runtime/libmoonrobo_apic.so --device 0 --capacity-profile paper-4096 --output /fresh/runtime-inspection.json
```

This command requires canonical absolute adapter/output paths and an existing
output directory. The adapter must be a regular file, not a symlink, at most
256 MiB. The shared native inspector streams its SHA-256 in 64 KiB blocks and
checks size, modification/change timestamps and canonical identity before and
after context inspection. Callers must pin the executable and compare the
reported adapter SHA with their trusted expected SHA; the command does not
invent a trust anchor. Unknown, duplicate and missing-value options fail before
CUDA access. A 30-second internal watchdog also covers hashing and publication;
retain an external process timeout. A killed process may leave no final report.

The bounded report preserves native fields and adds decimal-string Unix-ms
`started_unix_ms`/`finished_unix_ms`, elapsed time and explicit zero graph/step
counts. `success=true` means only this inspection completed. Ordinary inspection
errors write a failure report and exit nonzero, with memory fields unknown.
Reports use a fresh `.partial` then a no-replace rename; an existing output or
partial is rejected. No previous result is overwritten. Local tests cover only
argument/path/schema boundaries with synthetic JSON; they do not access CUDA.

```text
moon build src/learning_aligned/gpu_audit --target native --release
moon run src/learning_aligned/gpu_audit --target native -- emit-tape --num-envs 4 --output /fresh/tape-n4.json
# On an admitted Linux host only; this emits inputs and does not invoke a GPU:
gpu_audit.exe emit-tape --capacity-profile paper-4096 --num-envs 4096 --output /fresh/tape-n4096.json
```

Run the built executable on the GPU host with a separately exported matching
bundle and the SDK oracle made from the exact same tape:

```text
gpu_audit.exe run --adapter /runtime/libmoonrobo_apic.so --manifest /bundle/manifest.json --manifest-sha256 <SHA256> --scene /assets/g1.xml --tape /fresh/tape-n4.json --oracle /fresh/sdk-oracle-n4.json --output /fresh/native-replay-n4.json --max-host-mib 8192 --max-device-mib 8192 --timeout-seconds 180
```

For a Paper4096 bundle, add `--capacity-profile paper-4096` to `run` and use
its separately generated matching tape/oracle. Keep every old bundle, tape,
native adapter and failed report. This extension has only CPU bounds/schema
tests and compilation evidence; it does not claim a new N4096 execution or fix
the known SDK/native numerical discrepancy.

Output paths must be fresh. A failed comparison writes its report and exits
nonzero; do not overwrite it with a later passing oracle. V2 always reports
`physics_equivalence_claimed=false` and
`known_sdk_numerical_gap_unresolved=true`, even if its own trace comparison
passes. Local CPU contract tests, compilation, and C++ syntax checking do not
execute GPU physics; N4/N8 runtime validation is separate evidence.

The N256 export/oracle metadata from `20261024-b` exposed a replay-preflight
decoder mismatch: the producer writes `shared_regions[].bytes` as JSON numbers,
whereas MoonBit's generic `Int64` decoder expects decimal strings. Preflight
now accepts both exact positive integer numbers and decimal digit strings,
checks finite values and the selected member bound before numeric conversion,
and retains the same cumulative union bound. Fractional, nonfinite, negative,
zero and overflowing counts are rejected. No physics or memory limit changed.

`testdata/paper-n256-20261024-b` preserves the original manifest, tape and SDK
oracle bytes. CPU regression checks their fixed SHA-256 hashes, all 27 selected
snapshots, and the 333-region union of 54,331,573 bytes. These checks do not load
graphs or establish that the new native replay passes its numerical comparison;
that requires a separate fresh runtime result using the unchanged inputs.
