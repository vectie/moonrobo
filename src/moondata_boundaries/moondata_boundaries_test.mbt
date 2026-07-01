///|
fn read_manifest(path : String) -> String raise {
  @fsx.read_file_to_string(path) catch {
    _ => fail("failed to read " + path)
  }
}

///|
fn assert_not_contains(
  text : String,
  needle : String,
  label : String,
) -> Unit raise {
  if text.contains(needle) {
    fail(label + " contains forbidden dependency " + needle)
  }
}

///|
fn assert_contains(
  text : String,
  needle : String,
  label : String,
) -> Unit raise {
  if !text.contains(needle) {
    fail(label + " does not contain expected dependency " + needle)
  }
}

///|
test "moondata packages do not import moonrobo control or memory packages" {
  let manifests = [
    "src/moondata_core/moon.pkg", "src/moondata_store/moon.pkg", "src/moondata_ingest/moon.pkg",
    "src/moondata_quality/moon.pkg", "src/moondata_transform/moon.pkg", "src/moondata_annotation/moon.pkg",
    "src/moondata_export/moon.pkg", "src/moondata_api/moon.pkg", "src/moondata_validate/moon.pkg",
    "cmd/moondata/moon.pkg",
  ]
  let forbidden = [
    "\"vectie/moonrobo/src/runtime", "\"vectie/moonrobo/src/host_api", "\"vectie/moonrobo/src/moonbook",
    "\"vectie/moonrobo/src/pipeline", "\"vectie/moonrobo/src/platform_queue", "\"vectie/moonrobo/src/replay\"",
    "\"vectie/moonrobo/src/annotation\"", "\"vectie/moonrobo/src/bridge", "\"vectie/moonrobo/src/sdk",
    "\"vectie/moonrobo/src/core",
  ]
  for manifest in manifests {
    let text = read_manifest(manifest)
    for dependency in forbidden {
      assert_not_contains(text, dependency, manifest)
    }
  }
}

///|
test "moondata package dependency direction stays layered" {
  let core = read_manifest("src/moondata_core/moon.pkg")
  assert_not_contains(core, "\"vectie/moonrobo/src/moondata_", "moondata_core")
  let leaf_packages = [
    "src/moondata_ingest/moon.pkg", "src/moondata_quality/moon.pkg", "src/moondata_transform/moon.pkg",
    "src/moondata_annotation/moon.pkg", "src/moondata_export/moon.pkg",
  ]
  for manifest in leaf_packages {
    let text = read_manifest(manifest)
    assert_contains(text, "\"vectie/moonrobo/src/moondata_core\"", manifest)
    assert_not_contains(text, "\"vectie/moonrobo/src/moondata_store", manifest)
    assert_not_contains(text, "\"vectie/moonrobo/src/moondata_api", manifest)
    assert_not_contains(
      text, "\"vectie/moonrobo/src/moondata_validate", manifest,
    )
  }
  let api = read_manifest("src/moondata_api/moon.pkg")
  assert_contains(api, "\"vectie/moonrobo/src/moondata_core\"", "moondata_api")
  assert_contains(api, "\"vectie/moonrobo/src/moondata_store\"", "moondata_api")
  assert_not_contains(
    api, "\"vectie/moonrobo/src/moondata_validate", "moondata_api",
  )
  let validate = read_manifest("src/moondata_validate/moon.pkg")
  assert_contains(
    validate, "\"vectie/moonrobo/src/moondata_core\"", "moondata_validate",
  )
  assert_contains(
    validate, "\"vectie/moonrobo/src/moondata_store\"", "moondata_validate",
  )
  assert_not_contains(
    validate, "\"vectie/moonrobo/src/moondata_api", "moondata_validate",
  )
}
