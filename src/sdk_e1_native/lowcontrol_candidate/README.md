# E1 low-control source candidate (disabled)

This directory holds a repository-owned copy of the Noetix SDK 2.0.0
`src/lowcontroller.cpp` with narrow, source-level corrections. The source and
license are adjacent. It is **not** included in the product CMake target,
loaded by the E1 native bridge, or used by any robot command path.

The vendor source copies only slots 0–20 from its 24-motor state buffer. This
candidate returns all 24, rejects DDS messages unless they contain exactly
24 ordered motor IDs, zero-initializes missing state and reports an invalid
sentinel before the first valid sample or when the last status is over 100 ms
old. It time-bounds command republishing to 40 ms after `set_joint` using a
monotonic clock, rather than indefinitely refreshing the DDS packet timestamp
for an old setpoint. The `guard.hpp` predicate has a device-free unit test
source in `guard_test.cpp`; it is included in the SDK-free CTest configuration.

**This is not a safety-certified stop.** After the 40 ms deadline the SDK
thread merely stops publishing motor packets. The robot's motor controller may
hold the last target. The selected deadlines are provisional and require
measured timing and a manufacturer-confirmed stop/hold behavior. Calling
`LowController::init()` changes the SDK mode to user control; that call is
absent from MoonRobo's product bridge and must not be introduced as a side
effect of preflight or read-only checks.

The candidate is kept outside the linked target because `highcontroller.cpp`
and `lowcontroller.cpp` define overlapping global buffer symbols, and their
SDK singleton behavior has not been qualified together. A future low-control
runner needs a separate process or library, an exclusive-control protocol,
validated model/calibration, a hardware watchdog and a qualified fallback.
Only after those conditions are met should this candidate be compiled against
the exact Linux SDK revision and compared with the vendor implementation.

On this macOS checkout, `c++ -fsyntax-only` for the SDK-backed candidate stops
at the SDK's Linux-only `<features.h>` dependency. This is a platform limit of
the local static check, not evidence that the candidate builds on Linux.
