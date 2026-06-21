///|
test "host api emits cockpit snapshot response" {
  let response = @host_api.snapshot_response("examples/noetix-e1")
  assert_eq(response.status, 200)
  assert_eq(response.content_type, "application/json")
  assert_true(response.body.contains("\"robot_id\": \"noetix-e1-lab-01\""))
  assert_true(response.body.contains("\"decision\": \"dry-run-required\""))
}

///|
test "host api routes health and missing paths" {
  let health = @host_api.route(
    "examples/noetix-e1",
    "GET",
    @host_api.health_path(),
  )
  assert_eq(health.status, 200)
  assert_true(
    health.body.contains("\"snapshot_path\": \"/api/cockpit/snapshot\""),
  )
  let missing = @host_api.route("examples/noetix-e1", "GET", "/missing")
  assert_eq(missing.status, 404)
  assert_true(missing.body.contains("\"code\": \"not-found\""))
}

///|
test "host api rejects non-get methods" {
  let response = @host_api.route(
    "examples/noetix-e1",
    "POST",
    @host_api.snapshot_path(),
  )
  assert_eq(response.status, 405)
  assert_true(response.body.contains("\"code\": \"method-not-allowed\""))
}
