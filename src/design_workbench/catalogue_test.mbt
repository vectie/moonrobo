///|
test "R20 native library comparison sources fork save build preserves originals" {
  let root = fixture_root("r20-library")
  @fsx.write_string_to_file(root + "/robot.json", "active physical profile")
  assert_eq(@design_workbench.catalogue(root).entries.length(), 0)
  assert_false(@fsx.path_exists(root + "/.moonsuite"))
  let first = save(root)
  let first_package = @design_workbench.build_revision(
    root,
    first.design_id,
    first.revision,
    first.design_digest,
  )
  guard design(revision="r2", max=0.2) is Object(fields) else {
    fail("fixture")
  }
  fields["task_loop"] = [
    "Dig a shallow scoop", "Load the payload bed", "Haul to the delivery area", "Dump and return to safe hold",
    "Inspect the scoop",
  ].to_json()
  fields["mechanisms"] = [
    { "id": "excavator", "kind": "shallow-scoop" },
    { "id": "payload-bed", "kind": "tipping-bed" },
    { "id": "mobility", "kind": "wheeled" },
  ]
  fields["validation"] = {
    "scenarios": [
      { "id": "nominal-cycle", "expected": "One shallow delivery completes" },
      {
        "id": "hazard-stop",
        "expected": "Motion stops when the hazard is detected",
      },
      {
        "id": "low-energy-return",
        "expected": "The declared energy reserve is preserved",
      },
    ],
  }
  let second = @design_workbench.save_draft(
    root,
    Json::object(fields),
    "2026-10-07T04:00:00Z",
  )
  let catalogue = @design_workbench.catalogue(root)
  assert_eq(catalogue.entries.length(), 2)
  assert_eq(catalogue.entries[0].state, "built")
  assert_eq(catalogue.entries[1].state, "draft")
  assert_eq(catalogue.entries[0].design_digest, first.design_digest)
  assert_false(catalogue.truncated)
  let left = @design_workbench.inspect_revision(
    root,
    first.design_id,
    first.revision,
  )
  let right = @design_workbench.inspect_revision(
    root,
    second.design_id,
    second.revision,
  )
  assert_eq(@design_workbench.catalogue(root), catalogue)
  // The shipped UI creates these ordinary fields. Saving is still explicit.
  fields["revision"] = "r3"
  let fork = @design_workbench.save_draft(
    root,
    Json::object(fields),
    "2026-10-07T04:01:00Z",
  )
  let fork_view = @design_workbench.inspect_revision(
    root,
    fork.design_id,
    fork.revision,
  )
  let roundtrip : Json = {
    "catalogue": catalogue,
    "left": left,
    "right": right,
    "fork": fork_view,
  }
  @fsx.write_string_to_file(
    "/tmp/moonrobo-r20-library-roundtrip.json",
    roundtrip.stringify(indent=2) + "\n",
  )
  let fork_package = @design_workbench.build_revision(
    root,
    fork.design_id,
    fork.revision,
    fork.design_digest,
  )
  assert_true(fork_package.package_json.contains("shallow-scoop"))
  assert_eq(
    @design_workbench.export_input(
      root,
      first.design_id,
      first.revision,
      first.design_digest,
    ),
    first_package,
  )
  assert_eq(
    @design_workbench.load_draft(root, second.design_id, second.revision),
    second,
  )
  assert_eq(
    @fsx.read_file_to_string(root + "/robot.json"),
    "active physical profile",
  )
  assert_false(@fsx.path_exists(root + "/bridge"))
}

///|
test "R20 library labels missing corrupt and partial evidence without repairing" {
  let root = fixture_root("r20-damaged-library")
  ignore(save(root))
  ignore(save(root, revision="r2"))
  let base = root +
    "/.moonsuite/products/moonrobo/design-workbench/excavation-haul/"
  @fsx.create_dir(base + "r1/build")
  @fsx.write_string_to_file(base + "r1/build/partial.txt", "keep me")
  @fsx.write_string_to_file(base + "r2/draft.json", "{ corrupt")
  @fsx.create_dir(base + "r3")
  let catalogue = @design_workbench.catalogue(root)
  assert_eq(catalogue.entries.map(e => e.state), [
    "unconfirmed", "corrupt-or-unreadable-draft", "missing-draft",
  ])
  assert_eq(catalogue.entries.map(e => e.selectable), [true, false, false])
  assert_eq(@fsx.read_file_to_string(base + "r1/build/partial.txt"), "keep me")
  assert_eq(@fsx.read_file_to_string(base + "r2/draft.json"), "{ corrupt")
  assert_false(@fsx.path_exists(base + "r3/draft.json"))
}

///|
test "R20 catalogue bounded deterministic and invalid names nonselectable" {
  let root = fixture_root("r20-bounded-library")
  ignore(save(root))
  let base = root +
    "/.moonsuite/products/moonrobo/design-workbench/excavation-haul/"
  for i in 0..<42 {
    @fsx.create_dir(base + "saved-\{i}")
  }
  let catalogue = @design_workbench.catalogue(root)
  assert_eq(catalogue.limit, 40)
  assert_eq(catalogue.entries.length(), 40)
  assert_true(catalogue.truncated)
  assert_eq(@design_workbench.catalogue(root), catalogue)
  let invalid_root = fixture_root("r20-invalid-name")
  ignore(save(invalid_root))
  @fsx.create_dir(
    invalid_root +
    "/.moonsuite/products/moonrobo/design-workbench/excavation-haul/UPPER",
  )
  let invalid = @design_workbench.catalogue(invalid_root).entries.filter(e => {
    e.revision == "UPPER"
  })
  assert_eq(invalid.length(), 1)
  assert_eq(invalid[0].state, "invalid-name")
  assert_false(invalid[0].selectable)
}
