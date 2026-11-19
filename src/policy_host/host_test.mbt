///|
async fn partial_body(address : @socket.Addr) -> @socket.Tcp {
  let stream = @socket.Tcp::connect(address)
  let writer : &@io.Writer = stream
  writer.write(
    "POST /v1/skills HTTP/1.1\r\nHost: localhost\r\nContent-Length: 100\r\nContent-Type: application/json\r\n\r\n{",
  )
  stream
}

///|
async fn state(url : String) -> @skills.Execution {
  let (response, body) = @http.get(url + "/v1/state")
  guard response.code == 200 && body.json() is { "execution": value, .. } else {
    fail("actor host state unavailable")
  }
  @json.from_json(value)
}

///|
async test "task host completes without a client and keeps ticking through an incomplete HTTP body" {
  let supervisor = @skills.Supervisor::new("host-fixture", [
    {
      id: "short",
      description: "software",
      reference_id: "frames",
      maximum_duration_ms: 1000,
      parameters: [],
    },
    {
      id: "hold",
      description: "software",
      reference_id: "frames",
      maximum_duration_ms: 1000,
      parameters: [],
    },
  ])
  let clock = () => @env.now().reinterpret_as_int64()
  let started = clock()
  let writes = Ref(0)
  let stops = Ref(0)
  let host = @policy_host.Host::new(supervisor, clock~, prepare=(owner, clock) => {
    @runner.Runner::new(
      owner,
      clock~,
      history_frames=1,
      observation_width=1,
      goal_width=1,
      action_width=1,
      reference=(execution, step, _, time) => {
        observation: [0.0],
        goals: [0.0],
        captured_at_ms: time,
        complete: execution.skill_id == "short" && step == 3,
      },
      predict=(_, _) => [0.5],
      sink=_ => writes.val += 1,
      stop=() => stops.val += 1,
    )
  })
  @async.with_timeout(5000, () => {
    @async.with_task_group(group => {
      let server = @http.Server(@socket.Addr::parse("127.0.0.1:0"))
      defer server.close()
      let endpoint = "http://127.0.0.1:\{server.addr.port()}"
      let running = group.spawn(allow_failure=true, () => host.serve(server))
      let advertised = for ;; {
        let advertisement = Some(@task.fetch_catalog(endpoint)) catch {
          error => {
            if @async.is_cancellation_error(error) {
              raise error
            }
            None
          }
        }
        if advertisement is Some(value) {
          break value
        }
        guard running.try_wait() is None else {
          fail("actor host exited before readiness")
        }
        @async.sleep(5)
      }
      assert_true(advertised.now_ms >= started && advertised.now_ms <= clock())
      let request = @task.request(
        advertised,
        { skill_id: "short", parameters: Map([]), },
        request_id="short-one",
        ttl_ms=1000,
      )
      ignore(@task.submit(endpoint, request))
      // submit's connection has ended; no planner/client is needed for ticks.
      for ;; {
        let execution = state(endpoint)
        if execution.state is Completed {
          break
        }
        assert_true(execution.state is Accepted || execution.state is Running)
        @async.sleep(5)
      }
      assert_eq((writes.val, stops.val), (3, 1))
      let request = @task.request(
        @task.fetch_catalog(endpoint),
        { skill_id: "hold", parameters: Map([]), },
        request_id="hold-one",
        ttl_ms=1000,
      )
      ignore(@task.submit(endpoint, request))
      let stalled = partial_body(server.addr)
      defer stalled.close()
      for ;; {
        if writes.val >= 5 {
          break
        }
        @async.sleep(5)
      }
      assert_true(state(endpoint).state is Running)
      running.cancel()
      running.wait() catch {
        error => if !@async.is_cancellation_error(error) { raise error }
      }
      assert_eq(stops.val, 2)
      assert_true(
        supervisor.snapshot(clock())
        is Some({ request_id: "hold-one", state: Interrupted, .. }),
      )
    })
  })
}

///|
suberror InferenceFailure {
  Original
}

///|
async test "task host preserves inference errors and stops the owned execution once" {
  let supervisor = @skills.Supervisor::new("failure-fixture", [
    {
      id: "one",
      description: "software",
      reference_id: "frames",
      maximum_duration_ms: 1000,
      parameters: [],
    },
  ])
  ignore(
    supervisor.accept(
      {
        request_id: "one",
        sequence: 0L,
        catalog_id: "failure-fixture",
        context_version: 0L,
        expires_at_ms: 1100L,
        proposal: { skill_id: "one", parameters: Map([]), },
      },
      100L,
    ),
  )
  let stops = Ref(0)
  let host = @policy_host.Host::new(supervisor, clock=() => 100L, prepare=(
    owner,
    clock,
  ) => {
    @runner.Runner::new(
      owner,
      clock~,
      history_frames=1,
      observation_width=1,
      goal_width=1,
      action_width=1,
      reference=(_, _, _, now) => {
        observation: [0.0],
        goals: [0.0],
        captured_at_ms: now,
        complete: false,
      },
      predict=(_, _) => raise InferenceFailure::Original,
      sink=_ => fail("failed inference reached publication"),
      stop=() => stops.val += 1,
    )
  })
  let server = @http.Server(@socket.Addr::parse("127.0.0.1:0"))
  defer server.close()
  try host.serve(server) catch {
    error => assert_true(error is InferenceFailure::Original)
  } noraise {
    _ => fail("actor host swallowed inference failure")
  }
  assert_eq(stops.val, 1)
  assert_true(supervisor.snapshot(100L) is Some({ state: Failed, .. }))
}
