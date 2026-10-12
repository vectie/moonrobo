///|
fn r8_clear(path : String) -> Unit raise {
  if !@fsx.path_exists(path) {
    return
  }
  if @fsx.is_dir(path) {
    for name in @fsx.read_dir(path) {
      r8_clear(path + "/" + name)
    }
    @fsx.remove_dir(path)
  } else {
    @fsx.remove_file(path)
  }
}

///|
test "R8 host routes save reopen build export with actual producer design" {
  let root = "/tmp/moonrobo-r8-host-routes"
  r8_clear(root)
  @fsx.create_dir(root)
  @fsx.write_string_to_file(
    root + "/robot.json",
    "selected physical RoboBook remains untouched",
  )
  let view = @json.parse(
    @fsx.read_file_to_string("fixtures/design-workbench-built-view.json"),
  )
  guard view is { "draft": { "design_text": String(text), .. }, .. } else {
    fail("actual producer fixture")
  }
  let design = @json.parse(text)
  let save : Json = { "design": design, "recorded_at": "2026-10-06T16:00:00Z" }
  let response = @host_api.route_with_body(
    root,
    "POST",
    "/api/moonrobo/design-workbench/save",
    save.stringify(),
  )
  assert_eq(response.status, 200, msg=response.body)
  guard @json.parse(response.body)
    is {
      "draft": { "design_digest": String(digest), .. },
      "state": String("draft"),
      ..
    } else {
    fail("saved draft")
  }
  let request : Json = {
    "design_id": "excavation-haul",
    "revision": "r1",
    "expected_digest": digest,
  }
  let built = @host_api.route_with_body(
    root,
    "POST",
    "/api/moonrobo/design-workbench/build",
    request.stringify(),
  )
  assert_eq(built.status, 200, msg=built.body)
  assert_true(@json.parse(built.body) is { "state": String("built"), .. })
  let reopened = @host_api.route_with_body(
    root,
    "POST",
    "/api/moonrobo/design-workbench/open",
    request.stringify(),
  )
  assert_eq(reopened.body, built.body)
  let exported = @host_api.route_with_body(
    root,
    "POST",
    "/api/moonrobo/design-workbench/export",
    request.stringify(),
  )
  assert_eq(exported.status, 200, msg=exported.body)
  assert_eq(
    @json.parse(exported.body),
    @json.parse(
      @fsx.read_file_to_string(
        "fixtures/design-workbench-simulation-input.json",
      ),
    ),
  )
  assert_eq(
    @fsx.read_file_to_string(root + "/robot.json"),
    "selected physical RoboBook remains untouched",
  )
  assert_false(
    @fsx.path_exists(root + "/.moonsuite/products/moonrobo/gateway-commands"),
  )
  assert_false(@fsx.path_exists(root + "/bridge"))
  let repeated = @host_api.route_with_body(
    root,
    "POST",
    "/api/moonrobo/design-workbench/build",
    request.stringify(),
  )
  assert_eq(repeated.body, built.body)
}

///|
test "R8 host invalid unsafe and stale requests fail without dispatch" {
  let root = "/tmp/moonrobo-r8-host-invalid"
  r8_clear(root)
  @fsx.create_dir(root)
  assert_eq(
    @host_api.route_with_body(
      root, "POST", "/api/moonrobo/design-workbench/save", "{",
    ).status,
    400,
  )
  for operation in ["open", "build", "export", "execute", "dispatch"] {
    let body : Json = {
      "design_id": "../escape",
      "revision": "r1",
      "expected_digest": "stale",
    }
    assert_eq(
      @host_api.route_with_body(
        root,
        "POST",
        "/api/moonrobo/design-workbench/" + operation,
        body.stringify(),
      ).status,
      409,
    )
  }
  assert_false(@fsx.path_exists(root + "/.moonsuite"))
}
