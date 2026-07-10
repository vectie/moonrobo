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
fn assert_path_exists(path : String) -> Unit raise {
  if !@fsx.path_exists(path) {
    fail("expected path to exist: " + path)
  }
}

///|
fn assert_array_contains(
  values : Array[String],
  value : String,
  label : String,
) -> Unit raise {
  for candidate in values {
    if candidate == value {
      return
    }
  }
  fail(label + " is missing " + value)
}

///|
fn assert_only_expected_moondata_dirs(
  root : String,
  prefix : String,
  expected : Array[String],
) -> Unit raise {
  let names = @fsx.read_dir(root) catch {
    _ => fail("failed to read directory " + root)
  }
  for name in names {
    if name.has_prefix(prefix) {
      assert_array_contains(expected, name, root)
    }
  }
  for name in expected {
    assert_path_exists(root + "/" + name)
  }
}

///|
fn moondata_manifests() -> Array[String] {
  [
    "src/moondata_core/moon.pkg", "src/moondata_store/moon.pkg", "src/moondata_blob/moon.pkg",
    "src/moondata_ingest/moon.pkg", "src/moondata_capture/moon.pkg", "src/moondata_quality/moon.pkg",
    "src/moondata_assess/moon.pkg", "src/moondata_transform/moon.pkg", "src/moondata_curate/moon.pkg",
    "src/moondata_annotation/moon.pkg", "src/moondata_review/moon.pkg", "src/moondata_handoff/moon.pkg",
    "src/moondata_export/moon.pkg", "src/moondata_replay/moon.pkg", "src/moondata_publish/moon.pkg",
    "src/moondata_index/moon.pkg", "src/moondata_import/moon.pkg", "src/moondata_robot_model/moon.pkg",
    "src/moondata_normalize/moon.pkg", "src/moondata_pipeline/moon.pkg", "src/moondata_api/moon.pkg",
    "src/moondata_validate/moon.pkg", "src/moondata_repair/moon.pkg", "cmd/moondata/moon.pkg",
  ]
}

///|
fn moondata_source_files() -> Array[String] {
  [
    "docs/MOONDATA.md", "cmd/moondata/main.mbt", "cmd/moondata/moon.pkg", "src/moondata_annotation/moon.pkg",
    "src/moondata_annotation/moondata_annotation_test.mbt", "src/moondata_annotation/review.mbt",
    "src/moondata_api/annotations.mbt", "src/moondata_api/artifacts.mbt", "src/moondata_api/captures.mbt",
    "src/moondata_api/context.mbt", "src/moondata_api/data_refs.mbt", "src/moondata_api/datasets.mbt",
    "src/moondata_api/episodes.mbt", "src/moondata_api/exports.mbt", "src/moondata_api/frames.mbt",
    "src/moondata_api/handoff.mbt", "src/moondata_api/handoffs.mbt", "src/moondata_api/lineage.mbt",
    "src/moondata_api/moon.pkg", "src/moondata_api/moondata_api_test.mbt", "src/moondata_api/quality.mbt",
    "src/moondata_api/payloads.mbt", "src/moondata_api/repairs.mbt", "src/moondata_api/replays.mbt",
    "src/moondata_api/robot_models.mbt", "src/moondata_api/slice.mbt", "src/moondata_api/signals.mbt",
    "src/moondata_api/sources.mbt", "src/moondata_api/status.mbt", "src/moondata_api/transforms.mbt",
    "src/moondata_api/validations.mbt", "src/moondata_api/versions.mbt", "src/moondata_assess/dataset_quality.mbt",
    "src/moondata_assess/moon.pkg", "src/moondata_assess/moondata_assess_test.mbt",
    "src/moondata_blob/local_blob.mbt", "src/moondata_blob/moon.pkg", "src/moondata_blob/moondata_blob_test.mbt",
    "src/moondata_boundaries/boundary.mbt", "src/moondata_boundaries/moon.pkg", "src/moondata_capture/moon.pkg",
    "src/moondata_capture/moondata_capture_test.mbt", "src/moondata_capture/sealed_mcap.mbt",
    "src/moondata_capture/sealed_mcap_test.mbt", "src/moondata_capture/stored_capture.mbt",
    "src/moondata_core/annotation.mbt", "src/moondata_core/artifact_ref.mbt", "src/moondata_core/capture.mbt",
    "src/moondata_core/catalog.mbt", "src/moondata_core/checksum.mbt", "src/moondata_core/dataset.mbt",
    "src/moondata_core/episode.mbt", "src/moondata_core/export.mbt", "src/moondata_core/frame_ref.mbt",
    "src/moondata_core/handoff.mbt", "src/moondata_core/ids.mbt", "src/moondata_core/json.mbt",
    "src/moondata_core/lineage.mbt", "src/moondata_core/moon.pkg", "src/moondata_core/moondata_core_test.mbt",
    "src/moondata_core/quality.mbt", "src/moondata_core/repair.mbt", "src/moondata_core/replay.mbt",
    "src/moondata_core/robot_model.mbt", "src/moondata_core/signal.mbt", "src/moondata_core/source.mbt",
    "src/moondata_core/transform.mbt", "src/moondata_core/uri.mbt", "src/moondata_core/validation.mbt",
    "src/moondata_curate/moon.pkg", "src/moondata_curate/moondata_curate_test.mbt",
    "src/moondata_curate/stored_curation.mbt", "src/moondata_export/export_builder.mbt",
    "src/moondata_export/moon.pkg", "src/moondata_export/moondata_export_test.mbt",
    "src/moondata_handoff/moon.pkg", "src/moondata_handoff/moondata_handoff_test.mbt",
    "src/moondata_handoff/stored_handoff.mbt", "src/moondata_import/local_files.mbt",
    "src/moondata_import/moon.pkg", "src/moondata_import/moondata_import_test.mbt",
    "src/moondata_index/index.mbt", "src/moondata_index/moon.pkg", "src/moondata_index/moondata_index_test.mbt",
    "src/moondata_ingest/capture_registration.mbt", "src/moondata_ingest/moon.pkg",
    "src/moondata_ingest/moondata_ingest_test.mbt", "src/moondata_normalize/moon.pkg",
    "src/moondata_normalize/moondata_normalize_test.mbt", "src/moondata_normalize/raw_to_canonical.mbt",
    "src/moondata_pipeline/local_file_product.mbt", "src/moondata_pipeline/moon.pkg",
    "src/moondata_pipeline/moondata_pipeline_test.mbt", "src/moondata_pipeline/review_replay_product.mbt",
    "src/moondata_publish/moon.pkg", "src/moondata_publish/moondata_publish_test.mbt",
    "src/moondata_publish/stored_export.mbt", "src/moondata_quality/deterministic.mbt",
    "src/moondata_review/moon.pkg", "src/moondata_review/moondata_review_test.mbt",
    "src/moondata_review/stored_review.mbt", "src/moondata_replay/moon.pkg", "src/moondata_replay/moondata_replay_test.mbt",
    "src/moondata_replay/stored_replay.mbt", "src/moondata_robot_model/import_model.mbt",
    "src/moondata_robot_model/moon.pkg", "src/moondata_robot_model/moondata_robot_model_test.mbt",
    "src/moondata_repair/moon.pkg", "src/moondata_repair/moondata_repair_test.mbt",
    "src/moondata_repair/repair_plan.mbt", "src/moondata_repair/repair_receipt.mbt",
    "src/moondata_quality/moon.pkg", "src/moondata_quality/moondata_quality_test.mbt",
    "src/moondata_store/moon.pkg", "src/moondata_store/moondata_store_test.mbt",
    "src/moondata_store/store.mbt", "src/moondata_transform/curation.mbt", "src/moondata_transform/moon.pkg",
    "src/moondata_transform/moondata_transform_test.mbt", "src/moondata_validate/moon.pkg",
    "src/moondata_validate/moondata_validate_test.mbt", "src/moondata_validate/validation.mbt",
  ]
}

///|
test "moondata packages do not import moonrobo control or memory packages" {
  let forbidden = [
    "\"vectie/moonrobo/src/runtime", "\"vectie/moonrobo/src/host_api", "\"vectie/moonrobo/src/moonbook",
    "\"vectie/moonrobo/src/pipeline", "\"vectie/moonrobo/src/platform_queue", "\"vectie/moonrobo/src/replay\"",
    "\"vectie/moonrobo/src/annotation\"", "\"vectie/moonrobo/src/bridge", "\"vectie/moonrobo/src/sdk",
    "\"vectie/moonrobo/src/core",
  ]
  for manifest in moondata_manifests() {
    let text = read_manifest(manifest)
    for dependency in forbidden {
      assert_not_contains(text, dependency, manifest)
    }
  }
}

///|
test "moondata package list is explicit and standalone" {
  assert_only_expected_moondata_dirs("src", "moondata_", [
    "moondata_annotation", "moondata_api", "moondata_assess", "moondata_blob", "moondata_boundaries",
    "moondata_capture", "moondata_core", "moondata_curate", "moondata_export", "moondata_handoff",
    "moondata_import", "moondata_index", "moondata_ingest", "moondata_normalize",
    "moondata_pipeline", "moondata_publish", "moondata_quality", "moondata_repair",
    "moondata_replay", "moondata_review", "moondata_robot_model", "moondata_store",
    "moondata_transform", "moondata_validate",
  ])
  assert_only_expected_moondata_dirs("cmd", "moondata", ["moondata"])
  for manifest in moondata_manifests() {
    assert_path_exists(manifest)
  }
}

///|
test "moondata source stays free of reference product residue" {
  let forbidden = [
    "Robot " + "Data Studio",
    "." + "rds-artifacts",
    "../" + "rds",
    "/" + "rds/",
    "R" + "DS",
  ]
  for path in moondata_source_files() {
    let text = read_manifest(path)
    for term in forbidden {
      assert_not_contains(text, term, path)
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
  let index = read_manifest("src/moondata_index/moon.pkg")
  assert_contains(
    index, "\"vectie/moonrobo/src/moondata_core\"", "moondata_index",
  )
  assert_contains(
    index, "\"vectie/moonrobo/src/moondata_store\"", "moondata_index",
  )
  assert_not_contains(
    index, "\"vectie/moonrobo/src/moondata_api", "moondata_index",
  )
  assert_not_contains(
    index, "\"vectie/moonrobo/src/moondata_validate", "moondata_index",
  )
  let assess = read_manifest("src/moondata_assess/moon.pkg")
  assert_contains(
    assess, "\"vectie/moonrobo/src/moondata_core\"", "moondata_assess",
  )
  assert_contains(
    assess, "\"vectie/moonrobo/src/moondata_store\"", "moondata_assess",
  )
  assert_contains(
    assess, "\"vectie/moonrobo/src/moondata_quality\"", "moondata_assess",
  )
  assert_contains(
    assess, "\"vectie/moonrobo/src/moondata_index\"", "moondata_assess",
  )
  assert_not_contains(
    assess, "\"vectie/moonrobo/src/moondata_import", "moondata_assess",
  )
  assert_not_contains(
    assess, "\"vectie/moonrobo/src/moondata_normalize", "moondata_assess",
  )
  assert_not_contains(
    assess, "\"vectie/moonrobo/src/moondata_api", "moondata_assess",
  )
  assert_not_contains(
    assess, "\"vectie/moonrobo/src/moondata_validate", "moondata_assess",
  )
  let capture = read_manifest("src/moondata_capture/moon.pkg")
  assert_contains(
    capture, "\"vectie/moonrobo/src/moondata_core\"", "moondata_capture",
  )
  assert_contains(
    capture, "\"vectie/moonrobo/src/moondata_ingest\"", "moondata_capture",
  )
  assert_contains(
    capture, "\"vectie/moonrobo/src/moondata_store\"", "moondata_capture",
  )
  assert_contains(
    capture, "\"vectie/moonrobo/src/moondata_index\"", "moondata_capture",
  )
  assert_not_contains(
    capture, "\"vectie/moonrobo/src/moondata_api", "moondata_capture",
  )
  assert_not_contains(
    capture, "\"vectie/moonrobo/src/moondata_validate", "moondata_capture",
  )
  let curate = read_manifest("src/moondata_curate/moon.pkg")
  assert_contains(
    curate, "\"vectie/moonrobo/src/moondata_core\"", "moondata_curate",
  )
  assert_contains(
    curate, "\"vectie/moonrobo/src/moondata_store\"", "moondata_curate",
  )
  assert_contains(
    curate, "\"vectie/moonrobo/src/moondata_transform\"", "moondata_curate",
  )
  assert_contains(
    curate, "\"vectie/moonrobo/src/moondata_index\"", "moondata_curate",
  )
  assert_not_contains(
    curate, "\"vectie/moonrobo/src/moondata_import", "moondata_curate",
  )
  assert_not_contains(
    curate, "\"vectie/moonrobo/src/moondata_normalize", "moondata_curate",
  )
  assert_not_contains(
    curate, "\"vectie/moonrobo/src/moondata_assess", "moondata_curate",
  )
  assert_not_contains(
    curate, "\"vectie/moonrobo/src/moondata_api", "moondata_curate",
  )
  assert_not_contains(
    curate, "\"vectie/moonrobo/src/moondata_validate", "moondata_curate",
  )
  let publish = read_manifest("src/moondata_publish/moon.pkg")
  assert_contains(
    publish, "\"vectie/moonrobo/src/moondata_core\"", "moondata_publish",
  )
  assert_contains(
    publish, "\"vectie/moonrobo/src/moondata_store\"", "moondata_publish",
  )
  assert_contains(
    publish, "\"vectie/moonrobo/src/moondata_export\"", "moondata_publish",
  )
  assert_contains(
    publish, "\"vectie/moonrobo/src/moondata_index\"", "moondata_publish",
  )
  assert_not_contains(
    publish, "\"vectie/moonrobo/src/moondata_import", "moondata_publish",
  )
  assert_not_contains(
    publish, "\"vectie/moonrobo/src/moondata_normalize", "moondata_publish",
  )
  assert_not_contains(
    publish, "\"vectie/moonrobo/src/moondata_curate", "moondata_publish",
  )
  assert_not_contains(
    publish, "\"vectie/moonrobo/src/moondata_assess", "moondata_publish",
  )
  assert_not_contains(
    publish, "\"vectie/moonrobo/src/moondata_api", "moondata_publish",
  )
  assert_not_contains(
    publish, "\"vectie/moonrobo/src/moondata_validate", "moondata_publish",
  )
  let replay = read_manifest("src/moondata_replay/moon.pkg")
  assert_contains(
    replay, "\"vectie/moonrobo/src/moondata_core\"", "moondata_replay",
  )
  assert_contains(
    replay, "\"vectie/moonrobo/src/moondata_store\"", "moondata_replay",
  )
  assert_contains(
    replay, "\"vectie/moonrobo/src/moondata_index\"", "moondata_replay",
  )
  assert_not_contains(
    replay, "\"vectie/moonrobo/src/moondata_import", "moondata_replay",
  )
  assert_not_contains(
    replay, "\"vectie/moonrobo/src/moondata_normalize", "moondata_replay",
  )
  assert_not_contains(
    replay, "\"vectie/moonrobo/src/moondata_curate", "moondata_replay",
  )
  assert_not_contains(
    replay, "\"vectie/moonrobo/src/moondata_assess", "moondata_replay",
  )
  assert_not_contains(
    replay, "\"vectie/moonrobo/src/moondata_api", "moondata_replay",
  )
  assert_not_contains(
    replay, "\"vectie/moonrobo/src/moondata_validate", "moondata_replay",
  )
  let review = read_manifest("src/moondata_review/moon.pkg")
  assert_contains(
    review, "\"vectie/moonrobo/src/moondata_core\"", "moondata_review",
  )
  assert_contains(
    review, "\"vectie/moonrobo/src/moondata_store\"", "moondata_review",
  )
  assert_contains(
    review, "\"vectie/moonrobo/src/moondata_annotation\"", "moondata_review",
  )
  assert_contains(
    review, "\"vectie/moonrobo/src/moondata_index\"", "moondata_review",
  )
  assert_not_contains(
    review, "\"vectie/moonrobo/src/moondata_import", "moondata_review",
  )
  assert_not_contains(
    review, "\"vectie/moonrobo/src/moondata_normalize", "moondata_review",
  )
  assert_not_contains(
    review, "\"vectie/moonrobo/src/moondata_curate", "moondata_review",
  )
  assert_not_contains(
    review, "\"vectie/moonrobo/src/moondata_assess", "moondata_review",
  )
  assert_not_contains(
    review, "\"vectie/moonrobo/src/moondata_api", "moondata_review",
  )
  assert_not_contains(
    review, "\"vectie/moonrobo/src/moondata_validate", "moondata_review",
  )
  let handoff = read_manifest("src/moondata_handoff/moon.pkg")
  assert_contains(
    handoff, "\"vectie/moonrobo/src/moondata_core\"", "moondata_handoff",
  )
  assert_contains(
    handoff, "\"vectie/moonrobo/src/moondata_store\"", "moondata_handoff",
  )
  assert_contains(
    handoff, "\"vectie/moonrobo/src/moondata_index\"", "moondata_handoff",
  )
  assert_contains(
    handoff, "\"vectie/moonrobo/src/moondata_validate\"", "moondata_handoff",
  )
  assert_contains(
    handoff, "\"vectie/moonrobo/src/moondata_api\"", "moondata_handoff",
  )
  assert_not_contains(
    handoff, "\"vectie/moonrobo/src/moondata_import", "moondata_handoff",
  )
  assert_not_contains(
    handoff, "\"vectie/moonrobo/src/moondata_normalize", "moondata_handoff",
  )
  assert_not_contains(
    handoff, "\"vectie/moonrobo/src/moondata_curate", "moondata_handoff",
  )
  assert_not_contains(
    handoff, "\"vectie/moonrobo/src/moondata_assess", "moondata_handoff",
  )
  let pipeline = read_manifest("src/moondata_pipeline/moon.pkg")
  assert_contains(
    pipeline, "\"vectie/moonrobo/src/moondata_import\"", "moondata_pipeline",
  )
  assert_contains(
    pipeline, "\"vectie/moonrobo/src/moondata_normalize\"", "moondata_pipeline",
  )
  assert_contains(
    pipeline, "\"vectie/moonrobo/src/moondata_assess\"", "moondata_pipeline",
  )
  assert_contains(
    pipeline, "\"vectie/moonrobo/src/moondata_curate\"", "moondata_pipeline",
  )
  assert_contains(
    pipeline, "\"vectie/moonrobo/src/moondata_review\"", "moondata_pipeline",
  )
  assert_contains(
    pipeline, "\"vectie/moonrobo/src/moondata_publish\"", "moondata_pipeline",
  )
  assert_contains(
    pipeline, "\"vectie/moonrobo/src/moondata_replay\"", "moondata_pipeline",
  )
  assert_contains(
    pipeline, "\"vectie/moonrobo/src/moondata_validate\"", "moondata_pipeline",
  )
  assert_not_contains(
    pipeline, "\"vectie/moonrobo/src/moondata_api", "moondata_pipeline",
  )
  let import_manifest = read_manifest("src/moondata_import/moon.pkg")
  assert_contains(
    import_manifest, "\"vectie/moonrobo/src/moondata_core\"", "moondata_import",
  )
  assert_contains(
    import_manifest, "\"vectie/moonrobo/src/moondata_store\"", "moondata_import",
  )
  assert_contains(
    import_manifest, "\"vectie/moonrobo/src/moondata_index\"", "moondata_import",
  )
  assert_not_contains(
    import_manifest, "\"vectie/moonrobo/src/moondata_api", "moondata_import",
  )
  assert_not_contains(
    import_manifest, "\"vectie/moonrobo/src/moondata_validate", "moondata_import",
  )
  let robot_model = read_manifest("src/moondata_robot_model/moon.pkg")
  assert_contains(
    robot_model, "\"vectie/moonrobo/src/moondata_core\"", "moondata_robot_model",
  )
  assert_contains(
    robot_model, "\"vectie/moonrobo/src/moondata_store\"", "moondata_robot_model",
  )
  assert_contains(
    robot_model, "\"vectie/moonrobo/src/moondata_index\"", "moondata_robot_model",
  )
  assert_not_contains(
    robot_model, "\"vectie/moonrobo/src/moondata_api", "moondata_robot_model",
  )
  let normalize = read_manifest("src/moondata_normalize/moon.pkg")
  assert_contains(
    normalize, "\"vectie/moonrobo/src/moondata_core\"", "moondata_normalize",
  )
  assert_contains(
    normalize, "\"vectie/moonrobo/src/moondata_store\"", "moondata_normalize",
  )
  assert_contains(
    normalize, "\"vectie/moonrobo/src/moondata_index\"", "moondata_normalize",
  )
  assert_not_contains(
    normalize, "\"vectie/moonrobo/src/moondata_import", "moondata_normalize",
  )
  assert_not_contains(
    normalize, "\"vectie/moonrobo/src/moondata_api", "moondata_normalize",
  )
  assert_not_contains(
    normalize, "\"vectie/moonrobo/src/moondata_validate", "moondata_normalize",
  )
  let validate = read_manifest("src/moondata_validate/moon.pkg")
  assert_contains(
    validate, "\"vectie/moonrobo/src/moondata_core\"", "moondata_validate",
  )
  assert_contains(
    validate, "\"vectie/moonrobo/src/moondata_store\"", "moondata_validate",
  )
  assert_contains(
    validate, "\"vectie/moonrobo/src/moondata_index\"", "moondata_validate",
  )
  assert_not_contains(
    validate, "\"vectie/moonrobo/src/moondata_api", "moondata_validate",
  )
  let repair = read_manifest("src/moondata_repair/moon.pkg")
  assert_contains(
    repair, "\"vectie/moonrobo/src/moondata_core\"", "moondata_repair",
  )
  assert_contains(
    repair, "\"vectie/moonrobo/src/moondata_store\"", "moondata_repair",
  )
  assert_contains(
    repair, "\"vectie/moonrobo/src/moondata_validate\"", "moondata_repair",
  )
  assert_not_contains(
    repair, "\"vectie/moonrobo/src/moondata_api", "moondata_repair",
  )
  assert_not_contains(
    repair, "\"vectie/moonrobo/src/moondata_import", "moondata_repair",
  )
}
