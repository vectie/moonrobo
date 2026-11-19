///|
async test "task host composes a prepared reference sensor numerical actor and complete mapped frames" {
  let (actor, mapping) = fixture()
  defer (actor.close() catch { _ => () })
  let frame : Json = {
    "goals": Json(Array::make(73, 0.0)),
    "body_to_world": [1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0],
  }
  let clip = @reference.Clip::parse(actor.bundle(), {
    "format": "moonrobo.e1-actor-reference.v1",
    "profile_id": actor.bundle().profile_id(),
    "joints": Json(actor.bundle().joints()),
    "reference_id": "frames",
    "control_dt_ms": 20,
    "goal_layout": "aligned.preview73.v1",
    "frames": Json([frame, frame, frame]),
  })
  let supervisor = @skills.Supervisor::new("host-control", [
    {
      id: "one",
      description: "synthetic only",
      reference_id: clip.reference_id(),
      maximum_duration_ms: 1000,
      parameters: [],
    },
  ])
  let clock = () => @env.now().reinterpret_as_int64()
  let previous_values : Array[Double] = []
  let writes = Ref(0)
  let stops = Ref(0)
  let host = @host.Host::new(supervisor, clock~, prepare=(owner, clock) => {
    let sensor = @e1_actor_control.Sensor::new(
      profile_id=actor.bundle().profile_id(),
      clock~,
      capture=(previous, _) => {
        previous_values.push(previous[0])
        let observation = Array::make(99, 0.0)
        for i in 0..<29 {
          observation[64 + i] = previous[i]
        }
        { observation, receipt_age_ms: 0L, }
      },
    )
    @e1_actor_control.new_runner(
      owner,
      actor,
      mapping,
      sensor,
      reference=(execution, step, _) => {
        let value = clip.frame(execution, step)
        {
          goals: value.goals,
          body_to_world: value.body_to_world,
          complete: value.complete,
        }
      },
      publish=commands => {
        assert_eq(commands.length(), 24)
        assert_eq(commands[0].position, 1.0)
        assert_eq(commands[23].position, 0.75)
        writes.val += 1
      },
      stop=() => stops.val += 1,
    )
  })
  @async.with_timeout(5000, () => {
    @async.with_task_group(group => {
      let server = @http.Server(@socket.Addr::parse("127.0.0.1:0"))
      defer server.close()
      let endpoint = "http://127.0.0.1:\{server.addr.port()}"
      let running = group.spawn(allow_failure=true, () => host.serve(server))
      let advertisement = for ;; {
        let value = Some(@task.fetch_catalog(endpoint)) catch {
          error => {
            if @async.is_cancellation_error(error) {
              raise error
            }
            None
          }
        }
        if value is Some(advertisement) {
          break advertisement
        }
        guard running.try_wait() is None else {
          fail("control host exited before readiness")
        }
        @async.sleep(5)
      }
      ignore(
        @task.submit(
          endpoint,
          @task.request(
            advertisement,
            { skill_id: "one", parameters: Map([]), },
            request_id="composed-host",
            ttl_ms=1000,
          ),
        ),
      )
      for ;; {
        guard supervisor.snapshot(clock()) is Some(execution) else {
          fail("accepted control task missing")
        }
        if execution.state is Completed {
          break
        }
        assert_true(execution.state is Accepted || execution.state is Running)
        guard running.try_wait() is None else {
          fail("control host exited during execution")
        }
        @async.sleep(5)
      }
      assert_eq((writes.val, stops.val), (2, 1))
      assert_eq(previous_values, [0.0, 1.0, 1.0])
      running.cancel()
      running.wait() catch {
        error => if !@async.is_cancellation_error(error) { raise error }
      }
      assert_eq(stops.val, 1)
    })
  })
}
