# Deployment-only E1 shadow execution

This package owns recorded SMC replay and the task-driven shadow service. It
uses the existing local policy runner, typed skill supervisor and HTTP task
service. It imports no training, LibTorch, CUDA, simulator, LunaFlux or robot SDK
package. Both `cmd/e1_actor` and the older training/evaluation commands call this
same implementation.

`Policy` is a borrowed view of the actor's dimensions, prediction callback and
nominal position conversion. `Policy::from_actor` binds a deployment-only
LunaKine/reference actor. `Policy::new` also allows the offline LibTorch
comparison to lend its existing predictor without a reverse dependency.
Neither constructor takes ownership of model resources.

```mbt check
///|
async fn _serve(
  actor : @actor.Actor,
  recorded : String,
  address : String,
) -> Unit {
  defer (actor.close() catch { _ => () })
  @e1_actor_shadow.serve(
    @e1_actor_shadow.Policy::from_actor(actor),
    recorded,
    address,
  )
}
```

Keep the actor open until replay/service work returns, then close it. The
package owns no native resources or physical motor sink. Its supported recorded
profile is the99-feature SMC observation,29 embedded actions,23/24 physical axes,
oldest-to-newest history and73 features per preview frame.

`ActorReplay` and `ActorReplayFrame` preserve the existing
`moonrobo.actor-replay.v1` tape. The training package reexports these types for
source and JSON compatibility. Parameter-free skills select nonempty recorded
frame lists by `reference_id`. Previous-action features64..92 are replaced by
the local runner's outputs, and history resets for a new task.

`replay(policy,tape)` uses the tape's deterministic20ms clock and requires a
fresh catalog and matching frame cadence. `replay_file` additionally reads/writes
JSON. `serve(policy,tape_path,address)` uses one live host clock shared with task
admission, follows nominal20ms ticks and skips missed periods instead of issuing
a catch-up burst. HTTP/LLM calls remain outside the synchronous actor tick.

The service now delegates HTTP and scheduling to the shared
[task host](../policy_host/README.mbt.md). An overrun waits a full period after
the slow work, rather than yielding into an immediate second tick. Cooperative
host shutdown interrupts an owned task and sends one software stop notification.
The real trained portable actor's HTTP regression passes at
`output/e1-shared-host-shadow-v1/report.json`; device timing and physical stop
behavior remain unqualified.

Recorded observations are stamped at replay time in service mode. This exercises
task/control software and does not prove live sensor freshness,50Hz device
performance or physical reference quality. Reports/rows retain `published:false`;
Completed means the reference finished, not that a robot task succeeded.

From MoonRobo:

```sh
moon run cmd/e1_actor --release --target native -- shadow-reference BUNDLE RECORDED_TAPE NEW_REPORT
moon run cmd/e1_actor --release --target native -- serve-shadow-reference BUNDLE RECORDED_TAPE 127.0.0.1:8171
moon run cmd/e1_actor --release --target native -- shadow-ascend BUNDLE CANN_LIBRARY MODEL_OM RECORDED_TAPE NEW_REPORT
moon run cmd/e1_actor --release --target native -- serve-shadow-ascend BUNDLE CANN_LIBRARY MODEL_OM RECORDED_TAPE 127.0.0.1:8171
```

Ascend commands are explicit NPU execution and require the actual target runtime
and compiled model. They do not substitute another backend. Portable reference
commands initialize no accelerator or SDK. Every command is shadow-only.

The local service smoke is:

```sh
moon run scripts/test_lunakine_actor_clock.mbtx ABSOLUTE_REPO ACTUAL_BUNDLE RECORDED_TAPE NEW_OUTPUT
```

It builds only `cmd/e1_actor`, submits through actual task HTTP using advertised
host time, observes Completed and cancels/reaps its owned service process.
`output/e1-actor-shadow-service-v1/report.json` passes with the actual trained
portable actor and recorded features. The source graph at
`output/e1-actor-deployment-v3/report.json` excludes training/simulator imports.
The focused runner/task/skills/shadow suite passes17/17, and the trained
LibTorch/reference plus three-frame replay comparison still passes after
extraction (`target/e1-shadow-extraction-trained-comparison.log`).
