///|
test "R20 host catalogue reads actual saved draft and remains inert" {
  let root = "/tmp/moonrobo-r20-host-library"
  r8_clear(root)
  @fsx.create_dir(root)
  let empty = @host_api.route_with_body(
    root, "POST", "/api/moonrobo/design-workbench/catalogue", "{}",
  )
  assert_eq(empty.status, 200)
  assert_true(
    @json.parse(empty.body)
    is { "entries": Array([]), "physical_execution_allowed": False, .. },
  )
  assert_false(@fsx.path_exists(root + "/.moonsuite"))
  guard @json.parse(
      @fsx.read_file_to_string("fixtures/design-workbench-built-view.json"),
    )
    is { "draft": { "design_text": String(text), .. }, .. } else {
    fail("fixture")
  }
  let body : Json = {
    "design": @json.parse(text),
    "recorded_at": "2026-10-07T04:00:00Z",
  }
  assert_eq(
    @host_api.route_with_body(
      root,
      "POST",
      "/api/moonrobo/design-workbench/save",
      body.stringify(),
    ).status,
    200,
  )
  let response = @host_api.route_with_body(
    root, "POST", "/api/moonrobo/design-workbench/catalogue", "{}",
  )
  assert_eq(response.status, 200)
  assert_true(
    @json.parse(response.body)
    is {
      "entries": Array(
        [
          {
            "design_id": String("excavation-haul"),
            "revision": String("r1"),
            "state": String("draft"),
            "selectable": True,
            ..
          },
        ]
      ),
      ..
    },
  )
  assert_false(
    @fsx.path_exists(root + "/.moonsuite/products/moonrobo/gateway-commands"),
  )
  assert_false(@fsx.path_exists(root + "/bridge"))
}
