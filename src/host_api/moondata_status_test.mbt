///|
test "MoonData status is a stable read-only projection before initialization" {
  let root = "/tmp/moonrobo-moondata-status-missing-root"
  let status = @host_api.moondata_cockpit_status(root).unwrap()
  assert_eq(status.initialized, false)
  assert_eq(status.status, "not-initialized")
  assert_eq(status.artifact_count, 0)
  assert_eq(status.root, root + "/moondata")
  let response = @host_api.route(root, "GET", @host_api.moondata_status_path())
  assert_eq(response.status, 200)
  assert_true(response.body.contains("\"initialized\": false"))
  assert_true(response.body.contains("\"status\": \"not-initialized\""))
  assert_true(response.body.contains("\"artifacts\": []"))
}
