# Local actor task host

This package owns the existing task HTTP service and one synchronous actor tick
loop. Shadow replay and calibrated E1 composition share this host. It imports no
robot SDK, model runtime, trainer, simulator or LLM. The caller prepares a runner
with explicit reference, inference, publication and stop callbacks.

`Host::new(supervisor,clock~,prepare~,period_ms=20)` passes its supervisor and
clock to the preparation callback. Use those same values in the runner and its
sensor adapter. The clock must advance in host milliseconds, remain nonnegative
and nondecreasing, and share the task acceptance/deadline time domain. No host
clock or device backend is selected implicitly. Construction runs preparation
once; it does not start HTTP or ticks.

```mbt check
///|
async fn _serve(host : @policy_host.Host, bind : String) -> Unit {
  let server = @http.Server(@socket.Addr::parse(bind))
  defer server.close()
  host.serve(server)
}
```

`serve(server)` borrows a listening server and runs the existing `/v1/catalog`,
`/v1/state`, `/v1/skills` and `/v1/cancel` protocol. Clients wait for catalog
readiness before submission. No start/finish or joint-command endpoint is added.
Networking and a slow/incomplete request body do not enter the synchronous tick.
Accepted work continues locally after the submitting connection ends.

The default control period is20ms. Normal ticks retain their scheduled slots.
If synchronous work reaches or overruns the next slot, missed slots are discarded
and the host waits a full period after that work. It does not replay a catch-up
burst. This favors bounded local sequencing over attempting to recover lost
reference time; the supervisor's real deadline still expires normally.

On cooperative cancellation or error, the host calls `Runner::interrupt` for
its owned execution and invokes the runner's explicit stop callback once. A
replacement request remains untouched. Original inference/reference/publication
errors propagate; the host does not select another backend or resume by itself.
The caller retains the actor, sensor/controller and reference until `serve`
and cleanup return, then closes resources. Serving the same host concurrently
is rejected. A later serving attempt needs a fresh listening server.

This is one cooperative event loop, not a real-time or independent watchdog
thread. A synchronous vendor call blocks that loop until it returns. Cleanup
cannot interrupt it or guarantee a stop after process termination/power loss.
The host supplies software stop notification, not a physical stop command or
device close. The E1 owner still qualifies authority, limits, stop/takeover,
watchdog, cadence, jitter and NPU timing on the target.

Deterministic cadence tests cover normal slots, exact-boundary/long overruns
and invalid clocks/periods. HTTP tests complete a task after its submitter
disconnects, keep ticking through an incomplete request body, expose state and
interrupt a running task on host cancellation. An inference-error test preserves
the original error and one stop callback. The E1 composition test adds prepared
references, synthetic sensor features, numerical actor execution and complete
mapped24-slot frames through this same HTTP host. No physical sink is enabled.
