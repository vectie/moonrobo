///|
/// One local task HTTP service and synchronous actor tick owner. Preparation
/// receives the same supervisor and clock used by HTTP and scheduling. Device,
/// reference, publication and stop behavior remain in the caller's runner.
pub struct Host {
  priv runner : @runner.Runner
  priv service : @task.Service
  priv clock : () -> Int64
  priv period_ms : Int32
  priv mut serving : Bool
}

///|
pub fn Host::new(
  supervisor : @skills.Supervisor,
  clock~ : () -> Int64,
  prepare~ : (@skills.Supervisor, () -> Int64) -> @runner.Runner raise,
  period_ms~ : Int32 = 20,
) -> Self raise {
  guard period_ms > 0 else {
    fail("actor host requires a positive control period")
  }
  {
    runner: prepare(supervisor, clock),
    service: @task.Service::new(supervisor, clock),
    clock,
    period_ms,
    serving: false,
  }
}

///|
/// Borrow a listening server. Cancellation/error interrupts only the runner's
/// owned execution and invokes its stop callback; the caller closes the server
/// and retains devices until this function and cleanup have returned.
pub async fn Host::serve(self : Self, server : @http.Server) -> Unit {
  guard !self.serving else { fail("actor host is already serving") }
  self.serving = true
  defer {
    self.serving = false
  }
  defer self.runner.interrupt(detail="local actor task host stopped")
  let cadence = Cadence::new((self.clock)(), self.period_ms)
  @async.with_task_group(group => {
    group.spawn_bg(no_wait=true, () => self.service.serve(server))
    for ;; {
      ignore(self.runner.tick())
      @async.sleep(cadence.delay((self.clock)()))
    }
  })
}
