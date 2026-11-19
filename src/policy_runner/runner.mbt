///|
/// A local reference adapter constructs calibrated, training-compatible inputs.
/// Previous actions and reference step are local; task messages never carry them.
pub(all) struct Inputs {
  observation : Array[Double]
  goals : Array[Double]
  captured_at_ms : Int64
  complete : Bool
}

///|
pub(all) enum Tick {
  Idle
  Action(Array[Double])
  Stopped
}

///|
/// One synchronous tick. Networking and LLM calls belong outside this object.
/// The sink may record shadow outputs; a physical sink needs the E1 SDK adapter.
pub struct Runner {
  priv supervisor : @skills.Supervisor
  priv clock : () -> Int64
  priv mut last_time : Int64
  priv history_frames : Int32
  priv observation_width : Int32
  priv goal_width : Int32
  priv action_width : Int32
  priv maximum_sensor_age_ms : Int64
  priv predict : (Array[Array[Double]], Array[Double]) -> Array[Double] raise
  priv reference : (@skills.Execution, Int32, Array[Double], Int64) -> Inputs raise
  priv sink : (Array[Double]) -> Unit raise
  priv stop : () -> Unit
  priv mut request_id : String?
  priv mut step : Int32
  priv mut history : Array[Array[Double]]
  priv mut previous : Array[Double]
}

///|
/// The supplied nondecreasing clock uses the supervisor/task host's millisecond
/// time domain. Replay can inject a deterministic clock; live owners use their
/// current host clock. No tick-start-only timestamp or implicit wall clock.
pub fn Runner::new(
  supervisor : @skills.Supervisor,
  clock~ : () -> Int64,
  history_frames~ : Int32,
  observation_width~ : Int32,
  goal_width~ : Int32,
  action_width~ : Int32,
  predict~ : (Array[Array[Double]], Array[Double]) -> Array[Double] raise,
  reference~ : (@skills.Execution, Int32, Array[Double], Int64) -> Inputs raise,
  sink~ : (Array[Double]) -> Unit raise,
  stop~ : () -> Unit,
  maximum_sensor_age_ms~ : Int64 = 100L,
) -> Runner raise {
  guard history_frames > 0 &&
    observation_width > 0 &&
    goal_width > 0 &&
    action_width > 0 &&
    maximum_sensor_age_ms >= 0L else {
    fail("invalid actor loop dimensions or sensor age")
  }
  {
    supervisor,
    clock,
    last_time: 0L,
    history_frames,
    observation_width,
    goal_width,
    action_width,
    maximum_sensor_age_ms,
    predict,
    reference,
    sink,
    stop,
    request_id: None,
    step: 0,
    history: [],
    previous: Array::make(action_width, 0.0),
  }
}

///|
fn Runner::stop_current(self : Runner) -> Unit {
  if self.request_id is Some(_) {
    (self.stop)()
    self.request_id = None
    self.history.clear()
  }
}

///|
/// Retire this runner's owned execution and call its explicit stop callback
/// once. No-op when idle; a newer accepted replacement is never cancelled.
/// This software notification is not a physical stop or device close.
pub fn Runner::interrupt(self : Self, detail~ : String) -> Unit {
  if self.request_id is Some(id) {
    ignore(self.supervisor.cancel(id, detail~)) catch {
      _ => ()
    }
  }
  self.stop_current()
}

///|
fn valid(values : Array[Double], width : Int32) -> Bool {
  values.length() == width && values.all(x => x == x && x - x == 0.0)
}

///|
fn Runner::time(self : Self) -> Int64 raise {
  let now = (self.clock)()
  guard now >= self.last_time else { fail("actor clock moved backward") }
  self.last_time = now
  now
}

///|
fn Runner::owns_execution(
  self : Self,
  execution : @skills.Execution,
  now : Int64,
) -> Bool {
  self.supervisor.snapshot(now) is Some(current) &&
  current.request_id == execution.request_id &&
  current.state is Running
}

///|
fn Runner::fresh(self : Self, inputs : Inputs, now : Int64) -> Bool {
  inputs.captured_at_ms >= 0L &&
  inputs.captured_at_ms <= now &&
  now - inputs.captured_at_ms <= self.maximum_sensor_age_ms
}

///|
/// Deadline and telemetry freshness are checked locally, even with no task client.
/// Completion means the reference adapter reported completion, not LLM success.
/// Rechecks after reference/prediction suppress late results; they cannot interrupt
/// a blocked call or replace an independent qualified device watchdog.
///
/// ```mbt check
/// test {
///   let supervisor = @skills.Supervisor::new("example", [
///     {
///       id: "hold",
///       description: "example",
///       reference_id: "hold-frames",
///       maximum_duration_ms: 1000,
///       parameters: [],
///     },
///   ])
///   let runner = @policy_runner.Runner::new(
///     supervisor,
///     clock=() => 0L,
///     history_frames=1,
///     observation_width=1,
///     goal_width=1,
///     action_width=1,
///     predict=(_, _) => [0.0],
///     reference=(_, _, _, _) => fail("no skill was accepted"),
///     sink=_ => (),
///     stop=() => (),
///   )
///   assert_true(runner.tick() is Idle)
/// }
/// ```
pub fn Runner::tick(self : Runner) -> Tick raise {
  errdefer {
    if self.request_id is Some(id) {
      // Cancellation/replacement may already have retired this request. Preserve
      // the original callback failure and never finish a newer execution.
      ignore(
        self.supervisor.finish(
          id,
          success=false,
          detail="local actor/reference/sink failure",
        ),
      ) catch {
        _ => ()
      }
    }
    self.stop_current()
  }
  let now_ms = self.time()
  guard self.supervisor.snapshot(now_ms) is Some(execution) &&
    (execution.state is Accepted || execution.state is Running) else {
    let stopped = self.request_id is Some(_)
    self.stop_current()
    return if stopped { Stopped } else { Idle }
  }
  if self.request_id != Some(execution.request_id) {
    self.stop_current()
    self.request_id = Some(execution.request_id)
    self.step = 0
    self.previous.fill(0.0)
    ignore(self.supervisor.start(execution.request_id, now_ms))
  }
  let inputs = (self.reference)(execution, self.step, self.previous, now_ms)
  let reference_time = self.time()
  guard self.owns_execution(execution, reference_time) else {
    self.stop_current()
    return Stopped
  }
  guard self.fresh(inputs, reference_time) else {
    fail("actor telemetry is stale or ahead of the local clock")
  }
  if inputs.complete {
    ignore(
      self.supervisor.finish(
        execution.request_id,
        success=true,
        detail="reference completed",
      ),
    )
    self.stop_current()
    return Stopped
  }
  guard valid(inputs.observation, self.observation_width) &&
    valid(inputs.goals, self.goal_width) else {
    fail("actor reference dimensions or finite values differ")
  }
  if self.history.is_empty() {
    self.history = Array::makei(self.history_frames, _ => {
      inputs.observation.copy()
    })
  } else {
    ignore(self.history.remove(0))
    self.history.push(inputs.observation.copy())
  }
  let actions = (self.predict)(self.history, inputs.goals)
  guard valid(actions, self.action_width) else {
    fail("actor output dimensions or finite values differ")
  }
  let publication_time = self.time()
  guard self.owns_execution(execution, publication_time) else {
    self.stop_current()
    return Stopped
  }
  guard self.fresh(inputs, publication_time) else {
    fail("actor telemetry became stale during prediction")
  }
  (self.sink)(actions)
  self.previous = actions.copy()
  self.step += 1
  Action(actions)
}
