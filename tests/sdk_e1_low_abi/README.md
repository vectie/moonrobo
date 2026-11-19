# Actual-header low-control ABI fixture

`fake_sdk.cpp` implements the methods declared by SDK 3.1 `lowcontroller.h`.
Neither the standalone C++ test nor the shared fake SDK links vendor/DDS code.
The special `fixture_*` joint names are private test synchronization controls;
the production adapter only forwards names to the real SDK method.

The MoonBit executable checks the actual dynamic loader, borrowed buffers, all
24 motor states, raw IMU/remote/mode, full command layout and failures/reuse.
The standalone C++ test independently checks ABI widths, invalid gains/numerics
and named lookup. The automation also runs generated MoonBit C plus its loader
and an instrumented fake SDK under ASan/UBSan, retaining the prebuilt runtime
and mimalloc with leak detection disabled. These tests provide no robot timing,
calibration, stop/takeover or physical execution evidence.

```sh
moon run scripts/test_sdk_e1_low.mbtx ABSOLUTE_REPO SDK_ROOT EIGEN3_PARENT MOON_ROOT NEW_OUTPUT
```
