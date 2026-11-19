# SDK 3.1 high-level adapter fixture

The test compiles `sdk_adapter_v31.cpp` and a fake implementation of the SDK's
`HighController` methods against the actual SDK headers and Eigen3.4.0. It never
links `noetix_e1_sdk` or DDS, so no controller initialization/publication can reach
a robot. Both translation units use warnings denied, ASan and UBSan.

```sh
moon run scripts/test_sdk_e1_v31_adapter.mbtx ABSOLUTE_MOONROBO SDK_ROOT PARENT_OF_EIGEN3_DIRECTORY NEW_OUTPUT
```

The Eigen parent contains `eigen3/Eigen/Dense`, matching the SDK's include form.
The fixture asserts `SDK_VERSION == "3.1.0"`, field layout/callback snapshot
ownership, delayed callback age, initialization/error paths, all24 motor/IMU/
remote/mode fields, output bounds, finite/narrowing checks and named command
mapping. In particular, bridge code12 maps to SDK `DEFAULT`14, not SDK `TAIJI`12.

Source audit uses the clean local SDK checkout
`3055bdc644f61caf948d935ee274c5c48703c24f`. Linux plugin linking, actual SDK/DDS
behavior and the low-level actor/calibration/authority path remain separate gates.
