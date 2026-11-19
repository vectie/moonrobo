# E1 deployment-only actor

This package consumes the existing MoonRobo/LunaKine E1 bundle without importing
training, LibTorch, CUDA, MuJoCo, planner or robot SDK packages. LunaKine owns
the numerical actor spec and Ascend execution; MoonRobo owns physical joint
order, the23/24-axis prefix of29 actions and nominal position conversion.

`Bundle::read` loads `actor.json` and `robot.json`. `Bundle::parse` accepts their
already-parsed documents. It checks the companion's source dimensions, E1
profile, physical action mask and conversion-vector shapes. It does not hash
weights or reconstruct training state. The existing v1/v2 archive contracts and
portable bundle format remain unchanged. Training/evaluation compatibility
loaders delegate numerical execution to this package.

```mbt check
///|
async fn _prepare_ascend(
  directory : String,
  library : String,
  model : String,
) -> @e1_actor.Actor {
  let bundle = @e1_actor.Bundle::read(directory)
  @e1_actor.Actor::open_ascend(bundle, library, model)
}

///|
fn _positions(
  actor : @e1_actor.Actor,
  history : Array[Array[Double]],
  goals : Array[Double],
) -> Array[Double] raise {
  let actions = actor.forward_embedded(history, goals)
  actor.bundle().nominal_setpoints(actions[:])
}
```

`Actor::open_ascend` explicitly initializes the chosen CANN runtime/model; it
does not select another backend after failure. `Actor::reference` explicitly
selects the portable CPU reference from FP32 parameter bytes for offline checks.
Both consume oldest-to-newest raw observation history and raw preview goals;
saved normalization belongs to the actor. `forward_embedded` returns29 values
with unused channels zero; `forward` returns only physical actions. Close the
actor deterministically. Successful close is idempotent and prevents inference.

`nominal_setpoints` computes `default_q + scales * raw_action` in the trained
robot frame, with no calibration, gains, clipping or SDK publication. It is not
a motor command. The separate `sdk_e1_policy` package applies an explicit
calibrated mapping to SDK slots. Observation/IMU conventions, references,
freshness, authority and a qualified watchdog remain control-owner concerns.

`Bundle::smc_observation()` prepares the99-feature encoder from the saved
companion contract. `SmcObservation::encode` consumes calibrated physical q/qd,
29 previous raw actions, body gyro/gravity and six reference-relative rotation
values. It applies saved velocity/gyro feature scales and masks inactive joint
channels; model normalization is still applied by the actor. Metadata parsing
and profile checks happen once during preparation, outside ticks.

The actual deployed v1 actor declares velocity scale0.1 and gyro scale0.25.
Current profile defaults cannot substitute for that saved contract. Missing
feature metadata remains acceptable for explicit recorded-feature inference,
but observation preparation fails instead of guessing scales. The separate
SDK policy `Observer` supplies calibrated joints and IMU features.

The deployment-only CLI has no SDK commands:

```sh
moon run cmd/e1_actor --release --target native -- inspect BUNDLE
moon run cmd/e1_actor --release --target native -- inspect-reference BUNDLE REFERENCE_JSON
moon run cmd/e1_actor --release --target native -- reference BUNDLE INPUT_JSON NEW_OUTPUT_JSON
moon run cmd/e1_actor --release --target native -- ascend BUNDLE CANN_LIBRARY MODEL_OM INPUT_JSON NEW_OUTPUT_JSON
```

`INPUT_JSON` contains `history` (array of observation rows) and `goals` (flat
preview). Results retain all29 actions, physical joint names, nominal setpoints
and `published:false`. Running an Ascend inference does not establish hardware
qualification. Inspection and reference commands initialize no accelerator/SDK.

The same CLI now offers `shadow-reference`/`shadow-ascend` and
`serve-shadow-reference`/`serve-shadow-ascend` through the separate
[deployment shadow package](../e1_actor_shadow/README.mbt.md). It shares recorded
replay and task HTTP with the training compatibility wrappers, without importing
training or simulation code into the deployment entrypoint.

The [prepared reference reader](../e1_actor_reference/README.mbt.md) consumes
goals exported by the existing training encoder and reference body rotations.
`inspect-reference` validates the selected bundle association and prints frame
count/duration without loading weights or initializing a device.

The repeatable local smoke builds the CLI, checks source dependency closures
using `moon tree --package --json`, and runs the actual exported actor through
the portable reference:

```sh
moon run scripts/test_e1_actor_deployment.mbtx ABSOLUTE_REPO ACTUAL_BUNDLE NEW_OUTPUT
```

`output/e1-actor-deployment-v3/report.json` records23 physical/29 embedded actions
and both actor/mapping dependency closures. The compiled macOS executable links
only `libSystem`; this is local CPU/build evidence, not Linux/CANN qualification.
The existing trained LibTorch/reference and three-frame runner comparison also
passes after actor/shadow delegation (`target/e1-shadow-extraction-trained-comparison.log`).
