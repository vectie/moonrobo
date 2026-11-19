///|
async test "encoded observations carry format and view identity without a model dependency" {
  let png = @fs.read_file("src/policy_planner/fixtures/rgb.png").binary()
  let jpeg = @fs.read_file("src/policy_planner/fixtures/baseline.jpg").binary()
  let front = @policy_planner.ImageObservation::from_encoded(
    png,
    source=" front ",
  )
  let hand = @policy_planner.ImageObservation::from_encoded(jpeg, source="hand")
  assert_eq(front.encoding(), @policy_planner.ImageEncoding::Png)
  assert_eq(front.source(), "front")
  assert_eq(front.byte_count(), png.length())
  assert_eq(hand.encoding(), @policy_planner.ImageEncoding::Jpeg)
  assert_true(
    try
      @policy_planner.ImageObservation::from_encoded(
        b"not an image",
        source="camera",
      )
    catch {
      _ => true
    } noraise {
      _ => false
    },
  )
  assert_true(
    try @policy_planner.ImageObservation::from_encoded(png, source=" ") catch {
      _ => true
    } noraise {
      _ => false
    },
  )
}

///|
async test "visual planner sends ordered inline bytes and preserves context and execution TTL rules" {
  let png = @fs.read_file("src/policy_planner/fixtures/rgb.png").binary()
  let jpeg = @fs.read_file("src/policy_planner/fixtures/baseline.jpg").binary()
  let images : ReadOnlyArray[@policy_planner.ImageObservation] = [
    @policy_planner.ImageObservation::from_encoded(png, source="front camera"),
    @policy_planner.ImageObservation::from_encoded(jpeg, source="hand camera"),
  ]
  let supervisor = @skills.Supervisor::new("visual-test", [
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
  let calls = Ref(0)
  @async.with_timeout(5000, () => {
    @async.with_task_group(group => {
      let tasks = @http.Server(@socket.Addr::parse("127.0.0.1:0"))
      let llm = @http.Server(@socket.Addr::parse("127.0.0.1:0"))
      defer tasks.close()
      defer llm.close()
      group.spawn_bg(no_wait=true, () => service.serve(tasks))
      group.spawn_bg(no_wait=true, () => {
        llm.run_forever((request, body, conn) => {
          let bytes = body.read_all().binary()
          assert_eq(request.path, "/v1/chat/completions")
          assert_eq(
            request.headers.get("content-length"),
            Some(bytes.length().to_string()),
          )
          assert_eq(
            request.headers.get("content-type"),
            Some("application/json"),
          )
          assert_eq(request.headers.get("transfer-encoding"), None)
          assert_eq(
            request.headers.get("authorization"),
            Some("Bearer fixture"),
          )
          let payload = @json.parse(@utf8.decode(bytes))
          guard payload
            is {
              "model": "MiniCPM-V-4.7-35B-A3B",
              "temperature": 0,
              "stream": False,
              "messages": [
                { "role": "system", "content": String(policy), .. },
                { "role": "user", "content": Array(parts), .. },
              ],
              ..
            } else {
            fail("invalid visual planner request")
          }
          assert_true(policy.contains("skill_id"))
          assert_eq(parts.length(), 5)
          assert_true(
            parts[0]
            is { "type": "text", "text": "根据图像选择技能。", .. },
          )
          for index in 0..<2 {
            let source = if index == 0 { "front camera" } else { "hand camera" }
            assert_true(
              parts[1 + index * 2]
              is { "type": "text", "text": String(label), .. } &&
              label.contains(source),
            )
            guard parts[2 + index * 2]
              is {
                "type": "image_url",
                "image_url": { "url": String(uri), "detail": "high", .. },
                ..
              } else {
              fail("missing inline image")
            }
            let prefix = if index == 0 {
              "data:image/png;base64,"
            } else {
              "data:image/jpeg;base64,"
            }
            guard uri.strip_prefix(prefix) is Some(encoded) else {
              fail("wrong image MIME")
            }
            assert_eq(
              @base64.decode(encoded),
              if index == 0 {
                png
              } else {
                jpeg
              },
            )
          }
          calls.val += 1
          time.val += 100L
          if calls.val == 2 {
            ignore(
              supervisor.cancel("visual-one", detail="operator changed context"),
            )
          }
          conn.send_response(200, "OK")
          conn.write_string(
            (
              {
                "choices": [
                  {
                    "finish_reason": "stop",
                    "message": {
                      "content": "{\"skill_id\":\"one\",\"parameters\":{}}",
                    },
                  },
                ],
              } : Json).stringify(),
          )
          conn.end_response()
        })
      })
      let task_url = "http://127.0.0.1:\{tasks.addr.port()}"
      let llm_url = "http://127.0.0.1:\{llm.addr.port()}"
      let headers : Map[String, String] = {
        "Authorization": "Bearer fixture",
        "CONTENT-LENGTH": "1",
        "Transfer-Encoding": "chunked",
      }
      let accepted = @policy_planner.plan_and_submit(
        task_url,
        llm_url,
        "MiniCPM-V-4.7-35B-A3B",
        "  根据图像选择技能。\n",
        request_id="visual-one",
        ttl_ms=200,
        images~,
        headers~,
      )
      assert_eq(accepted.reference_id, "clip")
      assert_eq(accepted.accepted_at_ms, 200L)
      assert_eq(accepted.deadline_ms, 400L)
      assert_eq(headers.get("CONTENT-LENGTH"), Some("1"))
      assert_eq(headers.get("Transfer-Encoding"), Some("chunked"))
      assert_true(
        try
          @policy_planner.plan_and_submit(
            task_url,
            llm_url,
            "MiniCPM-V-4.7-35B-A3B",
            "根据图像选择技能。",
            request_id="visual-two",
            ttl_ms=200,
            images~,
            headers~,
          )
        catch {
          _ => true
        } noraise {
          _ => false
        },
      )
      assert_true(
        supervisor.snapshot(time.val)
        is Some({ request_id: "visual-one", state: Interrupted, .. }),
      )
      assert_eq(calls.val, 2)
    })
  })
}

///|
async test "image planning still rejects truncated model output before a proposal can be submitted" {
  let image = @policy_planner.ImageObservation::from_encoded(
    @fs.read_file("src/policy_planner/fixtures/rgb.png").binary(),
    source="front",
  )
  let advertisement : @task.Advertisement = {
    now_ms: 100L,
    catalog: {
      catalog_id: "test",
      context_version: 1L,
      last_sequence: 0L,
      skills: [],
    },
  }
  @async.with_timeout(3000, () => {
    @async.with_task_group(group => {
      let llm = @http.Server(@socket.Addr::parse("127.0.0.1:0"))
      defer llm.close()
      group.spawn_bg(no_wait=true, () => {
        llm.run_forever((_, body, conn) => {
          ignore(body.read_all())
          conn.send_response(200, "OK")
          conn.write_string(
            (
              {
                "choices": [
                  {
                    "finish_reason": "length",
                    "message": {
                      "content": "{\"skill_id\":\"one\",\"parameters\":{}}",
                    },
                  },
                ],
              } : Json).stringify(),
          )
          conn.end_response()
        })
      })
      assert_true(
        try
          @policy_planner.propose(
            "http://127.0.0.1:\{llm.addr.port()}",
            "MiniCPM-V-4.7-35B-A3B",
            advertisement,
            "look",
            images=[image],
          )
        catch {
          _ => true
        } noraise {
          _ => false
        },
      )
    })
  })
}
