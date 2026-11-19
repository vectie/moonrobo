# Calibrated E1 actor / SDK mapping

This MoonRobo package converts the deployment-only actor's outputs into complete
SDK3.1 motor frames and converts raw joint status back to actor-profile order.
It imports no trainer, LibTorch or LunaFlux. It initializes no SDK/runtime and
never publishes a command. The existing SDK transport remains a separate owner.

`Calibration` is an explicit `moonrobo.e1-sdk-calibration.v1` record bound to the
actor's profile ID. It contains one `Axis` per physical actor joint, and one
`FixedMotor` per remaining SDK joint. Its numbers/names are not supplied by the
library: determine them from the installed robot and qualify them separately.

| Field | Meaning |
| --- | --- |
| `actor_joint` | Exact name from `Bundle::joints()`. |
| `sdk_joint` | Exact SDK lookup name, resolved once at construction. |
| `motor_id` | Expected status ID for that SDK slot; distinct from slot index. |
| `direction`, `zero` | `q_model = direction * (q_sdk - zero)`, radians, direction±1. Velocity uses the same direction. |
| `kp`, `kd` | Explicit finite nonnegative SDK position-PD gains. Simulation profile gains are not silently adopted. |
| `FixedMotor` | Full position/velocity/torque/gain command for a joint absent from the actor; no automatic padding or stop/hold semantics. |

```mbt check
///|
fn _bind(
  bundle : @actor.Bundle,
  calibration : @sdk_e1_policy.Calibration,
  controller : @low.Controller,
) -> @sdk_e1_policy.Mapping raise {
  @sdk_e1_policy.Mapping::new(bundle, calibration, resolve=name => {
    controller.joint_index(name)
  })
}

///|
fn _build(
  mapping : @sdk_e1_policy.Mapping,
  actions : ArrayView[Double],
) -> Array[@low.MotorCommand] raise {
  mapping.commands(actions)
}
```

`Mapping::new` binds every actor joint exactly once and every SDK slot exactly
once. It rejects missing, repeated or unresolved axes/slots. It accepts an
offline name lookup as well as a previously opened SDK controller. No SDK joint
name/order/sign is guessed from the training profile's names.

`joint_state(sample)` checks IDs and reported errors for all24 status slots,
then returns calibrated physical q/qd in actor order. It does not interpret the
IMU, build observation history/goals or assign freshness. The reference owner
retains capture time plus `Sample::age_ms` and uses the runner's time domain.

`commands(actions)` first applies the saved actor's nominal position conversion,
then `q_sdk = zero + direction * q_model`, placing results in resolved SDK slots.
Controlled axes use position PD with zero target velocity/feedforward torque;
extra axes use their complete explicit commands. The transport separately adds
the SDK's command `motor_id=slot` convention. Status IDs remain explicitly
configured and are not inferred from that command convention.

`Imu::new(ImuCalibration)` also prepares explicit quaternion order
(`wxyz`/`xyzw`), orientation direction (`sensor_to_world`/`world_to_sensor`), gyro
frame (`sensor`/`body`/SDK `world`), gyro-unit conversion and mounting/world
rotations. Matrices are row-major, right-handed rotations, checked once at
preparation. No convention or numeric calibration is inferred from SDK field
names. Quaternion magnitude is normalized; zero/nonfinite input is rejected.

For `C_BS = sensor_to_body`, `R_AW = world_to_actor_world` and measured
`R_WS = sensor_to_world`, the calibrated body rotation is
`R_AB = R_AW * R_WS * transpose(C_BS)`. Gyro is converted to body rad/s;
gravity is the negative third row of `R_AB`. The supplied reference rotation
must map its body into the same actor world. Relative orientation uses
`transpose(R_AB) * R_reference`, encoded in training's row-interleaved first
two columns (`0,1,3,4,6,7`), rather than concatenating columns.

`Observer::new(mapping,imu)` prepares the actor's saved SMC feature contract.
`Observer::observation(sample,previous,reference_rotation)` composes raw coherent
status -> calibrated q/qd/attitude ->99 raw actor features. Saved feature scales
are applied after physical unit conversion: the deployed legacy actor uses
velocity0.1 and gyro0.25, while current contracts may use1.0. Do not include
these feature factors in `gyro_to_radians` or apply normalization again.

```mbt check
///|
fn _observe(
  observer : @sdk_e1_policy.Observer,
  sample : @low.Sample,
  previous : ArrayView[Double],
  reference_rotation : ArrayView[Double],
) -> Array[Double] raise {
  observer.observation(sample, previous, reference_rotation)
}
```

The caller owns actual root/IMU calibration, motion references, freshness,
mode/authority, hardware position/velocity/torque limits, independent watchdog,
stop/takeover and actual `Controller::publish`. There is no physical sink or live
motor CLI wired by this package. Tick allocations and timing are not qualified.

Two pure tests cover23/24-axis mapping and incomplete/ambiguous calibration.
The actual-header fake-SDK fixture also checks raw-state conversion, reversed
slots, signs/zeros/gains, an explicit extra joint, full-frame publication and
wrong-ID/error rejection with recovery through the real MoonBit loader ABI.
`target/sdk-e1-policy-validation-v1/report.json` passes C++ and generated MoonBit
C/loader ASan/UBSan. It retains prebuilt runtime/mimalloc and disables leak
detection for the MoonBit run. All calibration is synthetic; no vendor SDK/DDS
library, hardware or robot was accessed.

The newer `target/sdk-e1-sensor-validation-v1/report.json` and its `.log` also
cover raw SDK motor/quaternion/gyro values through the prepared observer into
all99 features with saved legacy scales, under the same ASan/UBSan scope.
Pure analytic tests cover12 noncommuting frame/order/direction/gyro combinations.
The separate training comparison matches3,168 features across32 cases with
23/24 axes and legacy/current contracts (`target/e1-observation-training-parity.log`).
These are software/numeric checks, not physical calibration, freshness, NPU
timing or learned-policy quality evidence. No physical sink or motor CLI was added.
