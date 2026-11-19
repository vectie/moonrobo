///|
// Pending: these regression sources are typechecked, never executed this round.
fn empty_collision_layout() -> HostLayout {
  {
    arrays: {},
    aliases: {},
    storage_scope: {},
    body_count: 0,
    joint_count: 0,
    coord_count: 0,
    dof_count: 0,
    world_count: 2,
    scalar_type: "f32",
    target_layout: "coord",
    mass_properties_complete: false,
    unresolved_semantics: [],
  }
}

///|
fn test_shape(body : Int32, world : Int32, group : Int32) -> ResolvedShape {
  {
    kind: "sphere",
    body,
    world,
    transform: @geo.transform3(@geo.identity_basis3(), @geo.vec3(0, 0, 0)),
    scale: @geo.vec3(1, 0, 0),
    material: {
      ke: 1,
      kd: 0,
      kf: 0,
      ka: 0,
      mu: 0.5,
      restitution: 0,
      mu_torsional: 0,
      mu_rolling: 0,
      kh: 0,
    },
    flags: 2,
    collision_group: group,
    margin: 0,
    gap: 0,
    collision_radius: 1,
    is_solid: true,
  }
}

///|
test "Contacts count views share the exact physical counter bytes" {
  let layout = empty_collision_layout()
  add_contacts(layout, {
    rigid_max: 2,
    soft_max: 0,
    requires_grad: false,
    per_contact_shape_properties: true,
    contact_matching: true,
    contact_report: true,
    surface_velocity: true,
  })
  assert_eq(
    layout.aliases["contacts.soft_contact_count"].base,
    "contacts.contact_counters",
  )
  assert_eq(layout.aliases["contacts.soft_contact_count"].offset_bytes, 4)
  assert_eq(layout.aliases["contacts._reduction_overflow"].offset_bytes, 8)
  assert_eq(
    layout.array("contacts.rigid_contact_count").bytes,
    b"\x00\x00\x00\x00",
  )
  assert_eq(
    layout.array("contacts.rigid_contact_shape0").bytes,
    b"\xff\xff\xff\xff\xff\xff\xff\xff",
  )
  assert_eq(
    layout.array("contacts.rigid_contact_match_generation").bytes,
    b"\xff\xff\xff\xff",
  )
  assert_eq(layout.array("contacts.soft_contact_indices").bytes.length(), 0)
  assert_true(!layout.array_names().contains("contacts.rigid_contact_count"))
  assert_eq(
    layout.array("contacts.rigid_contact_diff_normal").bytes,
    layout.array("contacts.rigid_contact_normal").bytes,
  )
  layout.aliases["bad"] = {
    base: "contacts.contact_counters",
    offset_bytes: 12,
    shape: [1],
    components: 1,
  }
  try layout.array("bad") catch {
    _ => ()
  } noraise {
    _ => fail("out-of-owner alias must reject")
  }
}

///|
test "generic candidates preserve global worlds groups same-body and explicit exclusions" {
  let shapes = [
    test_shape(-1, -1, -1),
    test_shape(0, 0, 1),
    test_shape(0, 0, 1),
    test_shape(1, 0, 2),
    test_shape(2, 1, 1),
  ]
  let pairs = primitive_candidates(shapes, [{ a: 0, b: 3, }], 20)
  assert_eq(pairs.length(), 3)
  assert_eq(pairs[0].a, 0)
  assert_eq(pairs[0].b, 1)
  assert_eq(pairs[1].a, 0)
  assert_eq(pairs[1].b, 2)
  assert_eq(pairs[2].a, 0)
  assert_eq(pairs[2].b, 4)
  assert_true(!group_pair(-2, -2) && group_pair(-2, -3) && !group_pair(0, 1))
  try primitive_candidates(shapes, [], 1) catch {
    _ => ()
  } noraise {
    _ => fail("capacity must reject without dropping pairs")
  }
  assert_eq(shape_world_starts([-1, 0, 0, 1, -1], 2), [1, 3, 4, 5])
}

///|
test "Newton primitive enum scale and exact packed exclusions differ from MuJoCo conventions" {
  let sphere = test_shape(0, 0, 1)
  assert_eq(primitive_type(sphere), 3)
  assert_eq(
    primitive_type({ ..sphere, kind: "capsule", scale: @geo.vec3(0.2, 0.7, 0), }),
    4,
  )
  assert_eq(
    primitive_type({ ..sphere, kind: "cone", scale: @geo.vec3(0.2, 0.7, 0), }),
    9,
  )
  try primitive_type({ ..sphere, kind: "mesh", }) catch {
    _ => ()
  } noraise {
    _ => fail("cooked source must reject")
  }
  try primitive_type({ ..sphere, flags: 16, }) catch {
    _ => ()
  } noraise {
    _ => fail("hydroelastic must reject")
  }
  let codes = filter_codes([{ a: 5, b: 2, }, { a: 2, b: 5, }], 6)
  assert_eq(words64(codes, "i64").bytes, b"\x05\x00\x00\x00\x02\x00\x00\x00")
}
