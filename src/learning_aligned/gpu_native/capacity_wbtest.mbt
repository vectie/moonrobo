///|
fn capacity_contract(worlds : Int32, profile : String?) -> Manifest {
  let source = contract_manifest()
  {
    ..source,
    num_envs: worlds,
    capacity_profile: profile,
    shared_regions: source.shared_regions.map(region => {
      ..region,
      bytes: if region.name == "shape_mu" {
        (2 * worlds + 2) * 4
      } else if region.name == "body_com" {
        3 * worlds * 4
      } else {
        region.bytes / 2 * worlds
      },
    }),
    env_origins: Array::makei(worlds, world => {
      [world.to_double() * 3.0, 0.0, 0.0]
    }),
    context_writes: {
      shape_friction: {
        binding: "shape_mu",
        indices: Array::makei(worlds, world => [2 * world, 2 * world + 1]),
      },
      ground_friction: {
        binding: "shape_mu",
        indices: [2 * worlds, 2 * worlds + 1],
      },
      torso_com: {
        binding: "body_com",
        indices: Array::makei(worlds, world => {
          [3 * world, 3 * world + 1, 3 * world + 2]
        }),
        base: Array::makei(worlds, _ => [0.1, 0.2, 0.3]),
      },
    },
  }
}

///|
test "APIC capacity keeps legacy consumer byte limits and separates paper union from payload total" {
  let initial = bundle_limits(Initial)
  assert_eq(initial.metadata, 4194304L)
  assert_eq(initial.member, 268435456L)
  assert_eq(initial.total, 2147483648L)
  assert_eq(initial.union_bytes, 2147483648L)
  assert_eq(initial.files, 8192)
  assert_eq(initial.regions, 8192)
  assert_eq(initial.environments, 128)
  let paper = bundle_limits(Paper4096)
  assert_eq(paper.metadata, 67108864L)
  assert_eq(paper.member, 1073741824L)
  assert_eq(paper.total, 4294967296L)
  assert_eq(paper.union_bytes, 2147483648L)
  assert_eq(paper.files, 4096)
  assert_eq(paper.regions, 8192)
  assert_eq(paper.environments, 4096)
  assert_eq(add_bundle_bytes(1879048192L, 268435456L), initial.total)
  assert_eq(
    add_bundle_bytes(3221225472L, 1073741824L, capacity_profile=Paper4096),
    paper.total,
  )
  assert_eq(
    add_bundle_bytes(
      1073741824L,
      1073741824L,
      capacity_profile=Paper4096,
      union=true,
    ),
    paper.union_bytes,
  )
  for
    (total, bytes, union) in [
      (4294967296L, 1L, false),
      (2147483648L, 1L, true),
      (0L, 1073741825L, false),
      (9223372036854775807L, 1L, false),
      (-1L, 1L, false),
    ] {
    try
      add_bundle_bytes(total, bytes, capacity_profile=Paper4096, union~)
    catch {
      _ => ()
    } noraise {
      _ => fail("paper byte boundary/overflow accepted")
    }
  }
}

///|
test "manifest capacity is strict and never inferred from dimensions or null" {
  let legacy = contract_manifest().to_json()
  assert_eq(decode_bundle_manifest(legacy, Initial).profile(), Initial)
  let explicit_initial = {
    ..contract_manifest(),
    capacity_profile: Some("initial"),
  }.to_json()
  assert_eq(
    decode_bundle_manifest(explicit_initial, Initial).profile(),
    Initial,
  )
  let paper = { ..contract_manifest(), capacity_profile: Some("paper-4096"), }.to_json()
  assert_eq(decode_bundle_manifest(paper, Paper4096).profile(), Paper4096)
  for
    (value, expected) in [
      (legacy, @capacity.Paper4096),
      (explicit_initial, @capacity.Paper4096),
      (paper, @capacity.Initial),
    ] {
    try decode_bundle_manifest(value, expected) catch {
      _ => ()
    } noraise {
      _ => fail("mismatched caller/manifest profile accepted")
    }
  }
  for
    invalid in [
      Json::null(),
      Json(true),
      Json(["paper-4096"]),
      Json("Paper4096"),
      Json("paper-4096 "),
      Json(4096),
    ] {
    guard contract_manifest().to_json() is Object(fields) else {
      fail("fixture object")
    }
    fields["capacity_profile"] = invalid
    try decode_bundle_manifest(Json(fields), Paper4096) catch {
      _ => ()
    } noraise {
      _ => fail("invalid capacity field accepted")
    }
  }
}

///|
test "paper APIC metadata validates 4096 worlds but readback remains at most three rows" {
  let paper = capacity_contract(4096, Some("paper-4096"))
  paper.validate("source-model", true)
  validate_audit_worlds(4096, [0, 2048, 4095], capacity_profile=Paper4096)
  capacity_contract(128, None).validate("source-model", true)
  validate_audit_worlds(128, [0, 64, 127])
  for
    invalid in [
      capacity_contract(129, None),
      capacity_contract(4097, Some("paper-4096")),
    ] {
    try invalid.validate("source-model", true) catch {
      _ => ()
    } noraise {
      _ => fail("manifest world cap bypass")
    }
  }
  for
    (worlds, selected, profile) in [
      (129, [0], @capacity.Initial),
      (4097, [0], @capacity.Paper4096),
      (4096, [0, 1, 2, 3], @capacity.Paper4096),
      (4096, [0, 2048, 2048], @capacity.Paper4096),
      (4096, [4096], @capacity.Paper4096),
      (4096, [], @capacity.Paper4096),
      (4096, [-1], @capacity.Paper4096),
    ] {
    try
      validate_audit_worlds(worlds, selected, capacity_profile=profile)
    catch {
      _ => ()
    } noraise {
      _ => fail("selected audit boundary bypass")
    }
  }
  let sizes : Map[String, Int64] = {}
  for file in paper.files {
    sizes[file.path] = 4L
  }
  guard paper.resource_summary(sizes)
    is {
      "capacity_profile": String("paper-4096"),
      "num_envs": Number(4096),
      "complete_peak_estimate": False,
      "replaces_training_memory_admission": False,
      ..
    } else {
    fail("paper summary omitted explicit profile/limits")
  }
}

///|
test "paper inventory caps do not inherit legacy count or conflate union and disk" {
  let source = { ..contract_manifest(), capacity_profile: Some("paper-4096"), }
  { ..source, files: Array::make(4096, source.files[0]), }.validate_resource_limits()
  let gigabyte : SharedRegion = {
    name: "one",
    bytes: 1073741824,
    scalar_type: "float32",
  }
  { ..source, shared_regions: [gigabyte, { ..gigabyte, name: "two", }], }.validate_resource_limits()
  // File inventory and persistent numeric regions have independent counts.
  { ..source, shared_regions: Array::make(8192, { ..gigabyte, bytes: 4, }), }.validate_resource_limits()
  for
    invalid in [
      { ..source, files: Array::make(4097, source.files[0]), },
      {
        ..source,
        shared_regions: Array::make(8193, { ..gigabyte, bytes: 4, }),
      },
      { ..source, shared_regions: [{ ..gigabyte, bytes: 1073741828, }], },
      {
        ..source,
        shared_regions: [gigabyte, gigabyte, { ..gigabyte, bytes: 4, }],
      },
    ] {
    try invalid.validate_resource_limits() catch {
      _ => ()
    } noraise {
      _ => fail("paper resource cap bypass")
    }
  }
}

///|
async test "paper bundle requires matching caller before payload IO and hashes through existing bounded path" {
  @async.with_task_group() <| group => {
    let root = @fs.realpath(@fs.tmpdir(prefix="moonrobo-apic-capacity-"))
    group.add_defer(() => @fs.rmdir(root, recursive=true))
    let initial_path = write_bundle_fixture(root, b"tiny")
    let initial : Manifest = @json.from_json(
      @json.parse(@fs.read_file(initial_path).text()),
    )
    let paper = { ..initial, capacity_profile: Some("paper-4096"), }
    let path = root + "/paper.json"
    @fs.write_file(
      path,
      @utf8.encode(paper.to_json().stringify()),
      create_mode=CreateNew,
    )
    let verified = inspect_bundle(
      path,
      "source-model",
      capacity_profile=Paper4096,
    )
    guard verified is { "capacity_profile": String("paper-4096"), .. } else {
      fail("inspection lost explicit capacity")
    }
    // A missing member must not mask the earlier explicit-profile mismatch.
    @fs.rename(root + "/step.wrp", root + "/saved.wrp", replace=false)
    try validate_bundle(path, "source-model", true, None) catch {
      Failure(message) =>
        assert_true(message.contains("capacity profiles differ"))
      other => raise other
    } noraise {
      _ => fail("paper inferred without caller opt-in")
    }
    try
      validate_bundle(
        initial_path,
        "source-model",
        true,
        None,
        capacity_profile=Paper4096,
      )
    catch {
      Failure(message) =>
        assert_true(message.contains("capacity profiles differ"))
      other => raise other
    } noraise {
      _ => fail("legacy silently upgraded to paper")
    }
    let large = @fs.open(path, mode=ReadWrite)
    large.write_at(b"\x00", position=67108864L)
    large.close()
    try bounded_bundle_manifest(path, capacity_profile=Paper4096) catch {
      Failure(message) => assert_true(message.contains("file size outside"))
      other => raise other
    } noraise {
      _ => fail("paper metadata above 64 MiB parsed")
    }
  }
}
