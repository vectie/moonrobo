# Local actor runner

`Runner` owns one skill execution's history, previous actions and reference step.
Reference construction, numerical prediction, output publication and qualified
stop behavior are injected. The package imports only the skill supervisor;
LLM/task networking, model frameworks and SDK resources stay outside its tick.

The constructor requires one nondecreasing millisecond clock in the same host
time domain as the supervisor's deadlines. `tick()` reads it at entry, after
reference preparation and after prediction. It rechecks current execution and
sensor age before the sink, so a callback that outlives the deadline, ages its
input, cancels or replaces the task cannot publish that result. A replacement
remains accepted until a fresh tick starts it with fresh history/previous actions.
Reference completion after expiry does not report successful task completion.

```mbt check
///|
fn _construct(
  supervisor : @skills.Supervisor,
  clock : () -> Int64,
  predict : (Array[Array[Double]], Array[Double]) -> Array[Double] raise,
  reference : (@skills.Execution, Int32, Array[Double], Int64) -> @policy_runner.Inputs raise,
  sink : (Array[Double]) -> Unit raise,
  stop : () -> Unit,
) -> @policy_runner.Runner raise {
  @policy_runner.Runner::new(
    supervisor,
    clock~,
    history_frames=10,
    observation_width=99,
    goal_width=730,
    action_width=29,
    predict~,
    reference~,
    sink~,
    stop~,
  )
}
```

The recorded replay adapter advances a local deterministic clock per frame. The
shadow HTTP service uses the same clock for task admission and actor execution;
reference/inference wall time is therefore included in its freshness checks.
There is no alternate timestamp argument to `tick` or default frozen clock.

A local callback failure retires the owned execution and invokes the supplied
stop. If cancellation/replacement already retired it, cleanup preserves the
original failure and cannot fail the newer request. Clock rollback also fails
locally. Callbacks and ticks belong to one synchronous owner and must not reenter
the runner. The sink retains responsibility for the actual authority/command API.

`interrupt(detail~)` retires only the execution owned by this runner, clears its
history and calls the explicit stop callback once. It is idempotent while idle
and preserves a newer accepted replacement. The shared
[task host](../policy_host/README.mbt.md) uses it during cooperative service
cancellation/error cleanup. It neither closes a device nor qualifies a physical
stop, and cannot interrupt a synchronous call already in progress.

Post-call checks cannot interrupt a blocked native inference or SDK call, or stop
the vendor's previously published target while it is blocked. An independent
qualified device/firmware watchdog and physical stop/takeover acceptance remain
required; the software callback tests provide no such hardware qualification.
