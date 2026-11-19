///|
/// Contract tests are source only until the user authorizes test execution.
fn allocation(address : UInt64, bytes : Int64, kind : ScalarType) -> Allocation {
  {
    owner_id: "owner-" + address.to_string(),
    address,
    bytes,
    scalar_type: kind,
    capture_origin: None,
  }
}

///|
fn captures(entries : Array[CapturedRegion]) -> Array[GraphCapture] {
  [Step, Reset, Context, Refresh].map(fn(role) {
    { role, regions: entries.copy(), module_keys: [], }
  })
}

///|
fn rejected(work : () -> Unit raise) -> Bool {
  try {
    work()
    false
  } catch {
    Invalid(_) => true
    _ => false
  }
}

///|
fn union() -> NumericUnion raise ContractError {
  NumericUnion::build([allocation(4096UL, 256L, F32)], captures([]))
}

///|
test "union deduplicates exact address aliases but rejects conflicting capacity/type and partial overlap" {
  let a = allocation(4096UL, 64L, F32)
  let aliases = NumericUnion::build(
    [a, { ..a, owner_id: "other-base-owner", }],
    captures([]),
  )
  assert_eq(aliases.regions().length(), 1)
  assert_true(
    rejected(fn() raise {
      ignore(NumericUnion::build([a, { ..a, bytes: 68L, }], captures([])))
    }),
  )
  assert_true(
    rejected(fn() raise {
      ignore(NumericUnion::build([a, { ..a, scalar_type: I32, }], captures([])))
    }),
  )
  assert_true(
    rejected(fn() raise {
      ignore(
        NumericUnion::build([a, allocation(4128UL, 64L, F32)], captures([])),
      )
    }),
  )
  assert_true(
    rejected(fn() raise {
      ignore(NumericUnion::build([a, { ..a, address: 8192UL, }], captures([])))
    }),
  )
}

///|
test "allocation pointer/capacity overflow and pointer-bearing numeric relabeling fail" {
  for
    a in [
      allocation(0UL, 4L, F32),
      allocation(4096UL, 0L, F32),
      allocation(4096UL, 2147483648L, F32),
      allocation(0xFFFFFFFFFFFFFFFCUL, 8L, F32),
      allocation(4097UL, 8L, F32),
      allocation(4096UL, 6L, F32),
      allocation(4096UL, 8L, U8),
      allocation(4096UL, 8L, U64),
      allocation(4096UL, 8L, Opaque("struct mesh ptr")),
    ] {
    assert_true(
      rejected(fn() raise { ignore(NumericUnion::build([a], captures([]))) }),
    )
  }
}

///|
test "four distinct graph roles and scratch/persistent separation are mandatory" {
  let a = allocation(4096UL, 64L, F32)
  let graphs = captures([])
  assert_true(
    rejected(fn() raise {
      ignore(NumericUnion::build([a], graphs[:3].to_owned()))
    }),
  )
  graphs[3] = { ..graphs[3], role: Step, }
  assert_true(rejected(fn() raise { ignore(NumericUnion::build([a], graphs)) }))
  let escaped = captures([])
  escaped[0] = {
    ..escaped[0],
    regions: [
      { allocation: { ..a, capture_origin: Some("step"), }, transient: true, },
    ],
  }
  assert_true(
    rejected(fn() raise { ignore(NumericUnion::build([a], escaped)) }),
  )
  assert_true(
    rejected(fn() raise {
      ignore(
        NumericUnion::build(
          [{ ..a, capture_origin: Some("step"), }],
          captures([]),
        ),
      )
    }),
  )
  // Genuine disjoint temporary bytes may be opaque and remain outside union.
  let scratch = {
    allocation: { ..allocation(8192UL, 32L, U8), capture_origin: Some("step"), },
    transient: true,
  }
  let valid = captures([])
  valid[0] = { ..valid[0], regions: [scratch], }
  assert_eq(NumericUnion::build([a], valid).regions().length(), 1)
  let wrong_role = captures([])
  wrong_role[1] = { ..wrong_role[1], regions: [scratch], }
  assert_true(
    rejected(fn() raise { ignore(NumericUnion::build([a], wrong_role)) }),
  )
}

///|
test "physical context maps reject aliasing indices and preserve finite three-component COM" {
  let checked = NumericUnion::build(
    [allocation(4096UL, 256L, F32)],
    captures([]),
  )
  let writes : ContextWrites = {
    shape_friction: { binding: "shared_0", indices: [[0, 1], [2, 3]], },
    ground_friction: { binding: "shared_0", indices: [4], },
    torso_com: {
      binding: "shared_0",
      indices: [[5, 6, 7], [8, 9, 10]],
      base: [[0.0, 0.0, 0.0], [1.0, 2.0, 3.0]],
    },
  }
  writes.validate(checked, 2)
  let duplicate = {
    ..writes,
    ground_friction: { binding: "shared_0", indices: [1], },
  }
  assert_true(rejected(fn() raise { duplicate.validate(checked, 2) }))
  let outside = {
    ..writes,
    ground_friction: { binding: "shared_0", indices: [64], },
  }
  assert_true(rejected(fn() raise { outside.validate(checked, 2) }))
  let short_com = {
    ..writes,
    torso_com: { ..writes.torso_com, base: [[0.0, 0.0], [1.0, 2.0, 3.0]], },
  }
  assert_true(rejected(fn() raise { short_com.validate(checked, 2) }))
  assert_true(rejected(fn() raise { writes.validate(checked, 1) }))
}

///|
test "mesh handles retain separate exact uint64 relocation identity" {
  let mesh : MeshHandles = {
    allocation: allocation(8192UL, 16L, U64),
    owned: true,
    contiguous: true,
    handles: [0UL, 42UL],
    registered_mesh_ids: [42UL],
  }
  mesh.validate()
  let graphs = captures([{ allocation: mesh.allocation, transient: false, }])
  let checked = NumericUnion::build(
    [allocation(4096UL, 64L, F32)],
    graphs,
    mesh~,
  )
  assert_eq(checked.regions().length(), 1)
  assert_true(
    rejected(fn() raise {
      ignore(NumericUnion::build([mesh.allocation], graphs, mesh~))
    }),
  )
  assert_true(
    rejected(fn() raise {
      ({ ..mesh, handles: [42UL, 99UL], } : MeshHandles).validate()
    }),
  )
  assert_true(
    rejected(fn() raise {
      ({ ..mesh, handles: [42UL], } : MeshHandles).validate()
    }),
  )
  assert_true(
    rejected(fn() raise { ({ ..mesh, owned: false, } : MeshHandles).validate() }),
  )
  assert_true(
    rejected(fn() raise {
      ({ ..mesh, contiguous: false, } : MeshHandles).validate()
    }),
  )
}

///|
test "strided and compound views preserve element identity and check exact last element" {
  let checked = union()
  let matrix : RawView = {
    address: 4100UL,
    shape: [2, 3],
    byte_strides: [32L, 8L],
    element_bytes: 4,
    scalar_type: F32,
    affine: true,
  }
  let view = checked.view(matrix, 3, 2)
  assert_eq(view.offset_elements, 1)
  assert_eq(view.row_stride_elements, 8)
  assert_eq(view.component_stride_elements, 2)
  assert_eq(view.index(checked, 2, 1, 2), 13)
  let compound = {
    ..matrix,
    address: 4096UL,
    shape: [2],
    byte_strides: [12L],
    element_bytes: 12,
  }
  assert_eq(checked.view(compound, 3, 2).index(checked, 2, 1, 2), 5)
  let mutated = checked.regions()
  mutated.clear()
  assert_eq(checked.regions().length(), 1)
  for
    raw in [
      { ..matrix, address: 4095UL, },
      { ..matrix, byte_strides: [-4L, 4L], },
      { ..matrix, byte_strides: [32L, -4L], },
      { ..matrix, byte_strides: [9223372036854775807L, 4L], },
      { ..matrix, shape: [2, 4], },
      { ..matrix, element_bytes: 12, },
      { ..matrix, affine: false, },
      { ..matrix, scalar_type: I32, },
      { ..matrix, address: 4348UL, },
    ] {
    assert_true(rejected(fn() raise { ignore(checked.view(raw, 3, 2)) }))
  }
  assert_true(rejected(fn() raise { ignore(view.index(checked, 2, 2, 0)) }))
  assert_true(
    rejected(fn() raise {
      (
        { ..view, width: 2147483647, component_stride_elements: 2147483647, } :
        BufferView).validate(checked, 2147483647)
    }),
  )
}

///|
fn hash() -> String {
  "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
}

///|
fn source() -> SourceIdentity {
  {
    name: "newton",
    expected_revision: "71eeba16a717d4dcf0b9dd7056a7b6f863054dc3",
    observed_revision: "71eeba16a717d4dcf0b9dd7056a7b6f863054dc3",
    canonical_root: "/sdk/newton",
    imported_source: "/sdk/newton/newton/__init__.py",
    expected_sha256: hash(),
    observed_sha256: hash(),
    tracked_clean: true,
  }
}

///|
test "source identity requires actual observed hash/revision and canonical containment" {
  source().validate()
  for
    invalid in [
      { ..source(), imported_source: "/sdk/newton-copy/newton.py", },
      { ..source(), imported_source: "/sdk/newton/../copy.py", },
      { ..source(), canonical_root: "/sdk/newton/", },
      { ..source(), observed_sha256: "bad", },
      { ..source(), observed_revision: "different", },
      { ..source(), tracked_clean: false, },
    ] {
    assert_true(rejected(fn() raise { invalid.validate() }))
  }
  for
    invalid in [
      "../step.wrp", "step/../reset.wrp", "/step.wrp", "a\\b", "a//b", "./step.wrp",
      "x:y", "a\u{0}b", "",
    ] {
    assert_false(relative_path(invalid))
  }
  assert_false(
    sha256_hex(
      "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
    ),
  )
}

///|
test "inventory binds four graph files and exact compiler source/binary observed hashes" {
  let graphs = captures([])
  graphs[0] = { ..graphs[0], module_keys: ["module0"], }
  let paths : Map[String, String] = Map([
    ("step", "step.wrp"),
    ("reset", "reset.wrp"),
    ("context", "context.wrp"),
    ("refresh", "refresh.wrp"),
  ])
  let files = [
    "step.wrp", "reset.wrp", "context.wrp", "refresh.wrp", "module0.cu", "module0.ptx",
  ].map(fn(path) { { path, expected_sha256: hash(), observed_sha256: hash(), } })
  let module0 : ModuleIdentity = {
    key: "module0",
    backend: PTX,
    source_path: "module0.cu",
    source_sha256: hash(),
    binary_path: "module0.ptx",
    binary_sha256: hash(),
    compiler_options: ["--gpu-architecture=compute_90"],
  }
  let options = module0.compiler_options
  let inventory = validate_inventory(
    files,
    [module0],
    [source()],
    graphs,
    paths,
  )
  options.push("--mutated-after-check")
  guard inventory.modules_json() is Array(modules) &&
    modules[0] is Object(fields) else {
    fail("expected module metadata")
  }
  assert_eq(
    fields.get("compiler_options"),
    Some(["--gpu-architecture=compute_90"].to_json()),
  )
  let bad = files.copy()
  bad[0] = { ..bad[0], observed_sha256: "bad", }
  assert_true(
    rejected(fn() raise {
      ignore(validate_inventory(bad, [module0], [source()], graphs, paths))
    }),
  )
  assert_true(
    rejected(fn() raise {
      ignore(validate_inventory(files, [], [source()], graphs, paths))
    }),
  )
  assert_true(
    rejected(fn() raise {
      ignore(
        validate_inventory(files, [module0], [source()], captures([]), paths),
      )
    }),
  )
  let missing = paths.copy()
  ignore(missing.remove("refresh"))
  assert_true(
    rejected(fn() raise {
      ignore(validate_inventory(files, [module0], [source()], graphs, missing))
    }),
  )
  let duplicate = files.copy()
  duplicate.push(files[0])
  assert_true(
    rejected(fn() raise {
      ignore(
        validate_inventory(duplicate, [module0], [source()], graphs, paths),
      )
    }),
  )
}
