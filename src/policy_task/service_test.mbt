///|
async test "task HTTP lifecycle keeps runner status local and rejects replay" {
  let supervisor = @skills.Supervisor::new("catalog-one", [
    {
      id: "motion-one",
      description: "recorded fixture",
      reference_id: "clip-one",
      maximum_duration_ms: 1000,
      parameters: [],
    },
  ])
  let now = Ref(100L)
  let service = @policy_task.Service::new(supervisor, () => now.val)
  @async.with_timeout(5000, () => {
    @async.with_task_group(group => {
      let server = @http.Server(@socket.Addr::parse("127.0.0.1:0"))
      defer server.close()
      group.spawn_bg(no_wait=true, () => service.serve(server))
      let client = @http.Client("http://127.0.0.1:\{server.addr.port()}")
      defer client.close()
      assert_eq(client.get("/v1/catalog").code, 200)
      let catalog = client.read_all().json()
      assert_true(
        catalog
        is {
          "now_ms": String("100"),
          "catalog": { "catalog_id": String("catalog-one"), .. },
          ..
        },
      )
      let request : @skills.Request = {
        request_id: "one",
        sequence: 1L,
        catalog_id: "catalog-one",
        context_version: 0L,
        expires_at_ms: 1100L,
        proposal: { skill_id: "motion-one", parameters: Map([]), },
      }
      assert_eq(client.post("/v1/skills", Json(request)).code, 200)
      let accepted : @skills.Execution = @json.from_json(
        client.read_all().json(),
      )
      assert_true(accepted.state is Accepted)
      assert_true(supervisor.start("one", 101L).state is Running)
      assert_eq(client.post("/v1/skills", Json(request)).code, 200)
      let repeated : @skills.Execution = @json.from_json(
        client.read_all().json(),
      )
      assert_true(repeated.state is Running)
      // No task connection is needed for expiry or a local actor tick.
      now.val = 1101L
      assert_true(
        supervisor.snapshot(now.val) is Some({ state: Interrupted, .. }),
      )
      assert_eq(client.post("/v1/skills", Json(request)).code, 200)
      let terminal : @skills.Execution = @json.from_json(
        client.read_all().json(),
      )
      assert_true(terminal.state is Interrupted)
      assert_eq(client.post("/v1/skills", Json({ "broken": true })).code, 400)
      ignore(client.read_all())
      assert_eq(
        client.post("/v1/start", Json({ "request_id": "one" })).code,
        404,
      )
      ignore(client.read_all())
    })
  })
}
