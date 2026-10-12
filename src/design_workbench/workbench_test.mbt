///|
fn clear_fixture(path : String) -> Unit raise {
  if !@fsx.path_exists(path) {
    return
  }
  if @fsx.is_dir(path) {
    for name in @fsx.read_dir(path) {
      clear_fixture(path + "/" + name)
    }
    @fsx.remove_dir(path)
  } else {
    @fsx.remove_file(path)
  }
}

///|
fn fixture_root(name : String) -> String raise {
  let root = "/tmp/moonrobo-r8-workbench-" + name
  clear_fixture(root)
  @fsx.create_dir(root)
  root
}

///|
fn design(revision? : String = "r1", max? : Double = 0.1) -> Json {
  {
    "contract_id": "moonsuite.robot-design.v1",
    "design_id": "excavation-haul",
    "revision": revision,
    "mission": {
      "name": "Excavation and haul concept",
      "authority": "digital-only",
      "robot_class": "excavation-haul-rover",
    },
    "task_loop": [
      "Excavate a bounded scoop", "Load the payload bed", "Haul to the delivery area",
      "Dump and return to safe hold",
    ],
    "mechanisms": [
      { "id": "excavator", "kind": "scoop" },
      { "id": "payload-bed", "kind": "tipping-bed" },
      { "id": "mobility", "kind": "wheeled" },
    ],
    "validation": {
      "scenarios": [
        {
          "id": "nominal-cycle",
          "expected": "Delivery completes within declared bounds",
        },
        {
          "id": "hazard-stop",
          "expected": "Motion stops when the hazard is detected",
        },
        {
          "id": "low-energy-return",
          "expected": "The declared energy reserve is preserved",
        },
      ],
    },
    "constraints": { "commanded_speed_mps": { "min": 0.01, "max": max } },
  }
}

///|
fn save(
  root : String,
  revision? : String = "r1",
  max? : Double = 0.1,
) -> @design_workbench.DesignDraft raise {
  @design_workbench.save_draft(
    root,
    design(revision~, max~),
    "2026-10-06T16:00:00Z",
  )
}

///|
test "R8 edited loop mechanism and scenario reach the actual produced artifacts" {
  let root = fixture_root("edited-semantics")
  guard design(revision="r2") is Object(fields) else { fail("fixture") }
  fields["task_loop"] = [
    "Dig shallow trench", "Transfer material", "Haul bounded route", "Unload safely",
    "Inspect returned mechanism",
  ].to_json()
  let mechanisms : Json = [
    { "id": "scoop-head", "kind": "bounded-scoop" },
    { "id": "hopper", "kind": "tipping-hopper" },
    { "id": "traction", "kind": "wheeled-base" },
    { "id": "inspection-mast", "kind": "camera-positioner" },
  ]
  fields["mechanisms"] = mechanisms
  fields["validation"] = {
    "scenarios": [
      { "id": "cycle", "expected": "One bounded delivery completes" },
      { "id": "stop", "expected": "Hazard stops traction" },
      { "id": "return", "expected": "Return preserves reserve" },
      { "id": "mast", "expected": "Mast remains within declared range" },
    ],
  }
  let draft = @design_workbench.save_draft(
    root,
    Json::object(fields),
    "2026-10-06T16:00:00Z",
  )
  let envelope = @design_workbench.build_revision(
    root,
    draft.design_id,
    draft.revision,
    draft.design_digest,
  )
  let packet : @design_workbench.SimulationInput = @json.from_json(
    @json.parse(envelope.package_json),
  )
  let urdf = packet.sources.filter(s => s.artifact_ref.has_suffix("/robot.urdf"))[0]
  assert_true(urdf.text.contains("inspection-mast_joint"))
  assert_false(urdf.text.contains("excavator_joint"))
  let receipt = packet.sources.filter(s => {
      s.artifact_ref.has_suffix("/validation-receipt.json")
    })[0]
  assert_true(
    @json.parse(receipt.text)
    is {
      "quality": {
        "task_loop_steps": Number(5, ..),
        "mechanism_count": Number(4, ..),
        "validation_scenarios": Number(4, ..),
        ..
      },
      ..
    },
  )
  assert_eq(
    packet.sources.filter(s => s.artifact_ref == packet.design_ref)[0].text,
    draft.design_text,
  )
}

///|
test "R8 incomplete draft reservation and corrupted draft are preserved" {
  let root = fixture_root("draft-interruption")
  let draft = save(root)
  let path = root +
    "/.moonsuite/products/moonrobo/design-workbench/excavation-haul/r1/draft.json"
  @fsx.write_string_to_file(path, "{\"partial\":")
  try save(root) catch {
    _ => ()
  } noraise {
    _ => fail("must not overwrite partial draft")
  }
  assert_eq(@fsx.read_file_to_string(path), "{\"partial\":")
  @fsx.remove_file(path)
  try
    @design_workbench.build_revision(
      root,
      draft.design_id,
      draft.revision,
      draft.design_digest,
    )
  catch {
    _ => ()
  } noraise {
    _ => fail("must not build missing draft")
  }
  try save(root) catch {
    _ => ()
  } noraise {
    _ => fail("must not overwrite reserved draft")
  }
  assert_false(@fsx.path_exists(path))
}

///|
test "R8 actual producer saves builds reopens and exports exact MoonMoon robot inputs" {
  let root = fixture_root("producer")
  @fsx.write_string_to_file(root + "/robot.json", "physical profile sentinel\n")
  let draft = save(root)
  let envelope = @design_workbench.build_revision(
    root,
    draft.design_id,
    draft.revision,
    draft.design_digest,
  )
  let packet : @design_workbench.SimulationInput = @json.from_json(
    @json.parse(envelope.package_json),
  )
  assert_eq(packet.sources.length(), 8)
  assert_eq(packet.robot_artifact.artifact_root, "books/excavation-haul/r1")
  assert_eq(packet.robot_artifact.robot_revision, "r1")
  assert_true(
    !packet.physical_execution_allowed &&
    !packet.robot_artifact.physical_transport_enabled &&
    packet.review_required,
  )
  for source in packet.sources {
    assert_eq(@moondata_core.text_checksum(source.text), source.digest)
    assert_false(source.text.contains(root))
  }
  let profile = packet.sources.filter(s => {
      s.artifact_ref.has_suffix("/robot.json")
    })[0]
  assert_true(profile.text.contains("\"high_control_max_x_abs\": 0.1"))
  assert_true(profile.text.contains("\"simulation-only\""))
  let urdf = packet.sources.filter(s => s.artifact_ref.has_suffix("/robot.urdf"))[0]
  assert_true(urdf.text.contains("excavator_joint"))
  assert_true(urdf.text.contains("<box size=\"0.20 0.12 0.12\"/>"))
  assert_eq(
    packet.robot_artifact.robot_json_sha256,
    profile.digest[7:].to_owned(),
  )
  assert_eq(packet.robot_artifact.robot_urdf_sha256, urdf.digest[7:].to_owned())
  let integration = packet.sources.filter(s => {
      s.artifact_ref == packet.integration_receipt_ref
    })[0]
  let receipt : @suite_adapter.AdapterOperationReceipt = @json.from_json(
    @json.parse(integration.text),
  )
  assert_eq(receipt.operation_id, "robot.integrate-digital-model")
  assert_eq(receipt.status, "succeeded")
  assert_eq(receipt.observed_input_digests, [draft.design_digest])
  assert_false(receipt.physical_execution_performed)
  assert_eq(
    @design_workbench.export_input(
      root,
      draft.design_id,
      draft.revision,
      draft.design_digest,
    ),
    envelope,
  )
  assert_eq(
    @design_workbench.build_revision(
      root,
      draft.design_id,
      draft.revision,
      draft.design_digest,
    ),
    envelope,
  )
  assert_eq(
    @design_workbench.save_draft(root, design(), "2026-10-07T12:00:00Z"),
    draft,
  )
  assert_eq(
    @fsx.read_file_to_string(root + "/robot.json"),
    "physical profile sentinel\n",
  )
  @fsx.write_string_to_file(
    "/tmp/moonrobo-r8-simulation-input.json",
    envelope.to_json().stringify(indent=2) + "\n",
  )
  @fsx.write_string_to_file(
    "/tmp/moonrobo-r8-built-view.json",
    @design_workbench.inspect_revision(root, draft.design_id, draft.revision).stringify(
      indent=2,
    ) +
    "\n",
  )
}

///|
test "R8 edits require fresh revisions and leave old artifacts byte-identical" {
  let root = fixture_root("revisions")
  let old = save(root)
  let first = @design_workbench.build_revision(
    root,
    old.design_id,
    old.revision,
    old.design_digest,
  )
  try save(root, max=0.2) catch {
    _ => ()
  } noraise {
    _ => fail("must reject overwrite")
  }
  let next = save(root, revision="r2", max=0.2)
  let second = @design_workbench.build_revision(
    root,
    next.design_id,
    next.revision,
    next.design_digest,
  )
  assert_true(first.package_digest != second.package_digest)
  assert_eq(
    @design_workbench.export_input(
      root,
      old.design_id,
      old.revision,
      old.design_digest,
    ),
    first,
  )
  assert_eq(
    @design_workbench.load_draft(root, old.design_id, old.revision),
    old,
  )
  let packet : @design_workbench.SimulationInput = @json.from_json(
    @json.parse(second.package_json),
  )
  assert_true(
    packet.sources.any(s => {
      s.artifact_ref.has_suffix("/robot.json") &&
      s.text.contains("\"high_control_max_x_abs\": 0.2")
    }),
  )
}

///|
test "R8 stale digest and traversal are rejected without a build" {
  let root = fixture_root("stale")
  let draft = save(root)
  try
    @design_workbench.build_revision(
      root,
      draft.design_id,
      draft.revision,
      "sha256:stale",
    )
  catch {
    _ => ()
  } noraise {
    _ => fail("must reject stale")
  }
  assert_false(
    @fsx.path_exists(
      root +
      "/.moonsuite/products/moonrobo/design-workbench/excavation-haul/r1/build",
    ),
  )
  for id in ["../escape", "/absolute", "a/b", "UPPER", "a\\b", ""] {
    try @design_workbench.load_draft(root, id, "r1") catch {
      _ => ()
    } noraise {
      _ => fail("must reject unsafe id")
    }
  }
}

///|
test "R8 bounded class authority speed and concrete evidence enforced before saving" {
  let root = fixture_root("invalid")
  for max in [0.0, -1.0, 0.501, 0.001] {
    try save(root, max~) catch {
      _ => ()
    } noraise {
      _ => fail("must reject speed")
    }
  }
  let replacements : Array[Json] = [
    {
      "mission": {
        "authority": "physical",
        "robot_class": "excavation-haul-rover",
      },
    },
    {
      "mission": {
        "authority": "digital-only",
        "robot_class": "general-cad-robot",
      },
    },
    { "task_loop": ["only one step"] },
    {
      "mechanisms": [
        { "id": "duplicate", "kind": "x" },
        { "id": "duplicate", "kind": "x" },
        { "id": "other", "kind": "x" },
      ],
    },
    { "validation": { "scenarios": [{ "id": "empty", "expected": "" }] } },
  ]
  for replacement in replacements {
    guard design() is Object(fields) && replacement is Object(changes) else {
      fail("fixture")
    }
    for name, value in changes {
      fields[name] = value
    }
    try
      @design_workbench.save_draft(
        root,
        Json::object(fields),
        "2026-10-06T16:00:00Z",
      )
    catch {
      _ => ()
    } noraise {
      _ => fail("must reject design")
    }
  }
  assert_false(@fsx.path_exists(root + "/.moonsuite"))
}

///|
test "R8 interrupted builds remain unconfirmed and never automatically retry" {
  let root = fixture_root("partial")
  let draft = save(root)
  let path = root +
    "/.moonsuite/products/moonrobo/design-workbench/excavation-haul/r1/build"
  @fsx.create_dir(path)
  @fsx.write_string_to_file(path + "/partial.txt", "unconfirmed bytes")
  try
    @design_workbench.build_revision(
      root,
      draft.design_id,
      draft.revision,
      draft.design_digest,
    )
  catch {
    _ => ()
  } noraise {
    _ => fail("must reject retry")
  }
  assert_true(
    @design_workbench.inspect_revision(root, draft.design_id, draft.revision)
    is { "state": String("unconfirmed"), .. },
  )
  assert_eq(
    @fsx.read_file_to_string(path + "/partial.txt"),
    "unconfirmed bytes",
  )
  @fsx.write_string_to_file(path + "/package.json", "{\"partial\":")
  assert_true(
    @design_workbench.inspect_revision(root, draft.design_id, draft.revision)
    is { "state": String("unconfirmed"), .. },
  )
}

///|
test "R8 modified or missing generated files cannot export or silently rebuild" {
  for
    filename in [
      "robot.json", "model/robot.urdf", "bridge/bridge.json", "safety/policy.json",
      "design/robot-design.json", "design/build-receipt.json", "design/validation-receipt.json",
      "design/integration-receipt.json",
    ] {
    let root = fixture_root("drift")
    let draft = save(root)
    let _ = @design_workbench.build_revision(
      root,
      draft.design_id,
      draft.revision,
      draft.design_digest,
    )
    let file = root +
      "/.moonsuite/products/moonrobo/design-workbench/excavation-haul/r1/build/artifact/" +
      filename
    let original = @fsx.read_file_to_string(file)
    @fsx.write_string_to_file(file, original + " ")
    try
      @design_workbench.export_input(
        root,
        draft.design_id,
        draft.revision,
        draft.design_digest,
      )
    catch {
      _ => ()
    } noraise {
      _ => fail("must reject drift")
    }
    try
      @design_workbench.build_revision(
        root,
        draft.design_id,
        draft.revision,
        draft.design_digest,
      )
    catch {
      _ => ()
    } noraise {
      _ => fail("must reject rebuild")
    }
    assert_eq(@fsx.read_file_to_string(file), original + " ")
    @fsx.remove_file(file)
    assert_true(
      @design_workbench.inspect_revision(root, draft.design_id, draft.revision)
      is { "state": String("unconfirmed"), .. },
    )
  }
}
