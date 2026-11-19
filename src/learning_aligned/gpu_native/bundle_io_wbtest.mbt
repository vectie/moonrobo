///|
async fn write_bundle_fixture(root : String, payload : Bytes) -> String {
  let source = contract_manifest()
  let files = source.files.map(file => {
    ..file,
    sha256: @artifacts.sha256(payload),
  })
  let manifest = { ..source, files, }
  for file in files {
    @fs.write_file(root + "/" + file.path, payload, create_mode=CreateNew)
  }
  let path = root + "/manifest.json"
  @fs.write_file(
    path,
    @utf8.encode(manifest.to_json().stringify()),
    create_mode=CreateNew,
  )
  path
}

///|
async test "bundle verification streams payloads and adapter across 64 KiB without CUDA" {
  @async.with_task_group() <| group => {
    let root = @fs.realpath(@fs.tmpdir(prefix="moonrobo-apic-bundle-"))
    group.add_defer(() => @fs.rmdir(root, recursive=true))
    let payload = Bytes::makei(65539, i => (i % 251).to_byte())
    let path = write_bundle_fixture(root, payload)
    let manifest_hash = @artifacts.sha256(@fs.read_file(path).binary())
    let verified = validate_bundle(
      path,
      "source-model",
      true,
      Some(manifest_hash),
    )
    assert_eq(verified.digest, manifest_hash)
    assert_eq(verified.directory, root)
    assert_eq(verified.identities.length(), 5)
    let result = inspect_bundle(
      path,
      "source-model",
      adapter_library=root + "/step.wrp",
    )
    guard result
      is {
        "resources": resources,
        "adapter_library_sha256": String(library),
        ..
      } else {
      fail("missing verified resources")
    }
    assert_eq(library, @artifacts.sha256(payload))
    assert_eq(resources, verified.resources)
    let damaged = @fs.open(root + "/reset.wrp", mode=ReadWrite)
    damaged.write_at(b"\xff", position=65537L)
    damaged.close()
    try validate_bundle(path, "source-model", true, Some(manifest_hash)) catch {
      Failure(message) => assert_true(message.contains("SHA256 mismatch"))
      other => raise other
    } noraise {
      _ => fail("same-length bundle tampering was accepted")
    }
    try verified.assert_unchanged() catch {
      _ => ()
    } noraise {
      _ => fail("changed file identity was accepted")
    }
  }
}

///|
async test "all payload sizes are bounded before hashing and metadata is bounded before parsing" {
  @async.with_task_group() <| group => {
    let root = @fs.realpath(@fs.tmpdir(prefix="moonrobo-apic-bounds-"))
    group.add_defer(() => @fs.rmdir(root, recursive=true))
    let path = write_bundle_fixture(root, b"tiny")
    // Sparse one-byte extension does not allocate a 256 MiB test buffer.
    let oversized = @fs.open(root + "/refresh.wrp", mode=ReadWrite)
    oversized.write_at(b"\x00", position=BundleFileLimit)
    oversized.close()
    let invalid_hash = @fs.open(root + "/step.wrp", mode=ReadWrite)
    invalid_hash.write_at(b"x", position=0L)
    invalid_hash.close()
    try validate_bundle(path, "source-model", true, None) catch {
      Failure(message) => assert_true(message.contains("file size outside"))
      other => raise other
    } noraise {
      _ => fail("oversized late inventory member was accepted")
    }
    let metadata = @fs.open(path, mode=ReadWrite)
    metadata.write_at(b"\x00", position=BundleMetadataLimit)
    metadata.close()
    try bounded_bundle_manifest(path) catch {
      Failure(message) => assert_true(message.contains("file size outside"))
      other => raise other
    } noraise {
      _ => fail("oversized metadata was parsed")
    }
  }
}

///|
async test "bundle payload paths reject symlinks and traversal" {
  @async.with_task_group() <| group => {
    let root = @fs.realpath(@fs.tmpdir(prefix="moonrobo-apic-paths-"))
    group.add_defer(() => @fs.rmdir(root, recursive=true))
    let path = write_bundle_fixture(root, b"tiny")
    @fs.rename(root + "/reset.wrp", root + "/saved.wrp", replace=false)
    @fs.symlink(target=root + "/saved.wrp", root + "/reset.wrp")
    try validate_bundle(path, "source-model", true, None) catch {
      Failure(message) => assert_true(message.contains("regular file"))
      other => raise other
    } noraise {
      _ => fail("symlinked graph accepted")
    }
    @fs.mkdir(root + "/modules")
    @fs.write_file(root + "/modules/code.ptx", b"tiny", create_mode=CreateNew)
    @fs.symlink(target=root + "/modules", root + "/alias")
    try bundle_payload_path(root, "alias/code.ptx") catch {
      Failure(message) => assert_true(message.contains("must not be a symlink"))
      other => raise other
    } noraise {
      _ => fail("symlinked module directory accepted")
    }
    for name in ["../x", "a/../x", "/x", "a//x", "a\\x", "a:x", "a\nb", "./x"] {
      assert_false(relative_path(name))
    }
    assert_true(relative_path("step_modules/wp_actual_kernel.sm121.ptx"))
  }
}

///|
test "resource limits reject count, total, individual and graph aliases before payload IO" {
  let source = contract_manifest()
  let bad_files = { ..source, files: Array::make(8193, source.files[0]), }
  try bad_files.validate("source-model", true) catch {
    _ => ()
  } noraise {
    _ => fail("oversized file inventory accepted")
  }
  let large = { name: "large", bytes: 268435456, scalar_type: "float32", }
  for
    regions in [
      Array::make(9, large),
      [{ ..large, bytes: 268435460, }],
      Array::make(8193, large),
    ] {
    try
      { ..source, shared_regions: regions, }.validate_resource_limits()
    catch {
      _ => ()
    } noraise {
      _ => fail("unbounded shared regions accepted")
    }
  }
  try add_bundle_bytes(BundleTotalLimit, 1L) catch {
    _ => ()
  } noraise {
    _ => fail("bundle disk budget overflow accepted")
  }
  let aliases = {
    ..source,
    graphs: { ..source.graphs, reset: source.graphs.step, },
  }
  try aliases.validate("source-model", true) catch {
    _ => ()
  } noraise {
    _ => fail("four graph roles aliased one file")
  }
}

///|
test "four graph summary counts the shared union once and keeps scratch unknown" {
  let manifest = contract_manifest()
  manifest.validate("source-model", true)
  let sizes : Map[String, Int64] = {}
  for file in manifest.files {
    sizes[file.path] = 1024L
  }
  let summary = manifest.resource_summary(sizes)
  let mut expected = 0L
  for region in manifest.shared_regions {
    expected += region.bytes.to_int64()
  }
  guard summary
    is {
      "shared_numeric_union_bytes": union,
      "four_graph_shared_allocation_lower_bound_bytes": lower,
      "bundle_disk_bytes": disk,
      "shared_union_counted_once": True,
      "cuda_scratch_bytes": Null,
      "complete_peak_estimate": False,
      "replaces_training_memory_admission": False,
      "views": {
        "joint_position": { "shape": shape, "last_byte_exclusive": last, .. },
        ..
      },
      ..
    } else {
    fail("resource summary lacks explicit bounds/unknowns")
  }
  assert_eq(union, expected.to_json())
  assert_eq(lower, expected.to_json())
  assert_eq(disk, 4096L.to_json())
  assert_eq(shape, [2, 29].to_json())
  assert_eq(last, (2L * 29L * 4L).to_json())
}

///|
async test "original h manifest remains compatible with bounded metadata validation" {
  // Immutable metadata from the already exercised N=2 artifact; the graph and
  // PTX payloads are deliberately not included or opened by this CPU test.
  let (_, bytes) = bounded_bundle_manifest(
    "src/learning_aligned/gpu_native/testdata/legacy-h-manifest.json",
  )
  assert_eq(
    @artifacts.sha256(bytes),
    "38d67d87cb0c9294fc7c9cb7635b6b9a88587f23a0036bdeb3cb6de2d1fb9b51",
  )
  let manifest : Manifest = @json.from_json(@json.parse(@utf8.decode(bytes)))
  manifest.validate(
    "34cf0cf3c5fa5452fc24d33d9f31fb4a4435f3050366041e1dc853b39bdd20ee", false,
  )
  assert_eq(manifest.num_envs, 2)
  assert_eq(manifest.shared_regions.length(), 332)
  let mut shared_bytes = 0L
  for region in manifest.shared_regions {
    shared_bytes += region.bytes.to_int64()
  }
  assert_true(shared_bytes > 0L && shared_bytes <= BundleTotalLimit)
}
