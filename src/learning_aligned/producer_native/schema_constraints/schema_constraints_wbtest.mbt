///|
fn row(kind : String) -> Equality {
  {
    kind,
    world: 0,
    body1: 0,
    body2: 1,
    joint1: -1,
    joint2: -1,
    anchor: None,
    relpose: None,
    torquescale: None,
    polycoef: None,
    label: "",
    enabled: true,
    solref: None,
    solimp: None,
  }
}

///|
fn topology(rows : Array[Equality]) -> EqualityRequest {
  {
    world_count: 1,
    body_world: [0, 0],
    body_names: ["body-a", "body-b"],
    joints: [
      { world: 0, linear_dofs: 0, angular_dofs: 1, },
      { world: 0, linear_dofs: 1, angular_dofs: 0, },
    ],
    joint_names: ["j0", "j1"],
    rows,
  }
}

///|
test "authored resolver priority beats caller and mapping defaults" {
  let result = resolve_schema({
    resolvers: ["newton", "mjc"],
    prim_type: "joint",
    attributes: { "newton:armature": Json(0.0), "mjc:armature": Json(2.0) },
    keys: ["armature"],
    defaults: { "armature": Json(9.0) },
  })
  guard result
    is {
      "values": {
        "armature": { "value": Number(0), "authored_resolver": "newton", .. },
      },
      ..
    } else {
    fail("authored zero lost priority")
  }
}

///|
test "explicit fallback precedes transformed mapping default" {
  let request : SchemaRequest = {
    resolvers: ["mjc", "newton"],
    prim_type: "scene",
    attributes: {},
    keys: ["time_steps_per_second"],
    defaults: {},
  }
  let result = resolve_schema(request)
  guard result
    is {
      "values": {
        "time_steps_per_second": {
          "value": Number(500),
          "authored_resolver": Null,
          ..
        },
      },
      ..
    } else {
    fail("mapping timestep transform differs")
  }
  let override = resolve_schema({
    ..request,
    defaults: { "time_steps_per_second": Json(42) },
  })
  guard override
    is {
      "values": {
        "time_steps_per_second": {
          "value": Number(42),
          "origin": "caller-default",
          ..
        },
      },
      ..
    } else {
    fail("caller fallback transformed or reordered")
  }
}

///|
test "physx gap getter and direct raw solref mirror" {
  let gap = resolve_schema({
    resolvers: ["physx"],
    prim_type: "shape",
    attributes: {
      "physxCollision:restOffset": Json(1.0),
      "physxCollision:contactOffset": Json(3.0),
    },
    keys: ["gap"],
    defaults: {},
  })
  guard gap is { "values": { "gap": { "value": Number(2), .. } }, .. } else {
    fail("gap getter differs")
  }
  let direct = resolve_schema({
    resolvers: ["mjc"],
    prim_type: "shape",
    attributes: { "mjc:solref": Json([-2.0, -3.0]) },
    keys: ["ke", "kd"],
    defaults: {},
  })
  guard direct
    is {
      "values": {
        "ke": { "value": Number(2), .. },
        "kd": { "value": Number(3), .. },
      },
      ..
    } else {
    fail("direct stiffness/damping differs")
  }
}

///|
test "weld preserves compiler inference sentinel and world starts" {
  let prepared = prepare_equalities(topology([row("weld")]))
  guard prepared.data() is { "mjs_authoring": Array(rows), .. } &&
    rows[0]
    is { "reference_pose_inference_pending": true, "data": Array(values), .. } else {
    fail("weld inference metadata missing")
  }
  assert_eq(values[4], Json(1.0))
  assert_eq(values[6], Json(0.0))
  assert_eq(values[10], Json(1.0))
  let arrays = prepared.arrays()
  let raw = arrays[arrays
    .find_index(a => a.name == "mujoco.equality_constraint_world_start")
    .unwrap()]
  assert_eq(raw.bytes, b"\x00\x00\x00\x00\x01\x00\x00\x00\x01\x00\x00\x00")
  assert_true(
    prepared.mjcf().contains("<weld body1=\"body-a\" body2=\"body-b\""),
  )
}

///|
test "joint polynomial pads and owners are isolated" {
  let joint_row = {
    ..row("joint"),
    body1: -1,
    body2: -1,
    joint1: 0,
    joint2: 1,
    polycoef: Some([2.0, 3.0]),
  }
  let prepared = prepare_equalities(topology([joint_row]))
  guard prepared.data() is { "mjs_authoring": Array(rows), .. } &&
    rows[0] is { "data": Array(values), .. } else {
    fail("joint data missing")
  }
  assert_eq(values[0], Json(2.0))
  assert_eq(values[1], Json(3.0))
  assert_eq(values[4], Json(0.0))
  let before = prepared.data()
  if prepared.data() is Object(fields) {
    fields.clear()
  }
  assert_eq(prepared.data(), before)
  prepared.arrays()[0].shape[0] = 999
  assert_eq(prepared.arrays()[0].shape, [1])
}

///|
test "cross-world equality and unsupported schema key reject" {
  try
    prepare_equalities({
      ..topology([row("connect")]),
      body_world: [0, -1],
      rows: [{ ..row("connect"), world: -1, }],
    })
  catch {
    _ => ()
  } noraise {
    _ => fail("cross-world body accepted")
  }
  try
    resolve_schema({
      resolvers: ["newton"],
      prim_type: "shape",
      attributes: {},
      keys: ["unported-hull-cooking"],
      defaults: {},
    })
  catch {
    _ => ()
  } noraise {
    _ => fail("unknown schema key accepted")
  }
}
