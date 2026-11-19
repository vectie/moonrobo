# E1 product process dependency audit

This audit covers `bridge_sidecar`, `supervisor`, the desktop bundle and the E1
SDK entry points. It is source-only: no tests, Python interpreter, self-check,
service, SDK, device read/write, training, simulation or export was executed.

| Path | Classification after this change |
| --- | --- |
| `sdk_e1_collector_command`, Native branch | Runtime: installed MoonBit `moonrobo-sdk-e1-native read --live`; real C++ SDK adapter/DDS required. No Python. |
| `sdk_e1_writer_command`, Native branch | Runtime: same native executable `write --watch`; actual publication only through the existing outbox/control gates. No Python. |
| Both constructors, `PythonReference` branches | Explicit optional runtime reference: interpreter plus preserved `bridges/sdk_e1/*.py`; live access additionally needs `highcontrol_py`. |
| `cmd/sdk_e1_native`, retained `src/sdk_e1_native/cli` | Two thin native entry points into one `command.run`; no Python subprocess or import. |
| `scripts/install_sdk_e1_native.mbtx` | Build/install only: MoonBit native compiler, file copy and chmod; never starts the resulting executable or initializes the SDK. No Python. |
| `src/sdk_e1_native/CMakeLists.txt` | Optional build dependency: C++17/CMake, SDK source, Eigen/Threads/driver/DDS/yaml-cpp; no Python/pybind11. |
| `src/desktop_bundle` | Builds, copies and packages the actual native command; runtime spec binds its absolute bundle path. Target SDK adapter/libraries stay external. No Python in the generated default commands. |
| `bridges/sdk_e1/*.py` | Preserved reference implementation, untouched. No default native fallback to these sources. |

The desktop host and host API already obtained their processes from
`runtime_spec_for_profile`; they therefore follow the new Native default without
changing the existing desktop configuration. An explicit reference setting can
still generate the original command vectors for later checks. Fixture reads
remain SDK-free, live reads need `--live`, and publishing remains the explicit
`write` operation; dry-run never opens a controller. No claim of verified hardware
or output parity follows from typechecking.

Supervisor readiness now checks actual POSIX executable metadata and the
configured native adapter's regular/readable file metadata. It reports a missing
adapter separately from an executable absence; compatible SDK C ABI and hardware
readiness remain unprobed at this stage. Structural plan errors generate only a
message and `exit 1`. Generated launch scripts recheck binaries and adapter files
before any outbox deletion or process start; missing inputs cause an immediate
exit. This preserves desktop artifacts generated before their release binaries
are installed. Regenerate a plan to refresh its read-only readiness report.

See [the SDK migration record](../sdk_e1_native/MIGRATION.md) for exact dependency
versions/architecture inputs, paths, installation and deferred command examples.
