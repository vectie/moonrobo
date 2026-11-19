# Actor planner coordinator

This adapter sends the current skill catalog and a user task to LunaFlux, accepts
one completed JSON skill proposal, rechecks the local control context, then
submits through the existing skill supervisor. It imports no actor runtime,
LibTorch, device implementation or robot SDK. LLM latency does not consume the
execution TTL; the actor tick does not call this adapter.

`propose` and `plan_and_submit` accept optional `images`. Encoded observations
become ordered OpenAI text/inline-image parts for LunaFlux `serve-media`.
PNG/JPEG bytes and a human-readable source label are sufficient; a future SDK
adapter can pass a captured encoded frame without writing it to disk. A frame
constructor checks its signature and 8 MiB byte ceiling; LunaFlux remains the
decoder and processor authority. There are at most eight images and the entire
serialized HTTP request must fit 16 MiB. All data uses inline base64; the model
server is never instructed to open a local path or fetch a URL.

```mbt check
///|
async fn _plan_camera_observation(
  endpoint : String,
  model : String,
  catalog : @task.Advertisement,
  encoded_frame : Bytes,
) -> @skills.Proposal {
  let image = @policy_planner.ImageObservation::from_encoded(
    encoded_frame,
    source="front camera",
  )
  @policy_planner.propose(
    endpoint,
    model,
    catalog,
    "Select a suitable skill.",
    images=[image],
    timeout_ms=30000,
  )
}
```

Calls without images retain their text-string request shape. Caller headers
are preserved except framing headers, which are set from the exact UTF-8 body.
Timeout, malformed/truncated model output, a changed catalog/control context or
an invalid skill proposal prevents submission. Images grant no robot control
authority. Capture freshness, physical orientation/calibration and visual model
quality still need the supplied camera/robot hardware; this API accepts explicit
snapshots and does not invent a camera SDK or a continuous perception loop.

The CLI accepts explicit image files outside the actor process:

```sh
moon run cmd/actor_task --target native -- plan-images TASK_URL LUNAFLUX_URL MiniCPM-V-4.7-35B-A3B 'Select a skill for these observations.' visual-one 1000 front.png hand.jpg
```

It labels files `view-1`, `view-2`, etc., and sends image bytes rather than local
paths. It inherits `LUNAFLUX_API_KEY` and gives planning a 30-second timeout.
The request still goes through the catalog/context and proposal checks before
the task service can accept it.

The hardware-free integration uses real MoonRobo task/client processes and
LunaFlux's full-program HTTP/media runtime fixture. Only sampled model tokens
are scripted. It checks an accepted bounded reference and clean native model
teardown; it loads no actor/robot writer and qualifies no GPU arithmetic or
visual quality:

```sh
moon run scripts/test_lunakine_visual_planner.mbtx ABSOLUTE_MOONROBO ABSOLUTE_LUNAFLUX ACTUAL_MINICPM_ASSETS NEW_OUTPUT
```

The small PNG/JPEG fixtures were generated for this software work; no camera or
encoder dependency enters this planner package.
