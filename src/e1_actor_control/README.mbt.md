# Local E1 actor control composition

This package connects the existing task/actor runner to calibrated SDK inputs
and complete motor command frames. MoonRobo owns the reference provider, task
state, SDK transport and control policy; LunaKine owns numerical inference.
The same composition accepts an explicitly selected portable reference actor
for software validation or an Ascend actor for later target qualification.
It imports no training, LibTorch, simulator or LLM package.

Prepare the actor, joint mapping and IMU observer from the same selected bundle.
Profile IDs are checked when composing; a shared profile ID alone does not
prove that separately prepared mappings or feature contracts are equivalent.
The caller retains the actor and an already-open controller until execution
ends, then closes them explicitly. Construction initializes no SDK and sends
no motor command.

```mbt check
///|
fn _compose(
  supervisor : @skills.Supervisor,
  actor : @actor.Actor,
  mapping : @policy.Mapping,
  observer : @policy.Observer,
  controller : @low.Controller,
  clock : () -> Int64,
  reference : (@skills.Execution, Int32, Int64) -> @e1_actor_control.Reference raise,
  publish : (ArrayView[@low.MotorCommand]) -> Unit raise,
  stop : () -> Unit,
) -> @runner.Runner raise {
  let sensor = @e1_actor_control.Sensor::from_sdk(controller, observer, clock~)
  @e1_actor_control.new_runner(
    supervisor,
    actor,
    mapping,
    sensor,
    reference~,
    publish~,
    stop~,
    maximum_sensor_age_ms=100L,
  )
}
```

The reference callback receives the accepted execution, local step and host
time. It returns trained preview goals, a row-major reference-body-to-actor-world
rotation and a completion flag. Preparing correctly aligned goals and qualified
motion references remains the caller's responsibility. The synchronous owner
calls `tick()` on the returned runner; neither networking nor LLM generation
belongs inside that tick. A scheduler must separately maintain the intended
50Hz cadence without replaying missed ticks in a burst.

The shared [task host](../policy_host/README.mbt.md) supplies that scheduling and
the existing HTTP task protocol. Prepare the sensor and runner inside its
factory so task admission, capture and deadlines share the same clock:

```mbt check
///|
fn _prepared_host(
  supervisor : @skills.Supervisor,
  actor : @actor.Actor,
  mapping : @policy.Mapping,
  observer : @policy.Observer,
  controller : @low.Controller,
  clip : @reference.Clip,
  clock : () -> Int64,
  publish : (ArrayView[@low.MotorCommand]) -> Unit raise,
  stop : () -> Unit,
) -> @host.Host raise {
  @host.Host::new(supervisor, clock~, prepare=(owner, clock) => {
    let sensor = @e1_actor_control.Sensor::from_sdk(
      controller,
      observer,
      clock~,
    )
    @e1_actor_control.new_runner(
      owner,
      actor,
      mapping,
      sensor,
      reference=(execution, step, _) => {
        let frame = clip.frame(execution, step)
        {
          goals: frame.goals,
          body_to_world: frame.body_to_world,
          complete: frame.complete,
        }
      },
      publish~,
      stop~,
    )
  })
}
```

Retain borrowed devices until the host and its cooperative stop cleanup return.
No physical publication callback is supplied by the library. A synchronous
vendor call still blocks the event loop and requires an independent watchdog.

The [prepared reference reader](../e1_actor_reference/README.mbt.md) can supply
this callback without importing the trainer. It rejects unsupported parameters
and a mismatched reference ID. For example:

```mbt check
///|
fn _prepared_reference(
  clip : @reference.Clip,
  execution : @skills.Execution,
  step : Int32,
) -> @e1_actor_control.Reference raise {
  let frame = clip.frame(execution, step)
  {
    goals: frame.goals,
    body_to_world: frame.body_to_world,
    complete: frame.complete,
  }
}
```

Every active tick, including reference completion, captures a coherent SDK
sample and builds99 raw SMC features using the bundle's saved feature scales.
The existing runner owns history and previous actions. It checks task ownership,
deadline and sample freshness after preparation and after inference. Command
projection occurs inside prediction, so its cost is included before the final
checks and the explicit publication callback.

`Sensor::new` also supports recorded or deterministic inputs. Its capture
callback receives previous29 actions and the reference rotation, and returns
raw99 features plus local callback receipt age. The clock must be nonnegative,
nondecreasing and shared with task acceptance/deadlines. Its origin must allow
representing the sample's receipt time. For a floor-rounded age `a` and capture
start `s`, the conservative timestamp is `s - a - 1` milliseconds. Using capture
start includes capture/feature preparation time in later freshness checks;
the extra millisecond covers SDK age rounding. Invalid age/time fails the tick.
This measures time since a local SDK callback, not sensor acquisition or DDS
transit latency.

One synchronous owner retains the reusable sample and pending command frame.
Do not call the sensor or runner concurrently. The explicit stop callback runs
on the runner's existing stop/failure paths; clearing pending commands is not a
physical stop. Publication, authority, hardware limits, watchdog and qualified
stop/takeover behavior belong to the host integration. No live motor CLI is
provided, and a native call cannot be interrupted by this synchronous runner.

Four unit tests cover conservative capture timing and rounding, completion and
task history reset, original capture errors, invalid ages, clock rollback and
profile mismatch. The actual-header fake SDK also exercises the composed path:
task -> raw status -> calibrated99 features -> numerical reference actor ->
complete24-slot mapped frame -> fake publication -> completion/stop callback.
Those fixtures use synthetic calibration and make no hardware timing, physical
stop or learned-policy success claim.
