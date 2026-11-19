# SDK-input E1 shadow service

This package composes the existing SDK sensor adapter, prepared reference reader,
LunaKine/reference actor, command mapping and task host for sensor qualification.
Its output callback records complete24-slot command frames. It never calls
`Controller::publish`. The separate `cmd/e1_sdk_shadow` uses this package while
the original `cmd/e1_actor` remains free of SDK imports.

The CLI explicitly opens the selected SDK plugin and initializes vendor SDK/DDS.
It enables no command publisher or physical stop implementation. Confirm vendor
initialization behavior and installed SDK/NIC binding before using it on the
actual host. Real sensor conventions, calibration and policy quality remain
separate qualification work.

```sh
moon run cmd/e1_sdk_shadow --release --target native -- reference BUNDLE SDK_PLUGIN SESSION_JSON 127.0.0.1:8171
moon run cmd/e1_sdk_shadow --release --target native -- ascend BUNDLE CANN_LIBRARY MODEL_OM SDK_PLUGIN SESSION_JSON 127.0.0.1:8171
```

The reference command explicitly uses CPU numerical inference. The Ascend
command explicitly loads the chosen CANN runtime/model; errors do not select
another backend. Both use SDK observations, record outputs and accept tasks
through the existing HTTP protocol. Starting the service does not start a skill.

`SESSION_JSON` has format `moonrobo.e1-sdk-shadow.v1`:

| Field | Meaning |
| --- | --- |
| `catalog_id`, `skills` | Fresh process-local catalog and existing typed `policy_skills.Skill` records. Each skill selects a prepared `reference_id` and must offer no parameters. Give its deadline budget headroom beyond the motion duration. |
| `joint_calibration` | Existing `moonrobo.e1-sdk-calibration.v1` record: exact profile, named axes, expected IDs, signs, zeros, gains and complete explicit extra motors. |
| `imu_calibration` | Existing explicit quaternion/gyro/frame/unit/mount/world calibration record. |
| `references` | Prepared reference JSON file paths, used as written relative to the process working directory. Absolute paths are convenient for deployment. Reference IDs must be distinct and cover the catalog. |
| `maximum_sensor_age_ms` | Nonnegative Int64 encoded as a decimal JSON string; explicit local callback-receipt age budget, including preparation/inference time. |

Use the [joint/IMU calibration contract](../sdk_e1_policy/README.mbt.md) and
[reference exporter](../e1_actor_reference/README.mbt.md). No hardware calibration
defaults or qualified physical motions are supplied. File/IMU/reference checks
run before the CLI opens the SDK; joint names resolve when binding the already
opened controller. SMC observations use the actor's saved feature scales.

```mbt check
///|
async fn _prepare(
  actor : @actor.Actor,
  session : String,
) -> @e1_actor_sdk_shadow.Plan {
  @e1_actor_sdk_shadow.Plan::read(actor, session)
}

///|
fn _host(
  plan : @e1_actor_sdk_shadow.Plan,
  controller : @low.Controller,
  clock : () -> Int64,
  record : (Json) -> Unit raise,
  stopped : () -> Unit,
) -> @host.Host raise {
  plan.host(controller, clock~, record~, stopped~)
}
```

The actor/controller remain borrowed until host execution and cleanup return.
`record` receives `moonrobo.e1-sdk-shadow-tick.v1` JSON with `published:false`,
`hardware_qualified:false`, host `recorded_at_ms` and24 ordered command records.
Each record contains slot, position, velocity, torque, kp and kd. Record time is
not a sensor-acquisition timestamp. The CLI prints these JSON rows to stdout.
Recording failures propagate and retire the owned task; the supplied `stopped`
callback is a software lifecycle notification, not a motor stop or device close.
Use one synchronous owner; vendor callbacks/modules retain their existing
process-resident lifetime. This path makes no50Hz/jitter or watchdog claim.

The actual-header fake-SDK test exercises raw capture, calibrated99 features,
numerical inference, prepared references, HTTP completion, mapped frames and
recording failure. It checks that the native publication counter never changes.
The standalone trained-actor smoke is reproducible with:

```sh
moon run scripts/test_e1_sdk_shadow.mbtx ABSOLUTE_REPO ACTUAL_BUNDLE ACTUAL_HEADER_FAKE_SDK NEW_OUTPUT
```

`output/e1-sdk-shadow-service-v1/report.json` records task completion, two command
frames and one software stop notification through the real trained portable
actor and fake SDK. Calibration and references are synthetic. The fixture uses
a fake-only joint lookup to inject status; never deploy that generated session
as hardware calibration. No vendor SDK, accelerator or robot was accessed.
