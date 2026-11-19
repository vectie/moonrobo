///|
async test "SDK shadow file preparation rejects incompatible sessions before a controller is opened" {
  let actor = fixture_actor()
  defer (actor.close() catch { _ => () })
  let directory = @fs.tmpdir(prefix="sdk-shadow-plan")
  defer @fs.rmdir(directory, recursive=true)
  let reference = write_reference(directory, actor.bundle())
  let path = directory + "/session.json"
  @fs.write_file(path, session(reference).stringify(), create_mode=CreateNew)
  ignore(@e1_actor_sdk_shadow.Plan::read(actor, path))
  for
    pair in [
      ("format", Json("other")),
      ("maximum_sensor_age_ms", Json("-1")),
      ("references", @json.parse("[]")),
      ("references", Json([reference, reference])),
    ] {
    let (field, replacement) = pair
    guard session(reference) is Object(fields) else { fail("invalid fixture") }
    fields[field] = replacement
    @fs.write_file(path, Json(fields).stringify(), create_mode=TruncateExisting)
    try @e1_actor_sdk_shadow.Plan::read(actor, path) catch {
      _ => ()
    } noraise {
      _ => fail("invalid SDK shadow session accepted: " + field)
    }
  }
}

///|
suberror RecordFailure {
  Original
}

///|
async test "SDK shadow task path records full frames and never publishes even on recording failure" {
  guard @env.get_env_var("MOONROBO_E1_LOW_FIXTURE") is Some(library) else {
    println(
      "SKIP SDK shadow ABI: set MOONROBO_E1_LOW_FIXTURE to the actual-header fake SDK",
    )
    return
  }
  let actor = fixture_actor()
  defer (actor.close() catch { _ => () })
  let directory = @fs.tmpdir(prefix="sdk-shadow-http")
  defer @fs.rmdir(directory, recursive=true)
  let reference = write_reference(directory, actor.bundle())
  let path = directory + "/session.json"
  @fs.write_file(path, session(reference).stringify(), create_mode=CreateNew)
  let controller = @low.Controller::open(library)
  let original_publications = controller.joint_index("fixture_publish_count")
  let clock = () => @env.now().reinterpret_as_int64()
  for fail_record in [false, true] {
    ignore(controller.joint_index("fixture_policy_clean"))
    let plan = @e1_actor_sdk_shadow.Plan::read(actor, path)
    let rows : Array[Json] = []
    let stops = Ref(0)
    let host = plan.host(
      controller,
      clock~,
      record=value => {
        if fail_record {
          raise RecordFailure::Original
        }
        rows.push(value)
      },
      stopped=() => stops.val += 1,
    )
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
            fail("SDK shadow host exited before readiness")
          }
          @async.sleep(5)
        }
        ignore(
          @task.submit(
            endpoint,
            @task.request(
              advertisement,
              { skill_id: "one", parameters: Map([]), },
              request_id="read-only-task",
              ttl_ms=1000,
            ),
          ),
        )
        if fail_record {
          try running.wait() catch {
            error => assert_true(error is RecordFailure::Original)
          } noraise {
            _ => fail("record failure was swallowed")
          }
          assert_true(rows.is_empty())
        } else {
          for ;; {
            let (response, body) = @http.get(endpoint + "/v1/state")
            guard response.code == 200 &&
              body.json() is { "execution": value, .. } else {
              fail("SDK shadow state unavailable")
            }
            let execution : @skills.Execution = @json.from_json(value)
            if execution.state is Completed {
              break
            }
            assert_true(
              execution.state is Accepted || execution.state is Running,
            )
            guard running.try_wait() is None else {
              fail("SDK shadow host exited during task")
            }
            @async.sleep(5)
          }
          running.cancel()
          running.wait() catch {
            error => if !@async.is_cancellation_error(error) { raise error }
          }
          assert_eq(rows.length(), 2)
          for value in rows {
            guard value
              is {
                "format": "moonrobo.e1-sdk-shadow-tick.v1",
                "published": False,
                "hardware_qualified": False,
                "commands": Array(commands),
                ..
              } &&
              commands.length() == 24 else {
              fail("invalid SDK shadow record")
            }
            assert_true(
              commands[0]
              is {
                "slot": 0,
                "position": 100.0,
                "velocity": 10.0,
                "torque": 20.0,
                "kp": 30.0,
                "kd": 40.0,
                ..
              },
            )
            for slot in 1..<24 {
              let index = 23 - slot
              guard commands[slot]
                is {
                  "position": Number(position, ..),
                  "kp": Number(kp, ..),
                  "kd": Number(kd, ..),
                  "velocity": 0.0,
                  "torque": 0.0,
                  ..
                } else {
                fail("invalid mapped SDK command")
              }
              assert_eq(
                position,
                0.25 +
                (if index % 2 == 0 { -1.0 } else { 1.0 }) *
                (index + 1).to_double(),
              )
              assert_eq(
                (kp, kd),
                ((10 + index).to_double(), (1 + index).to_double()),
              )
            }
          }
        }
        assert_eq(stops.val, 1)
        assert_eq(
          controller.joint_index("fixture_publish_count"),
          original_publications,
        )
      })
    })
  }
}
