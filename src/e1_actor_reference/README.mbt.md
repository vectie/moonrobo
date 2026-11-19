# Prepared E1 motion references

This deployment-only package reads `moonrobo.e1-actor-reference.v1` clips for
the selected actor bundle. It imports neither training/geometry nor SDK/LLM
packages. Training owns preparation; deployment selects already encoded goals
and reference attitudes. Saved actor normalization still belongs to LunaKine.

An artifact contains the exact profile ID and physical joint order, a
`reference_id`, `control_dt_ms:20`, `goal_layout:"aligned.preview73.v1"` and an
array of frames. Each frame has raw `goals` of the actor's goal width and a
row-major `body_to_world` rotation in the calibrated actor world. Shapes, finite
values, proper rotations and the bundle association are checked once at load.
This checks representation, not motion quality or physical qualification.

The offline exporter uses `MotionLibrary::goal`, the existing training encoder.
Each future frame contributes73 values: heading-relative displacement3 and
orientation6, future-body-frame linear/angular velocity3+3, embedded joint
positions29 and joint velocities29 scaled by0.1. Preview frames start at the
next reference state and repeat the selected clip's final state at its boundary.
No new preview geometry or normalizer is implemented here.

```sh
moon run cmd/e1_train --release --target native -- export-lunakine-reference --dataset DATASET --bundle BUNDLE --clip-id CLIP_ID --split validation --output NEW_REFERENCE_JSON
moon run cmd/e1_actor --release --target native -- inspect-reference BUNDLE REFERENCE_JSON
```

Export checks the existing dataset/asset identities and joint embedding. It
requires no tensor library, physics library, SDK, GPU or NPU initialization.
The dataset must already have matching prepared assets; this command does not
retarget or certify a new motion. Inspection imports only deployment packages
and does not read actor weights or open a device. Export refuses to overwrite.

```mbt check
///|
async fn _load(
  bundle : @actor.Bundle,
  path : String,
) -> @e1_actor_reference.Clip {
  @e1_actor_reference.Clip::read(bundle, path)
}

///|
fn _next(
  clip : @e1_actor_reference.Clip,
  task : @skills.Execution,
  step : Int32,
) -> @e1_actor_reference.Frame raise {
  clip.frame(task, step)
}
```

`frame(execution,step)` checks the selected reference ID and rejects parameters:
no speed/amplitude transform is silently ignored. Earlier frames drive inference;
the final stored frame and subsequent steps report `complete:true` with the final
data. Thus an N-state clip has N-1 action ticks and duration `(N-1)*20ms`, matching
the existing reference-transition convention. This is motion duration, not a
task deadline budget: the supervisor expires at the deadline, so allow explicit
headroom for acceptance-to-first-tick delay and the terminal capture/check.
The returned arrays are copies;
callers cannot mutate the prepared clip. No automatic repeat, transition blend
or root/world alignment is applied.

Supply the frame's fields to `e1_actor_control.Reference` in its reference
callback. The existing runner owns history, step reset, deadline and completion;
completion still needs a fresh sensor capture. The host schedules50Hz ticks and
owns calibrated reference/world alignment, evaluated skills and physical control.
This package cannot qualify policy quality, stability or robot task success.

Three pure tests cover metadata/geometry, ownership, selection, unsupported
parameters and terminal semantics. A separate training comparison verifies25,696
preview values across23/24-axis profiles, both existing heading encodings,
1/10-frame previews and two clips with different lengths, including padding and
unused channels (`target/e1-prepared-reference-training-parity.log`). Those
motions are synthetic; no physical skill is shipped by these tests.
