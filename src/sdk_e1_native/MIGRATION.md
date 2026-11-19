# E1 native SDK adapters and status decoding

MoonRobo provides a native C ABI for the vendor's legacy getter SDK and its
3.1 callback SDK. SDK headers and shared libraries are external dependencies.
Importing a MoonBit package or running a fixture does not initialize DDS.
An explicit live controller open is required to load the selected adapter.

## Separate the SDK paths

| Path | Purpose | Qualification boundary |
| --- | --- | --- |
| `sdk_adapter.cpp` | Vendor legacy high-control getters and publication | Requires matching external headers and libraries. |
| `sdk_adapter_v31.cpp` and `sdk_v31_state.hpp` | SDK 3.1 callbacks and logical high-control ABI | Callback state has process lifetime, matching the retained SDK module and its threads. |
| `../sdk_e1_low/` | SDK 3.1 low-control plugin with a separate worker process | The worker owns the vendor singleton; closing the last client handle waits for worker termination. Its host timeout does not specify the robot's handback behavior. |
| `status_cdr.hpp` and `status_reader.cpp` | Schema-selected, read-only raw status decoding | No controller is constructed. Both supported layouts contain 24 ordered motor records and occupy 1,156 bytes. |
| `lowcontrol_candidate/` | Licensed SDK 2.0 source correction kept for inspection | Disabled in product builds; it is not the command publisher used in the January-protocol trials. |

The powered 19 November 2026 trials used the independent January DDS sender
in [`deploy/e1`](../../deploy/e1/README.md), not `LowController::init()` or the
3.1 high-control wrapper. Matching a new SDK library to a machine does not
establish that its command schema matches the installed robot firmware.
See the [commissioning findings](../../docs/E1_COMMISSIONING_FINDINGS.md).

## Status schema and shutdown behavior

The captured January layout stores its sequence length at byte 372. SDK 3.1
stores work mode there and the length at byte 376. Both place motor records at
byte 380. The reader selects the layout using the advertised complete DDS type
identifier; it never searches the packet for an integer that happens to be 24.
The decoder checks all 24 IDs, record count, endianness, message size and finite
values. Slot 23 remains a reserved SDK record, not a 24th modeled joint.

SDK callbacks must not access state destroyed during process teardown. The
3.1 adapter therefore retains its callback state for process lifetime. The
low-control plugin isolates vendor threads in a worker process and reports
abnormal shutdown. Neither technique supplies a vendor stop/hold guarantee.
The read-only status path avoids initializing a command controller entirely.

## Device-free checks

```sh
cmake -S src/sdk_e1_native -B target/e1-status-tests \
  -DMOONROBO_E1_STATUS_TESTS_ONLY=ON -DCMAKE_BUILD_TYPE=Debug
cmake --build target/e1-status-tests
ctest --test-dir target/e1-status-tests --output-on-failure
moon test src/sdk_e1_low src/sdk_e1_native --target native
```

The C++ checks need no SDK, DDS, GPU, network connection or robot. The optional
MoonBit vendor-ABI test skips when its explicit test library is absent; a skip
is not a hardware qualification result.

## Build against the installed vendor SDK

On the supported Linux host, select the exact SDK API and target libraries:

```sh
cmake -S src/sdk_e1_native -B target/sdk-e1-v31 \
  -DMOONROBO_E1_SDK_API=3.1 -DSDK_ROOT=/absolute/vendor-sdk \
  -DBUILD_TESTING=ON
cmake --build target/sdk-e1-v31
```

`SDK_LIBRARY_DIR` and `SDK_DDS_LIBRARY_DIR` can override architecture-specific
library locations. Eigen and the vendor's matching DDS development headers
are required for this build. Install the low-control plugin and its worker
executable together. The maintained January sender uses CycloneDDS Python
11.1.0 and a separately built read-only decoder library; it does not require
opening the vendor low-control singleton.

For the native wrapper CLI, build `cmd/sdk_e1_native`. Its fixture and dry-run
paths are separate from explicit `--live` access. The commissioning sender's
action 11 and mode 2 are different interfaces from this wrapper's logical
high-control command codes; do not substitute one enum for another.
