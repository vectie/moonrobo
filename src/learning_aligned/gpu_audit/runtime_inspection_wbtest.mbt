///|
fn inspection_fixture(profile : @capacity.CapacityProfile) -> Json {
  let paper = profile == @capacity.Paper4096
  {
    "format": "moonrobo.apic-runtime-inspection.v1",
    "adapter_library": "/runtime/libapic.so",
    "adapter_library_sha256": "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
    "cuda_device_index": 0,
    "probe_num_envs": 2,
    "capacity_profile": Json(profile.name()),
    "cuda_free_bytes": "4294967296",
    "cuda_total_bytes": Json::null(),
    "paper_selected_audit_capacity_checked": Json(paper),
    "paper_selected_audit_capacity_confirmed": Json(paper),
    "no_graphs_loaded": true,
    "physics_validated": false,
  }
}

///|
test "runtime inspection validates exact options and bounded canonical file paths without CUDA" {
  let base = [
    "audit", "inspect-runtime", "--adapter", "/runtime/libapic.so", "--output", "/fresh/report.json",
  ]
  let options = runtime_inspection_options(base)
  assert_eq(options.profile, @capacity.Initial)
  assert_eq(options.device, 0)
  let paper = runtime_inspection_options(
    base + ["--device", "2", "--capacity-profile", "paper-4096"],
  )
  assert_eq(paper.profile, @capacity.Paper4096)
  assert_eq(paper.device, 2)
  for
    extra in [
      ["--adapter", "/runtime/other.so"],
      ["--manifest", "/bundle/manifest.json"],
      ["--device"],
      ["--device", "-1"],
      ["--capacity-profile", "paper4096"],
      ["--device", "0", "--device", "1"],
    ] {
    assert_true(
      capacity_rejected(() => runtime_inspection_options(base + extra)),
    )
  }
  for
    path in [
      "", "relative.so", "/", "/tmp/", "/tmp/../lib.so", "/tmp/./lib.so", "/tmp//lib.so",
      "/tmp/\u{0}lib.so",
    ] {
    assert_true(capacity_rejected(() => inspection_path(path)))
  }
  inspection_path("/" + String::make(4087, 'a'))
  assert_true(
    capacity_rejected(() => inspection_path("/" + String::make(4088, 'a'))),
  )
  assert_true(
    capacity_rejected(() => {
      runtime_inspection_options([
        "audit", "inspect-runtime", "--adapter", "/same.so", "--output", "/same.so",
      ])
    }),
  )
}

///|
test "runtime inspection requires actual free-only schema and explicit paper capability" {
  let base = [
    "audit", "inspect-runtime", "--adapter", "/runtime/libapic.so", "--output", "/fresh/report.json",
  ]
  for profile in [@capacity.Initial, @capacity.Paper4096] {
    let options = runtime_inspection_options(
      base + ["--capacity-profile", profile.name()],
    )
    let native = inspection_fixture(profile)
    let report = inspection_report(options, native, 1000L, 1020L)
    assert_true(
      report
      is {
        "success": true,
        "cuda_free_bytes": "4294967296",
        "cuda_total_bytes": Null,
        "graphs_loaded": 0,
        "physics_steps_executed": 0,
        "physics_validated": false,
        "memory_admission_granted": false,
        "elapsed_ms": "20",
        ..
      },
    )
    let fields : Map[String, Json] = @json.from_json(native)
    for
      (key, value) in [
        ("cuda_free_bytes", Json("0")),
        ("cuda_free_bytes", Json("9223372036854775808")),
        ("cuda_total_bytes", Json("8589934592")),
        ("adapter_library_sha256", Json("bad")),
        ("adapter_library", Json("/different.so")),
        ("cuda_device_index", Json(1)),
        ("physics_validated", Json(true)),
        ("no_graphs_loaded", Json(false)),
        ("capacity_profile", Json("unknown")),
        (
          "paper_selected_audit_capacity_confirmed",
          Json(profile != @capacity.Paper4096),
        ),
      ] {
      let invalid = fields.copy()
      invalid[key] = value
      assert_true(
        capacity_rejected(() => {
          inspection_report(options, Json(invalid), 1000L, 1020L)
        }),
      )
    }
    assert_true(
      capacity_rejected(() => inspection_report(options, native, 1020L, 1000L)),
    )
  }
}
