///|
test "APIC producer retains historical capacity unless explicitly selected" {
  let base : ExportConfig = {
    adapter: "",
    python: "",
    site_packages: "",
    isaaclab_root: "",
    newton_root: "",
    usd: "",
    usd_variants: {},
    source_mjcf: "",
    output: "",
    num_envs: 128,
    device_id: 0,
    self_collisions: false,
    capacity_profile: None,
  }
  assert_eq(base.profile().name(), "initial")
  let legacy : Map[String, Json] = @json.from_json(base.to_json())
  ignore(legacy.remove("capacity_profile"))
  let decoded : ExportConfig = @json.from_json(Json(legacy))
  assert_eq(decoded.profile().name(), "initial")
  assert_eq(
    { ..base, capacity_profile: Some("initial"), }.profile().name(),
    "initial",
  )
  assert_eq(
    { ..base, capacity_profile: Some("paper-4096"), }.profile().name(),
    "paper-4096",
  )
  let invalid_profile = Ok(
    { ..base, capacity_profile: Some("Paper-4096"), }.profile(),
  ) catch {
    e => Err(e)
  }
  assert_true(invalid_profile is Err(_))
}

///|
test "paper shared region follows native member bound without changing initial" {
  let initial = @capacity.CapacityProfile::parse("initial")
  let paper = @capacity.CapacityProfile::parse("paper-4096")
  assert_true(region_within_consumer_member_bound(1073741824L, paper))
  assert_true(!region_within_consumer_member_bound(1073741825L, paper))
  assert_true(region_within_consumer_member_bound(1073741825L, initial))
}
