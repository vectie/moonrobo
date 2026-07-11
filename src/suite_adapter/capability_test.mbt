///|
test "MoonRobo adapter cannot claim physical readiness" {
  guard @suite_adapter.moonflow_adapter_capability_json() is Object(capability) else {
    fail("expected MoonRobo adapter capability")
  }
  assert_true(capability["protocol"] == Json::string("moonflow.adapter.v1"))
  assert_true(capability["product_id"] == Json::string("moonrobo"))
  assert_true(capability["supports_cancel"] == Json::boolean(false))
  assert_true(capability["supports_reconcile"] == Json::boolean(true))
  assert_true(
    capability["readiness_ceiling"] == Json::string("simulation_ready"),
  )
  assert_true(capability["physical_ready_forbidden"] == Json::boolean(true))
  guard capability["authority_classes"] is Array(authorities) else {
    fail("expected MoonRobo authorities")
  }
  assert_true(authorities.contains(Json::string("sandbox-execution")))
  assert_false(authorities.contains(Json::string("external-effect")))
  assert_false(authorities.contains(Json::string("physical-effect")))
}
