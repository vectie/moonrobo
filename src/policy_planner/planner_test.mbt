///|
async test "recorded LLM response crosses HTTP and becomes a bounded reference" {
  let supervisor = @skills.Supervisor::new("test", [
    {
      id: "one",
      description: "fixture",
      reference_id: "clip",
      maximum_duration_ms: 200,
      parameters: [],
    },
  ])
  let time = Ref(100L)
  let service = @task.Service::new(supervisor, () => time.val)
  let changes_context = Ref(false)
  @async.with_timeout(5000, () => {
    @async.with_task_group(group => {
      let tasks = @http.Server(@socket.Addr::parse("127.0.0.1:0"))
      let llm = @http.Server(@socket.Addr::parse("127.0.0.1:0"))
      defer tasks.close()
      defer llm.close()
      group.spawn_bg(no_wait=true, () => service.serve(tasks))
      group.spawn_bg(no_wait=true, () => {
        llm.run_forever((request, body, conn) => {
          assert_eq(request.path, "/v1/chat/completions")
          let bytes = body.read_all().binary()
          assert_eq(
            request.headers.get("content-type"),
            Some("application/json"),
          )
          assert_eq(
            request.headers.get("content-length"),
            Some(bytes.length().to_string()),
          )
          assert_eq(request.headers.get("transfer-encoding"), None)
          let payload = @json.parse(@utf8.decode(bytes))
          assert_true(
            payload
            is { "model": String("MiniCPM-V-4.7-35B-A3B"), "stream": False, .. },
          )
          if !changes_context.val {
            assert_eq(
              request.headers.get("authorization"),
              Some("Bearer fixture"),
            )
            assert_true(
              payload
              is {
                "messages": Array(
                  [_, { "content": String("run the fixture"), .. }]
                ),
                ..
              },
            )
          }
          time.val += 100L
          if changes_context.val {
            ignore(
              supervisor.cancel(
                "planned-one",
                detail="operator changed context",
              ),
            )
          }
          conn.send_response(200, "OK")
          let reply : Json = {
            "choices": [
              {
                "finish_reason": "stop",
                "message": {
                  "content": "{\"skill_id\":\"one\",\"parameters\":{}}",
                },
              },
            ],
          }
          conn.write_string(reply.stringify())
          conn.end_response()
        })
      })
      let task_url = "http://127.0.0.1:\{tasks.addr.port()}"
      let llm_url = "http://127.0.0.1:\{llm.addr.port()}"
      let accepted = @policy_planner.plan_and_submit(
        task_url,
        llm_url,
        "MiniCPM-V-4.7-35B-A3B",
        "  run the fixture\n",
        request_id="planned-one",
        ttl_ms=200,
        headers={
          "authorization": "Bearer fixture",
          "CONTENT-LENGTH": "1",
          "Transfer-Encoding": "chunked",
        },
      )
      assert_eq(accepted.reference_id, "clip")
      assert_eq(accepted.accepted_at_ms, 200L)
      assert_eq(accepted.deadline_ms, 400L)
      changes_context.val = true
      assert_true(
        try
          @policy_planner.plan_and_submit(
            task_url,
            llm_url,
            "MiniCPM-V-4.7-35B-A3B",
            "another task",
            request_id="planned-two",
            ttl_ms=200,
          )
        catch {
          _ => true
        } noraise {
          _ => false
        },
      )
      assert_true(
        supervisor.snapshot(time.val)
        is Some({ request_id: "planned-one", state: Interrupted, .. }),
      )
    })
  })
}

///|
test "planner output cannot smuggle coordinator metadata or joint commands" {
  assert_true(
    try
      @task.parse_proposal(
        "{\"skill_id\":\"one\",\"parameters\":{},\"sequence\":42}",
      )
    catch {
      _ => true
    } noraise {
      _ => false
    },
  )
  assert_true(
    try
      @task.parse_proposal(
        "```json\n{\"skill_id\":\"one\",\"parameters\":{}}\n```",
      )
    catch {
      _ => true
    } noraise {
      _ => false
    },
  )
}
