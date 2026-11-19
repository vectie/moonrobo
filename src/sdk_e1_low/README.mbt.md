# SDK 3.1 low-control transport

This MoonRobo package exposes raw E1 SDK status, joint-name lookup and complete
24-slot motor frames. LunaKine remains the numerical actor runtime; this package
imports neither LunaKine nor the training/model packages. It does not map the
actor's 23 physical/29 output channels onto SDK slots, interpret the raw IMU
quaternion/frame, choose gains, construct references or implement stop/takeover.
Joint and IMU conversion, model normalization and authority belong to the
caller. The selected architecture is described in the
[LunaKine plan](../../docs/LUNAKINE_DEPLOYMENT_PLAN.md).

`Controller::open` explicitly loads a selected plugin and initializes its vendor
`LowController`/DDS. Importing the package and constructing `Sample` do neither.
SDK callbacks update synchronized C++ state, never MoonBit objects. One local
synchronous owner calls `capture_into` on reusable storage, resolves names once
with `joint_index`, and submits a full motor frame through `publish`.

```mbt check
///|
fn _raw_sample(controller : @sdk_e1_low.Controller) -> (Int64, Double) raise {
  let sample = @sdk_e1_low.Sample::new()
  controller.capture_into(sample)
  (sample.age_ms(), sample.joint(0).position)
}

///|
fn _motor_frame(
  controller : @sdk_e1_low.Controller,
  commands : ArrayView[@sdk_e1_low.MotorCommand],
) -> Unit raise {
  controller.publish(commands)
}
```

Samples fail before the first status callback; a failed capture invalidates its
destination. Joint state retains SDK motor IDs. `age_ms` is local callback
receipt age measured at capture, excluding hardware/DDS queuing; it does not
update as a stored sample ages. The calibrated reference adapter retains its
own capture time and applies the existing actor runner's freshness/deadline rules.
Vector accessors materialize small read-only arrays; no allocation-free tick or
timing claim is made for this unqualified path.

Command arrays must contain exactly 24 finite entries with nonnegative finite
`kp`/`kd`, in resolved SDK slot order. The private C++ adapter calls
`set_joint(std::array<MotorCmd,24>)` with `motor_id=slot`, matching the SDK 3.1
example. It never pads, truncates, reorders or converts actor outputs. A slot
lookup is not evidence that the trained actor matches the physical robot.

An explicit mapping can resolve names through this controller and produce all24
commands; publication remains the qualified caller's responsibility. See the
commissioning documentation in [`deploy/e1`](../../deploy/e1/README.md).
The January-protocol command path is a separate implementation.

Build on the supported Linux target through the existing CMake project:

```sh
cmake -S src/sdk_e1_native -B target/sdk-e1-v31 -DMOONROBO_E1_SDK_API=3.1 -DSDK_ROOT=/ABSOLUTE/sdk
cmake --build target/sdk-e1-v31 --target moonrobo_e1_low
```

Select the correct SDK/DDS library directories and Eigen installation as described
in `../sdk_e1_native/MIGRATION.md`. Install `libmoonrobo_e1_low.so` and
`moonrobo_e1_low_worker_v1` together in the same directory. The worker owns
the vendor singleton and all DDS entities. The plugin communicates with it over
a private Unix socket. `Controller::close` releases a handle. Closing the last
handle waits for the worker to exit. Normal client exit also reaps the worker.
Linux terminates the worker if its spawning thread dies.

Once a command has been published, the worker expires its session after
100 ms without a fresh publish. This host-side timeout allows five nominal
20 ms ticks. Status reads do not renew it. After expiry, close outstanding
handles before opening another session. The host provides no real-time
deadline for the robot's detection of a lost DDS peer or for its handoff.

The suspended elbow commissioning path records shadow commands before powered
trials. Its measured results do not qualify model-driven full-body control or
establish a manufacturer-guaranteed response to loss of DDS commands.

The local actual-header/fake-SDK checks run with:

```sh
moon run scripts/test_sdk_e1_low.mbtx ABSOLUTE_REPO SDK_ROOT EIGEN3_PARENT MOON_ROOT NEW_OUTPUT
```

They test C++ and generated MoonBit C/loader code with ASan/UBSan, raw fields,
reusable capture, frame widths/gains, named lookup and SDK failure/reuse. The
MoonBit sanitizer run retains the prebuilt runtime/mimalloc and disables leak
detection. The fake library implements the actual SDK declarations without
linking the vendor SDK or DDS. The `e1_elbow_sdk_loopback` fixture exercises the
installed Linux SDK in a private network namespace with synthetic elbow feedback.
