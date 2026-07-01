///|
fn has_finding(
  report : @moondata_core.ValidationReport,
  rule_id : String,
  artifact_kind : String,
) -> Bool {
  for finding in report.findings {
    if finding.rule_id == rule_id && finding.artifact_kind == artifact_kind {
      return true
    }
  }
  false
}

///|
fn remove_file_if_exists(path : String) -> Unit raise {
  if @fsx.path_exists(path) {
    @fsx.remove_file(path) catch {
      _ => fail("failed to remove stale test file: " + path)
    }
  }
}

///|
test "catalog validation passes complete local catalog" {
  let root = "target/moondata-validate-test"
  ignore(@moondata_store.initialize_root(root))
  let dataset = @moondata_core.dataset_manifest(
    "dataset-validate", "canonical", "active", 1L,
  )
  let persisted = match @moondata_store.write_dataset(root, dataset) {
    Ok(value) => value
    Err(_) => fail("write dataset failed")
  }
  let catalog = @moondata_core.moondata_catalog(root, 2L, [
    @moondata_core.catalog_entry(
      persisted.artifact_kind,
      persisted.artifact_id,
      persisted.path,
      status="active",
    ),
  ])
  ignore(@moondata_store.write_catalog(root, catalog))
  let report = match
    @moondata_validate.validate_root(root, generated_at_ms=3L) {
    Ok(value) => value
    Err(_) => fail("validate root failed")
  }
  assert_eq(report.status, "passed")
  assert_eq(report.finding_count, 0)
  assert_eq(report.catalog_entry_count, 1)
}

///|
test "root validation persists and catalogs validation report" {
  let root = "target/moondata-validate-stored-report-test"
  ignore(@moondata_store.initialize_root(root))
  remove_file_if_exists(
    @moondata_store.validation_report_path(root, "validation-32"),
  )
  let dataset = @moondata_core.dataset_manifest(
    "dataset-stored-validation", "canonical", "active", 30L,
  )
  let persisted = match @moondata_store.write_dataset(root, dataset) {
    Ok(value) => value
    Err(_) => fail("write dataset failed")
  }
  ignore(
    @moondata_store.write_catalog(
      root,
      @moondata_core.moondata_catalog(root, 31L, [
        @moondata_core.catalog_entry(
          persisted.artifact_kind,
          persisted.artifact_id,
          persisted.path,
          status=dataset.status,
        ),
      ]),
    ),
  )
  let result = match
    @moondata_validate.validate_and_write_root(root, generated_at_ms=32L) {
    Ok(value) => value
    Err(_) => fail("stored validate root failed")
  }
  assert_eq(result.validation_report_id, "validation-32")
  assert_eq(result.status, "passed")
  assert_true(@fsx.path_exists(result.report_path))
  let catalog = match @moondata_store.read_catalog(root) {
    Ok(value) => value
    Err(_) => fail("read catalog failed")
  }
  assert_eq(catalog.entry_count, 2)
  assert_true(catalog.entries[1].artifact_kind == "validation-report")
}

///|
test "catalog validation blocks inconsistent handoff dossier snapshots" {
  let root = "target/moondata-validate-handoff-dossier-test"
  ignore(@moondata_store.initialize_root(root))
  let validation = @moondata_core.validation_report(
    "validation-handoff-dossier",
    root,
    91L,
    "passed",
    2,
    0,
    0,
    0,
    [],
  )
  let validation_persisted = match
    @moondata_store.write_validation_report(root, validation) {
    Ok(value) => value
    Err(_) => fail("write handoff validation report failed")
  }
  let validation_ref = @moondata_core.moondata_ref(
    "validation-report",
    validation.validation_report_id,
    validation_persisted.path,
    "source validation",
  )
  let output_ref = @moondata_core.data_ref(
    "handoff-corrupt-output",
    "export-output",
    "moondata://exports/handoff-corrupt.jsonl",
    content_type="application/jsonl",
    byte_count=11L,
    checksum="checksum-handoff-corrupt",
  )
  let dossier : @moondata_core.HandoffDossier = {
    handoff_dossier_id: "handoff-dossier-corrupt",
    version_id: "",
    source_ready: true,
    source_readiness_status: "stale",
    source_validation_report_id: validation.validation_report_id,
    source_validation_status: "blocked",
    source_validation_generated_at_ms: 90L,
    source_validation_catalog_entry_count: 1,
    source_validation_covers_catalog: false,
    source_validation_finding_count: 1,
    source_validation_blocker_count: 1,
    source_validation_warning_count: 0,
    output_refs: [output_ref],
    output_ref_count: 0,
    total_output_byte_count: 0L,
    output_checksums: ["wrong-checksum"],
    ref_count: 99,
    refs: [validation_ref],
    validation_findings: [],
    generated_at_ms: 92L,
    summary: "corrupt handoff dossier",
  }
  let dossier_persisted = match
    @moondata_store.write_handoff_dossier(root, dossier) {
    Ok(value) => value
    Err(_) => fail("write corrupt handoff dossier failed")
  }
  ignore(
    @moondata_store.write_catalog(
      root,
      @moondata_core.moondata_catalog(root, 93L, [
        @moondata_core.catalog_entry(
          validation_persisted.artifact_kind,
          validation_persisted.artifact_id,
          validation_persisted.path,
          status=validation.status,
        ),
        @moondata_core.catalog_entry(
          dossier_persisted.artifact_kind,
          dossier_persisted.artifact_id,
          dossier_persisted.path,
          status=dossier.source_readiness_status,
        ),
      ]),
    ),
  )
  let report = match
    @moondata_validate.validate_root(root, generated_at_ms=94L) {
    Ok(value) => value
    Err(_) => fail("validate corrupt handoff dossier failed")
  }
  assert_eq(report.status, "blocked")
  assert_true(
    has_finding(report, "handoff-ref-count-mismatch", "handoff-dossier"),
  )
  assert_true(
    has_finding(report, "handoff-output-ref-count-mismatch", "handoff-dossier"),
  )
  assert_true(
    has_finding(report, "handoff-output-byte-count-mismatch", "handoff-dossier"),
  )
  assert_true(
    has_finding(report, "handoff-output-checksum-mismatch", "handoff-dossier"),
  )
  assert_true(
    has_finding(
      report, "handoff-source-validation-status-mismatch", "handoff-dossier",
    ),
  )
  assert_true(
    has_finding(
      report, "handoff-source-validation-timestamp-mismatch", "handoff-dossier",
    ),
  )
  assert_true(
    has_finding(
      report, "handoff-source-validation-catalog-count-mismatch", "handoff-dossier",
    ),
  )
  assert_true(
    has_finding(
      report, "handoff-source-validation-finding-count-mismatch", "handoff-dossier",
    ),
  )
  assert_true(
    has_finding(report, "handoff-ready-state-mismatch", "handoff-dossier"),
  )
}

///|
test "catalog validation blocks handoff output refs with missing payloads" {
  let root = "target/moondata-validate-handoff-output-payload-test"
  ignore(@moondata_store.initialize_root(root))
  let validation = @moondata_core.validation_report(
    "validation-handoff-output-payload",
    root,
    101L,
    "passed",
    1,
    0,
    0,
    0,
    [],
  )
  let validation_persisted = match
    @moondata_store.write_validation_report(root, validation) {
    Ok(value) => value
    Err(_) => fail("write handoff output validation report failed")
  }
  let validation_ref = @moondata_core.moondata_ref(
    "validation-report",
    validation.validation_report_id,
    validation_persisted.path,
    "source validation",
  )
  let output_ref = @moondata_core.data_ref(
    "handoff-missing-output",
    "export-output",
    "moondata://exports/handoff-missing.jsonl",
    content_type="application/jsonl",
    byte_count=24L,
    checksum="text-sum-v1:24:2400",
  )
  let dossier = @moondata_core.handoff_dossier(
    "handoff-output-payload",
    "",
    true,
    "ready",
    validation.validation_report_id,
    validation.status,
    validation.generated_at_ms,
    validation.catalog_entry_count,
    true,
    validation.finding_count,
    validation.blocker_count,
    validation.warning_count,
    [output_ref],
    [validation_ref],
    [],
    102L,
    "handoff dossier with missing output payload",
  )
  let dossier_persisted = match
    @moondata_store.write_handoff_dossier(root, dossier) {
    Ok(value) => value
    Err(_) => fail("write handoff output dossier failed")
  }
  ignore(
    @moondata_store.write_catalog(
      root,
      @moondata_core.moondata_catalog(root, 103L, [
        @moondata_core.catalog_entry(
          validation_persisted.artifact_kind,
          validation_persisted.artifact_id,
          validation_persisted.path,
          status=validation.status,
        ),
        @moondata_core.catalog_entry(
          dossier_persisted.artifact_kind,
          dossier_persisted.artifact_id,
          dossier_persisted.path,
          status=dossier.source_readiness_status,
        ),
      ]),
    ),
  )
  let report = match
    @moondata_validate.validate_root(root, generated_at_ms=104L) {
    Ok(value) => value
    Err(_) => fail("validate handoff output payload failed")
  }
  assert_eq(report.status, "blocked")
  assert_true(
    has_finding(report, "data-ref-missing-local-payload", "handoff-dossier"),
  )
}

///|
test "catalog validation blocks inconsistent repair run counts" {
  let root = "target/moondata-validate-repair-run-test"
  ignore(@moondata_store.initialize_root(root))
  let validation = @moondata_core.validation_report(
    "validation-repair-run",
    root,
    105L,
    "blocked",
    1,
    1,
    1,
    0,
    [
      @moondata_core.validation_finding(
        "data-ref-missing-local-payload", "blocker", "dataset", "dataset-repair-run",
        "missing payload",
      ),
    ],
  )
  let validation_persisted = match
    @moondata_store.write_validation_report(root, validation) {
    Ok(value) => value
    Err(_) => fail("write repair validation report failed")
  }
  let action = @moondata_core.repair_action(
    "repair-action-1", "missing-payload", "blocker", "dataset", "dataset-repair-run",
    "data-ref-missing-local-payload", "missing payload", "restore payload",
  )
  let run = @moondata_core.repair_run(
    "repair-run-corrupt",
    root,
    validation.validation_report_id,
    validation.status,
    106L,
    2,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    [action],
    [],
    "corrupt repair run",
  )
  let repair_persisted = match @moondata_store.write_repair_run(root, run) {
    Ok(value) => value
    Err(_) => fail("write corrupt repair run failed")
  }
  ignore(
    @moondata_store.write_catalog(
      root,
      @moondata_core.moondata_catalog(root, 107L, [
        @moondata_core.catalog_entry(
          validation_persisted.artifact_kind,
          validation_persisted.artifact_id,
          validation_persisted.path,
          status=validation.status,
        ),
        @moondata_core.catalog_entry(
          repair_persisted.artifact_kind,
          repair_persisted.artifact_id,
          repair_persisted.path,
          status=run.validation_status,
        ),
      ]),
    ),
  )
  let report = match
    @moondata_validate.validate_root(root, generated_at_ms=108L) {
    Ok(value) => value
    Err(_) => fail("validate corrupt repair run failed")
  }
  assert_eq(report.status, "blocked")
  assert_true(has_finding(report, "repair-run-count-mismatch", "repair-run"))
  assert_true(
    has_finding(
      report, "repair-run-validation-timestamp-mismatch", "repair-run",
    ),
  )
  assert_true(
    has_finding(report, "repair-run-validation-count-mismatch", "repair-run"),
  )
  assert_true(
    has_finding(report, "repair-run-validation-action-mismatch", "repair-run"),
  )
}

///|
test "catalog validation blocks repair receipts with stale action references" {
  let root = "target/moondata-validate-repair-receipt-test"
  ignore(@moondata_store.initialize_root(root))
  let validation = @moondata_core.validation_report(
    "validation-repair-receipt",
    root,
    109L,
    "blocked",
    1,
    1,
    1,
    0,
    [
      @moondata_core.validation_finding(
        "data-ref-missing-local-payload", "blocker", "dataset", "dataset-receipt",
        "missing payload",
      ),
    ],
  )
  let validation_persisted = match
    @moondata_store.write_validation_report(root, validation) {
    Ok(value) => value
    Err(_) => fail("write receipt validation failed")
  }
  let action = @moondata_core.repair_action(
    "repair-action-live",
    "missing-payload",
    "blocker",
    "dataset",
    "dataset-receipt",
    "data-ref-missing-local-payload",
    "missing payload",
    "restore payload",
    operation_kind="restore-or-remove-payload-ref",
    target_ref="dataset:dataset-receipt",
  )
  let run = @moondata_core.repair_run(
    "repair-run-receipt",
    root,
    validation.validation_report_id,
    validation.status,
    109L,
    1,
    1,
    0,
    1,
    0,
    0,
    0,
    0,
    0,
    0,
    [action],
    [],
    "repair receipt run",
  )
  let repair_persisted = match @moondata_store.write_repair_run(root, run) {
    Ok(value) => value
    Err(_) => fail("write receipt repair run failed")
  }
  let receipt = @moondata_core.repair_receipt(
    "repair-receipt-stale",
    run.repair_run_id,
    "repair-action-stale",
    action.operation_kind,
    "dataset:wrong-target",
    "applied",
    "operator",
    110L,
    validation.validation_report_id,
    summary="stale receipt",
  )
  let receipt_persisted = match
    @moondata_store.write_repair_receipt(root, receipt) {
    Ok(value) => value
    Err(_) => fail("write stale repair receipt failed")
  }
  ignore(
    @moondata_store.write_catalog(
      root,
      @moondata_core.moondata_catalog(root, 111L, [
        @moondata_core.catalog_entry(
          validation_persisted.artifact_kind,
          validation_persisted.artifact_id,
          validation_persisted.path,
          status=validation.status,
        ),
        @moondata_core.catalog_entry(
          repair_persisted.artifact_kind,
          repair_persisted.artifact_id,
          repair_persisted.path,
          status=run.validation_status,
        ),
        @moondata_core.catalog_entry(
          receipt_persisted.artifact_kind,
          receipt_persisted.artifact_id,
          receipt_persisted.path,
          status=receipt.status,
        ),
      ]),
    ),
  )
  let report = match
    @moondata_validate.validate_root(root, generated_at_ms=112L) {
    Ok(value) => value
    Err(_) => fail("validate stale repair receipt failed")
  }
  assert_eq(report.status, "blocked")
  assert_true(
    has_finding(report, "repair-receipt-action-missing", "repair-receipt"),
  )
}

///|
test "catalog validation blocks robot model refs with missing payloads" {
  let root = "target/moondata-validate-robot-model-payload-test"
  ignore(@moondata_store.initialize_root(root))
  let urdf_ref = @moondata_core.data_ref(
    "robot-model-missing-urdf",
    "urdf",
    "moondata://media/robot_models/missing/robot.urdf",
    content_type="application/xml",
    byte_count=20L,
    checksum="text-sum-v1:20:601",
  )
  let model = @moondata_core.robot_model_manifest(
    "robot-model-missing-payload",
    "robot-validate",
    "urdf",
    "active",
    urdf_ref,
    111L,
    link_names=["base_link"],
    joint_names=["hip_yaw"],
    validation_status="pending",
    summary="missing robot model payload",
  )
  let persisted = match @moondata_store.write_robot_model(root, model) {
    Ok(value) => value
    Err(_) => fail("write robot model failed")
  }
  ignore(
    @moondata_store.write_catalog(
      root,
      @moondata_core.moondata_catalog(root, 112L, [
        @moondata_core.catalog_entry(
          persisted.artifact_kind,
          persisted.artifact_id,
          persisted.path,
          status=model.status,
        ),
      ]),
    ),
  )
  let report = match
    @moondata_validate.validate_root(root, generated_at_ms=113L) {
    Ok(value) => value
    Err(_) => fail("validate robot model payload failed")
  }
  assert_eq(report.status, "blocked")
  assert_true(
    has_finding(report, "data-ref-missing-local-payload", "robot-model"),
  )
}

///|
test "catalog validation blocks data refs that escape moondata root" {
  let root = "target/moondata-validate-unsafe-data-ref-test"
  ignore(@moondata_store.initialize_root(root))
  let urdf_ref = @moondata_core.data_ref(
    "robot-model-unsafe-urdf",
    "urdf",
    "moondata://../outside/robot.urdf",
    content_type="application/xml",
  )
  let model = @moondata_core.robot_model_manifest(
    "robot-model-unsafe-ref",
    "robot-validate",
    "urdf",
    "active",
    urdf_ref,
    113L,
    validation_status="pending",
    summary="unsafe robot model payload",
  )
  let persisted = match @moondata_store.write_robot_model(root, model) {
    Ok(value) => value
    Err(_) => fail("write unsafe robot model failed")
  }
  ignore(
    @moondata_store.write_catalog(
      root,
      @moondata_core.moondata_catalog(root, 114L, [
        @moondata_core.catalog_entry(
          persisted.artifact_kind,
          persisted.artifact_id,
          persisted.path,
          status=model.status,
        ),
      ]),
    ),
  )
  let report = match
    @moondata_validate.validate_root(root, generated_at_ms=115L) {
    Ok(value) => value
    Err(_) => fail("validate unsafe data ref failed")
  }
  assert_eq(report.status, "blocked")
  assert_true(has_finding(report, "data-ref-unsafe-local-uri", "robot-model"))
}

///|
test "catalog validation accepts robot model binary refs with byte checksums" {
  let root = "target/moondata-validate-robot-model-binary-payload-test"
  ignore(@moondata_store.initialize_root(root))
  @fsx.create_dir(root + "/media/robot_models/binary") catch {
    _ => ()
  }
  @fsx.create_dir(root + "/media/robot_models/binary/meshes") catch {
    _ => ()
  }
  let urdf_text = "<robot name=\"binary\"><link name=\"base_link\"/></robot>"
  @fsx.write_string_to_file(
    root + "/media/robot_models/binary/robot.urdf",
    urdf_text,
  ) catch {
    _ => fail("failed to write robot model binary URDF")
  }
  let mesh_bytes = Bytes::from_array([
    (255).to_byte(),
    (0).to_byte(),
    (3).to_byte(),
  ])
  @fsx.write_bytes_to_file(
    root + "/media/robot_models/binary/meshes/base.stl",
    mesh_bytes,
  ) catch {
    _ => fail("failed to write robot model binary mesh")
  }
  let urdf_ref = @moondata_core.data_ref(
    "robot-model-binary-urdf",
    "urdf",
    "moondata://media/robot_models/binary/robot.urdf",
    content_type="application/xml",
    byte_count=urdf_text.length().to_int64(),
    checksum=@moondata_core.text_checksum(urdf_text),
  )
  let mesh_ref = @moondata_core.data_ref(
    "robot-model-binary-mesh",
    "stl",
    "moondata://media/robot_models/binary/meshes/base.stl",
    content_type="model/stl",
    byte_count=3L,
    checksum=@moondata_core.bytes_checksum(mesh_bytes),
  )
  let model = @moondata_core.robot_model_manifest(
    "robot-model-binary-payload",
    "robot-validate",
    "urdf",
    "active",
    urdf_ref,
    114L,
    mesh_refs=[mesh_ref],
    link_names=["base_link"],
    validation_status="pending",
    summary="binary robot model payload",
  )
  let persisted = match @moondata_store.write_robot_model(root, model) {
    Ok(value) => value
    Err(_) => fail("write binary robot model failed")
  }
  ignore(
    @moondata_store.write_catalog(
      root,
      @moondata_core.moondata_catalog(root, 115L, [
        @moondata_core.catalog_entry(
          persisted.artifact_kind,
          persisted.artifact_id,
          persisted.path,
          status=model.status,
        ),
      ]),
    ),
  )
  let report = match
    @moondata_validate.validate_root(root, generated_at_ms=116L) {
    Ok(value) => value
    Err(_) => fail("validate binary robot model payload failed")
  }
  assert_eq(report.status, "passed")
}

///|
test "catalog validation blocks robot model URDF external asset refs" {
  let root = "target/moondata-validate-robot-model-external-asset-test"
  ignore(@moondata_store.initialize_root(root))
  @fsx.create_dir(root + "/media/robot_models/external") catch {
    _ => ()
  }
  let urdf_text = "<robot name=\"external\"><link name=\"base_link\"><visual><geometry><mesh filename=\"package://fixture_pkg/meshes/base.stl\"/></geometry></visual><collision><geometry><mesh filename=\"file:///tmp/base.stl\"/></geometry></collision></link></robot>"
  @fsx.write_string_to_file(
    root + "/media/robot_models/external/robot.urdf",
    urdf_text,
  ) catch {
    _ => fail("failed to write external robot model URDF")
  }
  let urdf_ref = @moondata_core.data_ref(
    "robot-model-external-urdf",
    "urdf",
    "moondata://media/robot_models/external/robot.urdf",
    content_type="application/xml",
    byte_count=urdf_text.length().to_int64(),
    checksum=@moondata_core.text_checksum(urdf_text),
  )
  let model = @moondata_core.robot_model_manifest(
    "robot-model-external-asset",
    "robot-validate",
    "urdf",
    "active",
    urdf_ref,
    117L,
    link_names=["base_link"],
    validation_status="pending",
    summary="external robot model asset refs",
  )
  let persisted = match @moondata_store.write_robot_model(root, model) {
    Ok(value) => value
    Err(_) => fail("write external robot model failed")
  }
  ignore(
    @moondata_store.write_catalog(
      root,
      @moondata_core.moondata_catalog(root, 118L, [
        @moondata_core.catalog_entry(
          persisted.artifact_kind,
          persisted.artifact_id,
          persisted.path,
          status=model.status,
        ),
      ]),
    ),
  )
  let report = match
    @moondata_validate.validate_root(root, generated_at_ms=119L) {
    Ok(value) => value
    Err(_) => fail("validate external robot model asset refs failed")
  }
  assert_eq(report.status, "blocked")
  assert_true(
    has_finding(report, "robot-model-external-package-uri", "robot-model"),
  )
  assert_true(
    has_finding(report, "robot-model-external-file-uri", "robot-model"),
  )
}

///|
test "catalog validation blocks undeclared robot model URDF MoonData asset refs" {
  let root = "target/moondata-validate-robot-model-hidden-asset-test"
  ignore(@moondata_store.initialize_root(root))
  @fsx.create_dir(root + "/media/robot_models/hidden") catch {
    _ => ()
  }
  @fsx.create_dir(root + "/media/robot_models/hidden/meshes") catch {
    _ => ()
  }
  let urdf_text = "<robot name=\"hidden\"><link name=\"base_link\"><visual><geometry><mesh filename=\"moondata://media/robot_models/hidden/meshes/base.stl\"/></geometry></visual></link></robot>"
  @fsx.write_string_to_file(
    root + "/media/robot_models/hidden/robot.urdf",
    urdf_text,
  ) catch {
    _ => fail("failed to write hidden robot model URDF")
  }
  @fsx.write_string_to_file(
    root + "/media/robot_models/hidden/meshes/base.stl",
    "solid hidden\n",
  ) catch {
    _ => fail("failed to write hidden robot model mesh")
  }
  let urdf_ref = @moondata_core.data_ref(
    "robot-model-hidden-urdf",
    "urdf",
    "moondata://media/robot_models/hidden/robot.urdf",
    content_type="application/xml",
    byte_count=urdf_text.length().to_int64(),
    checksum=@moondata_core.text_checksum(urdf_text),
  )
  let model = @moondata_core.robot_model_manifest(
    "robot-model-hidden-asset",
    "robot-validate",
    "urdf",
    "active",
    urdf_ref,
    120L,
    link_names=["base_link"],
    validation_status="pending",
    summary="hidden robot model asset refs",
  )
  let persisted = match @moondata_store.write_robot_model(root, model) {
    Ok(value) => value
    Err(_) => fail("write hidden robot model failed")
  }
  ignore(
    @moondata_store.write_catalog(
      root,
      @moondata_core.moondata_catalog(root, 121L, [
        @moondata_core.catalog_entry(
          persisted.artifact_kind,
          persisted.artifact_id,
          persisted.path,
          status=model.status,
        ),
      ]),
    ),
  )
  let report = match
    @moondata_validate.validate_root(root, generated_at_ms=122L) {
    Ok(value) => value
    Err(_) => fail("validate hidden robot model asset refs failed")
  }
  assert_eq(report.status, "blocked")
  assert_true(
    has_finding(report, "robot-model-undeclared-asset-uri", "robot-model"),
  )
}

///|
test "catalog validation blocks duplicate and missing manifests" {
  let catalog = @moondata_core.moondata_catalog("moondata", 4L, [
    @moondata_core.catalog_entry("dataset", "dataset-a", "moondata://missing"),
    @moondata_core.catalog_entry(
      "dataset", "dataset-a", "moondata://missing-again",
    ),
  ])
  let report = @moondata_validate.validate_catalog(
    "moondata",
    catalog,
    generated_at_ms=5L,
    check_files=true,
  )
  assert_eq(report.status, "blocked")
  assert_true(report.blocker_count > 0)
  assert_true(report.warning_count > 0)
}

///|
test "catalog validation blocks noncanonical manifest paths" {
  let root = "target/moondata-validate-canonical-path-test"
  ignore(@moondata_store.initialize_root(root))
  let quality = @moondata_core.quality_run(
    "quality-canonical-path",
    "dataset-canonical-path",
    [],
    6L,
    [],
  )
  let persisted = match @moondata_store.write_quality_run(root, quality) {
    Ok(value) => value
    Err(_) => fail("write quality failed")
  }
  let catalog = @moondata_core.moondata_catalog(root, 7L, [
    @moondata_core.catalog_entry(
      persisted.artifact_kind,
      "quality-canonical-path-alias",
      persisted.path,
      status=quality.status,
    ),
  ])
  ignore(@moondata_store.write_catalog(root, catalog))
  let report = match
    @moondata_validate.validate_root(root, generated_at_ms=8L) {
    Ok(value) => value
    Err(_) => fail("validate root failed")
  }
  assert_eq(report.status, "blocked")
  assert_true(
    has_finding(report, "catalog-entry-noncanonical-path", "quality-run"),
  )
}

///|
test "root validation blocks stored manifests missing from catalog" {
  let root = "target/moondata-validate-catalog-completeness-test"
  ignore(@moondata_store.initialize_root(root))
  let source = @moondata_core.data_source(
    "source-uncataloged", "import", "uncataloged source", "robot-validate", "bridge-validate",
    "file:///tmp/uncataloged.csv", 6L,
  )
  ignore(@moondata_store.write_source(root, source))
  ignore(
    @moondata_store.write_catalog(
      root,
      @moondata_core.moondata_catalog(root, 7L, []),
    ),
  )
  let report = match
    @moondata_validate.validate_root(root, generated_at_ms=8L) {
    Ok(value) => value
    Err(_) => fail("validate root failed")
  }
  assert_eq(report.status, "blocked")
  assert_true(has_finding(report, "manifest-missing-catalog-entry", "source"))
}

///|
test "catalog validation blocks annotation target indexes without annotation set" {
  let root = "target/moondata-validate-annotation-index-test"
  ignore(@moondata_store.initialize_root(root))
  let index = @moondata_core.annotation_target_index(
    "annotation-target-validate",
    "missing-annotation-set",
    [],
    "reviewer-validate",
    "accepted",
    9L,
  )
  let persisted = match
    @moondata_store.write_annotation_target_index(root, index) {
    Ok(value) => value
    Err(_) => fail("write annotation target index failed")
  }
  ignore(
    @moondata_store.write_catalog(
      root,
      @moondata_core.moondata_catalog(root, 10L, [
        @moondata_core.catalog_entry(
          persisted.artifact_kind,
          persisted.artifact_id,
          persisted.path,
          status=index.status,
        ),
      ]),
    ),
  )
  let report = match
    @moondata_validate.validate_root(root, generated_at_ms=11L) {
    Ok(value) => value
    Err(_) => fail("validate root failed")
  }
  assert_eq(report.status, "blocked")
  assert_true(
    has_finding(
      report, "moondata-ref-missing-catalog-entry", "annotation-target-index",
    ),
  )
}

///|
test "catalog validation blocks annotation sets without target indexes" {
  let root = "target/moondata-validate-missing-annotation-index-test"
  ignore(@moondata_store.initialize_root(root))
  let annotation = @moondata_core.annotation_set(
    "annotation-missing-index",
    [],
    [
      @moondata_core.annotation_label(
        "curation",
        "accepted",
        source="moondata-validate-test",
      ),
    ],
    "reviewer-validate",
    12L,
    status="accepted",
  )
  let persisted = match @moondata_store.write_annotation_set(root, annotation) {
    Ok(value) => value
    Err(_) => fail("write annotation failed")
  }
  ignore(
    @moondata_store.write_catalog(
      root,
      @moondata_core.moondata_catalog(root, 13L, [
        @moondata_core.catalog_entry(
          persisted.artifact_kind,
          persisted.artifact_id,
          persisted.path,
          status=annotation.status,
        ),
      ]),
    ),
  )
  let report = match
    @moondata_validate.validate_root(root, generated_at_ms=14L) {
    Ok(value) => value
    Err(_) => fail("validate root failed")
  }
  assert_eq(report.status, "blocked")
  assert_true(
    has_finding(report, "annotation-target-index-missing", "annotation-set"),
  )
}

///|
test "catalog validation blocks duplicate annotation target indexes" {
  let root = "target/moondata-validate-duplicate-annotation-index-test"
  ignore(@moondata_store.initialize_root(root))
  let annotation = @moondata_core.annotation_set(
    "annotation-duplicate-index",
    [],
    [
      @moondata_core.annotation_label(
        "curation",
        "accepted",
        source="moondata-validate-test",
      ),
    ],
    "reviewer-validate",
    15L,
    status="accepted",
  )
  let index_a = @moondata_core.annotation_target_index(
    "annotation-target-duplicate-a",
    annotation.annotation_set_id,
    annotation.target_refs,
    annotation.reviewer,
    annotation.status,
    annotation.created_at_ms,
    label_keys=["curation"],
    label_values=["accepted"],
  )
  let index_b = @moondata_core.annotation_target_index(
    "annotation-target-duplicate-b",
    annotation.annotation_set_id,
    annotation.target_refs,
    annotation.reviewer,
    annotation.status,
    annotation.created_at_ms,
    label_keys=["curation"],
    label_values=["accepted"],
  )
  let annotation_persisted = match
    @moondata_store.write_annotation_set(root, annotation) {
    Ok(value) => value
    Err(_) => fail("write annotation failed")
  }
  let index_a_persisted = match
    @moondata_store.write_annotation_target_index(root, index_a) {
    Ok(value) => value
    Err(_) => fail("write annotation target index a failed")
  }
  let index_b_persisted = match
    @moondata_store.write_annotation_target_index(root, index_b) {
    Ok(value) => value
    Err(_) => fail("write annotation target index b failed")
  }
  ignore(
    @moondata_store.write_catalog(
      root,
      @moondata_core.moondata_catalog(root, 16L, [
        @moondata_core.catalog_entry(
          annotation_persisted.artifact_kind,
          annotation_persisted.artifact_id,
          annotation_persisted.path,
          status=annotation.status,
        ),
        @moondata_core.catalog_entry(
          index_a_persisted.artifact_kind,
          index_a_persisted.artifact_id,
          index_a_persisted.path,
          status=index_a.status,
        ),
        @moondata_core.catalog_entry(
          index_b_persisted.artifact_kind,
          index_b_persisted.artifact_id,
          index_b_persisted.path,
          status=index_b.status,
        ),
      ]),
    ),
  )
  let report = match
    @moondata_validate.validate_root(root, generated_at_ms=17L) {
    Ok(value) => value
    Err(_) => fail("validate root failed")
  }
  assert_eq(report.status, "blocked")
  assert_true(
    has_finding(report, "annotation-target-index-duplicate", "annotation-set"),
  )
}

///|
test "catalog validation blocks stale annotation target indexes" {
  let root = "target/moondata-validate-stale-annotation-index-test"
  ignore(@moondata_store.initialize_root(root))
  let annotation = @moondata_core.annotation_set(
    "annotation-stale-index",
    [],
    [
      @moondata_core.annotation_label(
        "curation",
        "accepted",
        source="moondata-validate-test",
      ),
    ],
    "reviewer-validate",
    12L,
    status="accepted",
  )
  let index = @moondata_core.annotation_target_index(
    "annotation-target-stale",
    annotation.annotation_set_id,
    annotation.target_refs,
    annotation.reviewer,
    annotation.status,
    annotation.created_at_ms,
    label_keys=["curation"],
    label_values=["rejected"],
  )
  let annotation_persisted = match
    @moondata_store.write_annotation_set(root, annotation) {
    Ok(value) => value
    Err(_) => fail("write annotation failed")
  }
  let index_persisted = match
    @moondata_store.write_annotation_target_index(root, index) {
    Ok(value) => value
    Err(_) => fail("write annotation target index failed")
  }
  ignore(
    @moondata_store.write_catalog(
      root,
      @moondata_core.moondata_catalog(root, 13L, [
        @moondata_core.catalog_entry(
          annotation_persisted.artifact_kind,
          annotation_persisted.artifact_id,
          annotation_persisted.path,
          status=annotation.status,
        ),
        @moondata_core.catalog_entry(
          index_persisted.artifact_kind,
          index_persisted.artifact_id,
          index_persisted.path,
          status=index.status,
        ),
      ]),
    ),
  )
  let report = match
    @moondata_validate.validate_root(root, generated_at_ms=14L) {
    Ok(value) => value
    Err(_) => fail("validate root failed")
  }
  assert_eq(report.status, "blocked")
  assert_true(
    has_finding(
      report, "annotation-target-index-stale", "annotation-target-index",
    ),
  )
}

///|
test "catalog validation blocks missing local data ref payloads" {
  let root = "target/moondata-validate-payload-test"
  ignore(@moondata_store.initialize_root(root))
  let dataset = @moondata_core.dataset_manifest(
    "dataset-missing-payload",
    "raw",
    "imported",
    6L,
    data_refs=[
      @moondata_core.data_ref(
        "payload-missing",
        "raw-file",
        "moondata://media/imports/dataset-missing-payload/missing.json",
        content_type="application/json",
      ),
    ],
  )
  let persisted = match @moondata_store.write_dataset(root, dataset) {
    Ok(value) => value
    Err(_) => fail("write dataset failed")
  }
  ignore(
    @moondata_store.write_catalog(
      root,
      @moondata_core.moondata_catalog(root, 7L, [
        @moondata_core.catalog_entry(
          persisted.artifact_kind,
          persisted.artifact_id,
          persisted.path,
          status="imported",
        ),
      ]),
    ),
  )
  let report = match
    @moondata_validate.validate_root(root, generated_at_ms=8L) {
    Ok(value) => value
    Err(_) => fail("validate root failed")
  }
  assert_eq(report.status, "blocked")
  assert_eq(report.findings[0].rule_id, "data-ref-missing-local-payload")
}

///|
test "catalog validation blocks external data ref URIs" {
  let root = "target/moondata-validate-external-data-ref-test"
  ignore(@moondata_store.initialize_root(root))
  let dataset = @moondata_core.dataset_manifest(
    "dataset-external-data-ref",
    "raw",
    "imported",
    183L,
    data_refs=[
      @moondata_core.data_ref(
        "payload-external",
        "raw-file",
        "file:///tmp/moondata-external.json",
        content_type="application/json",
      ),
    ],
  )
  let persisted = match @moondata_store.write_dataset(root, dataset) {
    Ok(value) => value
    Err(_) => fail("write external data ref dataset failed")
  }
  ignore(
    @moondata_store.write_catalog(
      root,
      @moondata_core.moondata_catalog(root, 184L, [
        @moondata_core.catalog_entry(
          persisted.artifact_kind,
          persisted.artifact_id,
          persisted.path,
          status=dataset.status,
        ),
      ]),
    ),
  )
  let report = match
    @moondata_validate.validate_root(root, generated_at_ms=185L) {
    Ok(value) => value
    Err(_) => fail("validate external data ref failed")
  }
  assert_eq(report.status, "blocked")
  assert_true(has_finding(report, "data-ref-external-uri", "dataset"))
}

///|
test "catalog validation blocks unmanaged local payload files" {
  let root = "target/moondata-validate-unmanaged-payload-test"
  ignore(@moondata_store.initialize_root(root))
  @fsx.create_dir(root + "/media/imports/unmanaged") catch {
    _ => ()
  }
  @fsx.write_string_to_file(
    root + "/media/imports/unmanaged/extra.json",
    "{\"unmanaged\":true}\n",
  ) catch {
    _ => fail("write unmanaged payload failed")
  }
  let dataset = @moondata_core.dataset_manifest(
    "dataset-unmanaged-payload", "raw", "imported", 174L,
  )
  let persisted = match @moondata_store.write_dataset(root, dataset) {
    Ok(value) => value
    Err(_) => fail("write unmanaged payload dataset failed")
  }
  ignore(
    @moondata_store.write_catalog(
      root,
      @moondata_core.moondata_catalog(root, 175L, [
        @moondata_core.catalog_entry(
          persisted.artifact_kind,
          persisted.artifact_id,
          persisted.path,
          status=dataset.status,
        ),
      ]),
    ),
  )
  let report = match
    @moondata_validate.validate_root(root, generated_at_ms=176L) {
    Ok(value) => value
    Err(_) => fail("validate unmanaged payload failed")
  }
  assert_eq(report.status, "blocked")
  assert_true(
    has_finding(report, "moondata-unmanaged-local-payload", "payload"),
  )
}

///|
test "catalog validation blocks data refs that point to manifest files" {
  let root = "target/moondata-validate-data-ref-manifest-surface-test"
  ignore(@moondata_store.initialize_root(root))
  let dataset = @moondata_core.dataset_manifest(
    "dataset-manifest-surface",
    "raw",
    "imported",
    177L,
    data_refs=[
      @moondata_core.data_ref(
        "payload-manifest-surface",
        "raw-file",
        "moondata://datasets/raw/dataset-manifest-surface.json",
        content_type="application/json",
      ),
    ],
  )
  let persisted = match @moondata_store.write_dataset(root, dataset) {
    Ok(value) => value
    Err(_) => fail("write manifest surface dataset failed")
  }
  ignore(
    @moondata_store.write_catalog(
      root,
      @moondata_core.moondata_catalog(root, 178L, [
        @moondata_core.catalog_entry(
          persisted.artifact_kind,
          persisted.artifact_id,
          persisted.path,
          status=dataset.status,
        ),
      ]),
    ),
  )
  let report = match
    @moondata_validate.validate_root(root, generated_at_ms=179L) {
    Ok(value) => value
    Err(_) => fail("validate manifest surface data ref failed")
  }
  assert_eq(report.status, "blocked")
  assert_true(has_finding(report, "data-ref-points-to-manifest", "dataset"))
}

///|
test "catalog validation blocks local data refs outside payload roots" {
  let root = "target/moondata-validate-data-ref-payload-root-test"
  ignore(@moondata_store.initialize_root(root))
  @fsx.create_dir(root + "/scratch") catch {
    _ => ()
  }
  let body = "{\"payload\":true}\n"
  @fsx.write_string_to_file(root + "/scratch/payload.json", body) catch {
    _ => fail("write non-payload-root data ref payload failed")
  }
  let dataset = @moondata_core.dataset_manifest(
    "dataset-payload-root",
    "raw",
    "imported",
    180L,
    data_refs=[
      @moondata_core.data_ref(
        "payload-outside-root",
        "raw-file",
        "moondata://scratch/payload.json",
        content_type="application/json",
        byte_count=body.length().to_int64(),
        checksum=@moondata_core.text_checksum(body),
      ),
    ],
  )
  let persisted = match @moondata_store.write_dataset(root, dataset) {
    Ok(value) => value
    Err(_) => fail("write payload root dataset failed")
  }
  ignore(
    @moondata_store.write_catalog(
      root,
      @moondata_core.moondata_catalog(root, 181L, [
        @moondata_core.catalog_entry(
          persisted.artifact_kind,
          persisted.artifact_id,
          persisted.path,
          status=dataset.status,
        ),
      ]),
    ),
  )
  let report = match
    @moondata_validate.validate_root(root, generated_at_ms=182L) {
    Ok(value) => value
    Err(_) => fail("validate non-payload-root data ref failed")
  }
  assert_eq(report.status, "blocked")
  assert_true(has_finding(report, "data-ref-outside-payload-root", "dataset"))
}

///|
test "catalog validation checks export manifest output refs" {
  let root = "target/moondata-validate-export-test"
  ignore(@moondata_store.initialize_root(root))
  let version = @moondata_core.dataset_version(
    "version-export-validate",
    "dataset-export-validate",
    "accepted",
    9L,
    accepted_episode_ids=["episode-export-validate"],
    quality_run_ids=["qr-export-validate"],
  )
  let output = @moondata_core.data_ref(
    "export-output-validate",
    "export-jsonl",
    "moondata://exports/export-output-validate.jsonl",
    content_type="application/jsonl",
  )
  let manifest = @moondata_core.export_manifest(
    "export-validate",
    version.version_id,
    version.dataset_id,
    "jsonl",
    "{\"payload\":\"frame.payload_ref\"}",
    [output],
    10L,
    quality_run_ids=version.quality_run_ids,
  )
  let persisted = match @moondata_store.write_export_manifest(root, manifest) {
    Ok(value) => value
    Err(_) => fail("write export manifest failed")
  }
  ignore(
    @moondata_store.write_catalog(
      root,
      @moondata_core.moondata_catalog(root, 11L, [
        @moondata_core.catalog_entry(
          persisted.artifact_kind,
          persisted.artifact_id,
          persisted.path,
          status=manifest.status,
        ),
      ]),
    ),
  )
  let report = match
    @moondata_validate.validate_root(root, generated_at_ms=12L) {
    Ok(value) => value
    Err(_) => fail("validate root failed")
  }
  assert_eq(report.status, "blocked")
  assert_eq(report.findings[0].artifact_kind, "export-manifest")
  assert_eq(report.findings[0].rule_id, "data-ref-missing-local-payload")
}

///|
test "catalog validation blocks ready exports without replay coverage" {
  let root = "target/moondata-validate-export-replay-coverage-test"
  ignore(@moondata_store.initialize_root(root))
  @fsx.write_string_to_file(root + "/exports/export-no-replay.jsonl", "{}\n") catch {
    _ => fail("write no-replay export payload failed")
  }
  let dataset = @moondata_core.dataset_manifest(
    "dataset-no-replay",
    "curated",
    "active",
    49L,
    episode_ids=["episode-no-replay"],
  )
  let episode = @moondata_core.episode_manifest(
    "episode-no-replay",
    dataset.dataset_id,
    "robot-no-replay",
    "bridge-no-replay",
    "session-no-replay",
    "stopped",
    50L,
    stopped_at_ms=Some(51L),
  )
  let version = @moondata_core.dataset_version(
    "version-no-replay",
    dataset.dataset_id,
    "accepted",
    52L,
    accepted_episode_ids=dataset.episode_ids,
  )
  let output = @moondata_core.data_ref(
    "export-no-replay-output",
    "export-jsonl",
    "moondata://exports/export-no-replay.jsonl",
    byte_count=3L,
    checksum=@moondata_core.text_checksum("{}\n"),
  )
  let export_manifest = @moondata_core.export_manifest(
    "export-no-replay",
    version.version_id,
    dataset.dataset_id,
    "jsonl",
    "{\"payload\":\"frame.payload_ref\"}",
    [output],
    53L,
  )
  let dataset_persisted = match @moondata_store.write_dataset(root, dataset) {
    Ok(value) => value
    Err(_) => fail("write no-replay dataset failed")
  }
  let episode_persisted = match @moondata_store.write_episode(root, episode) {
    Ok(value) => value
    Err(_) => fail("write no-replay episode failed")
  }
  let version_persisted = match
    @moondata_store.write_dataset_version(root, version) {
    Ok(value) => value
    Err(_) => fail("write no-replay version failed")
  }
  let export_persisted = match
    @moondata_store.write_export_manifest(root, export_manifest) {
    Ok(value) => value
    Err(_) => fail("write no-replay export failed")
  }
  ignore(
    @moondata_store.write_catalog(
      root,
      @moondata_core.moondata_catalog(root, 54L, [
        @moondata_core.catalog_entry(
          dataset_persisted.artifact_kind,
          dataset_persisted.artifact_id,
          dataset_persisted.path,
          status=dataset.status,
        ),
        @moondata_core.catalog_entry(
          episode_persisted.artifact_kind,
          episode_persisted.artifact_id,
          episode_persisted.path,
          status=episode.status,
        ),
        @moondata_core.catalog_entry(
          version_persisted.artifact_kind,
          version_persisted.artifact_id,
          version_persisted.path,
          status=version.status,
        ),
        @moondata_core.catalog_entry(
          export_persisted.artifact_kind,
          export_persisted.artifact_id,
          export_persisted.path,
          status=export_manifest.status,
        ),
      ]),
    ),
  )
  let report = match
    @moondata_validate.validate_root(root, generated_at_ms=55L) {
    Ok(value) => value
    Err(_) => fail("validate no-replay export failed")
  }
  assert_eq(report.status, "blocked")
  assert_true(
    has_finding(report, "export-replay-coverage-missing", "export-manifest"),
  )
}

///|
test "catalog validation passes ready export with replay coverage" {
  let root = "target/moondata-validate-export-replay-pass-test"
  ignore(@moondata_store.initialize_root(root))
  @fsx.create_dir(root + "/media/replays") catch {
    _ => ()
  }
  @fsx.write_string_to_file(root + "/exports/export-with-replay.jsonl", "{}\n") catch {
    _ => fail("write replay-covered export payload failed")
  }
  @fsx.write_string_to_file(
    root + "/media/replays/replay-with-export.json",
    "{\"ok\":true}\n",
  ) catch {
    _ => fail("write replay payload failed")
  }
  let dataset = @moondata_core.dataset_manifest(
    "dataset-with-replay",
    "curated",
    "active",
    56L,
    episode_ids=["episode-with-replay"],
  )
  let episode = @moondata_core.episode_manifest(
    "episode-with-replay",
    dataset.dataset_id,
    "robot-with-replay",
    "bridge-with-replay",
    "session-with-replay",
    "stopped",
    57L,
    stopped_at_ms=Some(58L),
  )
  let version = @moondata_core.dataset_version(
    "version-with-replay",
    dataset.dataset_id,
    "accepted",
    59L,
    accepted_episode_ids=dataset.episode_ids,
  )
  let output = @moondata_core.data_ref(
    "export-with-replay-output",
    "export-jsonl",
    "moondata://exports/export-with-replay.jsonl",
    byte_count=3L,
    checksum=@moondata_core.text_checksum("{}\n"),
  )
  let replay_payload = @moondata_core.data_ref(
    "replay-with-export-output",
    "replay-payload",
    "moondata://media/replays/replay-with-export.json",
    byte_count=12L,
    checksum=@moondata_core.text_checksum("{\"ok\":true}\n"),
  )
  let version_ref = @moondata_core.moondata_ref(
    "dataset-version",
    version.version_id,
    @moondata_store.dataset_version_path(root, version.version_id),
    "replay-covered version",
  )
  let episode_ref = @moondata_core.moondata_ref(
    "episode",
    episode.episode_id,
    @moondata_store.episode_path(root, episode.episode_id),
    "replay-covered episode",
  )
  let replay = @moondata_core.replay_artifact(
    "replay-with-export",
    dataset.dataset_id,
    version.accepted_episode_ids,
    60L,
    source_refs=[version_ref, episode_ref],
    generated_refs=[replay_payload],
  )
  let export_manifest = @moondata_core.export_manifest(
    "export-with-replay",
    version.version_id,
    dataset.dataset_id,
    "jsonl",
    "{\"payload\":\"frame.payload_ref\"}",
    [output],
    61L,
  )
  let dataset_persisted = match @moondata_store.write_dataset(root, dataset) {
    Ok(value) => value
    Err(_) => fail("write replay-covered dataset failed")
  }
  let episode_persisted = match @moondata_store.write_episode(root, episode) {
    Ok(value) => value
    Err(_) => fail("write replay-covered episode failed")
  }
  let version_persisted = match
    @moondata_store.write_dataset_version(root, version) {
    Ok(value) => value
    Err(_) => fail("write replay-covered version failed")
  }
  let replay_persisted = match
    @moondata_store.write_replay_artifact(root, replay) {
    Ok(value) => value
    Err(_) => fail("write replay-covered replay failed")
  }
  let export_persisted = match
    @moondata_store.write_export_manifest(root, export_manifest) {
    Ok(value) => value
    Err(_) => fail("write replay-covered export failed")
  }
  ignore(
    @moondata_store.write_catalog(
      root,
      @moondata_core.moondata_catalog(root, 62L, [
        @moondata_core.catalog_entry(
          dataset_persisted.artifact_kind,
          dataset_persisted.artifact_id,
          dataset_persisted.path,
          status=dataset.status,
        ),
        @moondata_core.catalog_entry(
          episode_persisted.artifact_kind,
          episode_persisted.artifact_id,
          episode_persisted.path,
          status=episode.status,
        ),
        @moondata_core.catalog_entry(
          version_persisted.artifact_kind,
          version_persisted.artifact_id,
          version_persisted.path,
          status=version.status,
        ),
        @moondata_core.catalog_entry(
          replay_persisted.artifact_kind,
          replay_persisted.artifact_id,
          replay_persisted.path,
          status="ready",
        ),
        @moondata_core.catalog_entry(
          export_persisted.artifact_kind,
          export_persisted.artifact_id,
          export_persisted.path,
          status=export_manifest.status,
        ),
      ]),
    ),
  )
  let report = match
    @moondata_validate.validate_root(root, generated_at_ms=63L) {
    Ok(value) => value
    Err(_) => fail("validate replay-covered export failed")
  }
  assert_eq(report.status, "passed")
  assert_eq(report.finding_count, 0)
}

///|
test "catalog validation blocks local payload checksum drift" {
  let root = "target/moondata-validate-checksum-test"
  ignore(@moondata_store.initialize_root(root))
  @fsx.create_dir(root + "/media/imports/dataset-checksum") catch {
    _ => ()
  }
  @fsx.write_string_to_file(
    root + "/media/imports/dataset-checksum/payload.json",
    "{\"t\":2}",
  ) catch {
    _ => fail("write payload failed")
  }
  let dataset = @moondata_core.dataset_manifest(
    "dataset-checksum",
    "raw",
    "imported",
    20L,
    data_refs=[
      @moondata_core.data_ref(
        "payload-checksum",
        "raw-file",
        "moondata://media/imports/dataset-checksum/payload.json",
        content_type="application/json",
        byte_count=7L,
        checksum=@moondata_core.text_checksum("{\"t\":1}"),
      ),
    ],
  )
  let persisted = match @moondata_store.write_dataset(root, dataset) {
    Ok(value) => value
    Err(_) => fail("write dataset failed")
  }
  ignore(
    @moondata_store.write_catalog(
      root,
      @moondata_core.moondata_catalog(root, 21L, [
        @moondata_core.catalog_entry(
          persisted.artifact_kind,
          persisted.artifact_id,
          persisted.path,
          status=dataset.status,
        ),
      ]),
    ),
  )
  let report = match
    @moondata_validate.validate_root(root, generated_at_ms=22L) {
    Ok(value) => value
    Err(_) => fail("validate root failed")
  }
  assert_eq(report.status, "blocked")
  assert_true(has_finding(report, "data-ref-checksum-mismatch", "dataset"))
}

///|
test "catalog validation blocks local payload byte count drift" {
  let root = "target/moondata-validate-byte-count-test"
  ignore(@moondata_store.initialize_root(root))
  @fsx.create_dir(root + "/media/imports/dataset-byte-count") catch {
    _ => ()
  }
  @fsx.write_string_to_file(
    root + "/media/imports/dataset-byte-count/payload.json",
    "{\"t\":3}",
  ) catch {
    _ => fail("write payload failed")
  }
  let dataset = @moondata_core.dataset_manifest(
    "dataset-byte-count",
    "raw",
    "imported",
    23L,
    data_refs=[
      @moondata_core.data_ref(
        "payload-byte-count",
        "raw-file",
        "moondata://media/imports/dataset-byte-count/payload.json",
        content_type="application/json",
        byte_count=99L,
        checksum=@moondata_core.text_checksum("{\"t\":3}"),
      ),
    ],
  )
  let persisted = match @moondata_store.write_dataset(root, dataset) {
    Ok(value) => value
    Err(_) => fail("write dataset failed")
  }
  ignore(
    @moondata_store.write_catalog(
      root,
      @moondata_core.moondata_catalog(root, 24L, [
        @moondata_core.catalog_entry(
          persisted.artifact_kind,
          persisted.artifact_id,
          persisted.path,
          status=dataset.status,
        ),
      ]),
    ),
  )
  let report = match
    @moondata_validate.validate_root(root, generated_at_ms=25L) {
    Ok(value) => value
    Err(_) => fail("validate root failed")
  }
  assert_eq(report.status, "blocked")
  assert_true(has_finding(report, "data-ref-byte-count-mismatch", "dataset"))
}

///|
test "catalog validation blocks conflicting metadata for the same local data URI" {
  let root = "target/moondata-validate-data-ref-uri-conflict-test"
  ignore(@moondata_store.initialize_root(root))
  @fsx.create_dir(root + "/media/imports/uri-conflict") catch {
    _ => ()
  }
  let body = "{\"t\":1}\n"
  let uri = "moondata://media/imports/uri-conflict/payload.json"
  @fsx.write_string_to_file(
    root + "/media/imports/uri-conflict/payload.json",
    body,
  ) catch {
    _ => fail("write URI conflict payload failed")
  }
  let source_ref = @moondata_core.data_ref(
    "payload-uri-conflict-source",
    "raw-json",
    uri,
    content_type="application/json",
    byte_count=body.length().to_int64() + 1L,
    checksum="text-sum-v1:999:999",
  )
  let dataset_ref = @moondata_core.data_ref(
    "payload-uri-conflict-dataset",
    "raw-json",
    uri,
    content_type="application/json",
    byte_count=body.length().to_int64(),
    checksum=@moondata_core.text_checksum(body),
  )
  let source = @moondata_core.data_source(
    "source-uri-conflict",
    "import",
    "URI conflict source",
    "robot-validate",
    "bridge-validate",
    "file:///tmp/payload.json",
    170L,
    source_refs=[source_ref],
  )
  let dataset = @moondata_core.dataset_manifest(
    "dataset-uri-conflict",
    "raw",
    "imported",
    171L,
    source_ids=[source.source_id],
    data_refs=[dataset_ref],
  )
  let persisted_source = match @moondata_store.write_source(root, source) {
    Ok(value) => value
    Err(_) => fail("write URI conflict source failed")
  }
  let persisted_dataset = match @moondata_store.write_dataset(root, dataset) {
    Ok(value) => value
    Err(_) => fail("write URI conflict dataset failed")
  }
  ignore(
    @moondata_store.write_catalog(
      root,
      @moondata_core.moondata_catalog(root, 172L, [
        @moondata_core.catalog_entry(
          persisted_source.artifact_kind,
          persisted_source.artifact_id,
          persisted_source.path,
          status="imported",
        ),
        @moondata_core.catalog_entry(
          persisted_dataset.artifact_kind,
          persisted_dataset.artifact_id,
          persisted_dataset.path,
          status="imported",
        ),
      ]),
    ),
  )
  let report = match
    @moondata_validate.validate_root(root, generated_at_ms=173L) {
    Ok(value) => value
    Err(_) => fail("validate URI conflict failed")
  }
  assert_eq(report.status, "blocked")
  assert_true(has_finding(report, "data-ref-uri-byte-count-conflict", "source"))
  assert_true(has_finding(report, "data-ref-uri-checksum-conflict", "source"))
}

///|
test "catalog validation checks signal series storage refs" {
  let root = "target/moondata-validate-signal-payload-test"
  ignore(@moondata_store.initialize_root(root))
  let signal = @moondata_core.signal_series(
    "signal-missing-payload",
    "dataset-signal",
    "episode-signal",
    "joint.position",
    "rad",
    1,
    "unix-ms",
    @moondata_core.data_ref(
      "signal-payload-missing",
      "raw-file",
      "moondata://media/imports/dataset-signal/missing.csv",
      content_type="text/csv",
    ),
  )
  let persisted = match @moondata_store.write_signal_series(root, signal) {
    Ok(value) => value
    Err(_) => fail("write signal failed")
  }
  ignore(
    @moondata_store.write_catalog(
      root,
      @moondata_core.moondata_catalog(root, 26L, [
        @moondata_core.catalog_entry(
          persisted.artifact_kind,
          persisted.artifact_id,
          persisted.path,
        ),
      ]),
    ),
  )
  let report = match
    @moondata_validate.validate_root(root, generated_at_ms=27L) {
    Ok(value) => value
    Err(_) => fail("validate root failed")
  }
  assert_eq(report.status, "blocked")
  assert_true(
    has_finding(report, "data-ref-missing-local-payload", "signal-series"),
  )
}

///|
test "catalog validation blocks dangling signal dataset and episode references" {
  let root = "target/moondata-validate-signal-reference-test"
  ignore(@moondata_store.initialize_root(root))
  @fsx.create_dir(root + "/media/imports/dataset-signal-ref") catch {
    _ => ()
  }
  @fsx.write_string_to_file(
    root + "/media/imports/dataset-signal-ref/payload.csv",
    "t,x\n1,2\n",
  ) catch {
    _ => fail("write signal payload failed")
  }
  let signal = @moondata_core.signal_series(
    "signal-dangling-ref",
    "dataset-signal-missing",
    "episode-signal-missing",
    "joint.velocity",
    "rad/s",
    1,
    "unix-ms",
    @moondata_core.data_ref(
      "signal-payload-ref",
      "raw-file",
      "moondata://media/imports/dataset-signal-ref/payload.csv",
      content_type="text/csv",
      byte_count=8L,
      checksum=@moondata_core.text_checksum("t,x\n1,2\n"),
    ),
  )
  let persisted = match @moondata_store.write_signal_series(root, signal) {
    Ok(value) => value
    Err(_) => fail("write signal failed")
  }
  ignore(
    @moondata_store.write_catalog(
      root,
      @moondata_core.moondata_catalog(root, 28L, [
        @moondata_core.catalog_entry(
          persisted.artifact_kind,
          persisted.artifact_id,
          persisted.path,
        ),
      ]),
    ),
  )
  let report = match
    @moondata_validate.validate_root(root, generated_at_ms=29L) {
    Ok(value) => value
    Err(_) => fail("validate root failed")
  }
  assert_eq(report.status, "blocked")
  assert_true(
    has_finding(report, "moondata-ref-missing-catalog-entry", "signal-series"),
  )
}

///|
test "catalog validation blocks dangling dataset and episode references" {
  let root = "target/moondata-validate-reference-test"
  ignore(@moondata_store.initialize_root(root))
  let dataset = @moondata_core.dataset_manifest(
    "dataset-dangling-ref",
    "canonical",
    "active",
    13L,
    source_ids=["source-missing"],
    capture_ids=["capture-missing"],
    episode_ids=["episode-missing"],
    lineage_id="lineage-missing",
  )
  let persisted = match @moondata_store.write_dataset(root, dataset) {
    Ok(value) => value
    Err(_) => fail("write dataset failed")
  }
  ignore(
    @moondata_store.write_catalog(
      root,
      @moondata_core.moondata_catalog(root, 14L, [
        @moondata_core.catalog_entry(
          persisted.artifact_kind,
          persisted.artifact_id,
          persisted.path,
          status=dataset.status,
        ),
      ]),
    ),
  )
  let report = match
    @moondata_validate.validate_root(root, generated_at_ms=15L) {
    Ok(value) => value
    Err(_) => fail("validate root failed")
  }
  assert_eq(report.status, "blocked")
  assert_true(
    has_finding(report, "moondata-ref-missing-catalog-entry", "dataset"),
  )
}

///|
test "catalog validation blocks dangling version and export references" {
  let root = "target/moondata-validate-handoff-reference-test"
  ignore(@moondata_store.initialize_root(root))
  let version = @moondata_core.dataset_version(
    "version-dangling",
    "dataset-missing",
    "accepted",
    16L,
    parent_version_ids=["version-parent-missing"],
    accepted_episode_ids=["episode-missing"],
    quality_run_ids=["quality-missing"],
  )
  let manifest = @moondata_core.export_manifest(
    "export-dangling",
    version.version_id,
    version.dataset_id,
    "jsonl",
    "{\"payload\":\"frame.payload_ref\"}",
    [],
    17L,
    quality_run_ids=version.quality_run_ids,
  )
  let version_persisted = match
    @moondata_store.write_dataset_version(root, version) {
    Ok(value) => value
    Err(_) => fail("write version failed")
  }
  let export_persisted = match
    @moondata_store.write_export_manifest(root, manifest) {
    Ok(value) => value
    Err(_) => fail("write export manifest failed")
  }
  ignore(
    @moondata_store.write_catalog(
      root,
      @moondata_core.moondata_catalog(root, 18L, [
        @moondata_core.catalog_entry(
          version_persisted.artifact_kind,
          version_persisted.artifact_id,
          version_persisted.path,
          status=version.status,
        ),
        @moondata_core.catalog_entry(
          export_persisted.artifact_kind,
          export_persisted.artifact_id,
          export_persisted.path,
          status=manifest.status,
        ),
      ]),
    ),
  )
  let report = match
    @moondata_validate.validate_root(root, generated_at_ms=19L) {
    Ok(value) => value
    Err(_) => fail("validate root failed")
  }
  assert_eq(report.status, "blocked")
  assert_true(
    has_finding(report, "moondata-ref-missing-catalog-entry", "dataset-version"),
  )
  assert_true(
    has_finding(report, "moondata-ref-missing-catalog-entry", "export-manifest"),
  )
}

///|
test "catalog validation blocks cross-dataset handoff references" {
  let root = "target/moondata-validate-dataset-graph-test"
  ignore(@moondata_store.initialize_root(root))
  let owner = @moondata_core.dataset_manifest(
    "dataset-owner", "curated", "active", 40L,
  )
  let other = @moondata_core.dataset_manifest(
    "dataset-other", "curated", "active", 41L,
  )
  let other_episode = @moondata_core.episode_manifest(
    "episode-other",
    other.dataset_id,
    "robot-graph",
    "bridge-graph",
    "session-graph",
    "stopped",
    42L,
    stopped_at_ms=Some(43L),
  )
  let other_quality = @moondata_core.quality_run(
    "quality-other",
    other.dataset_id,
    [other_episode.episode_id],
    44L,
    [],
  )
  let owner_version = @moondata_core.dataset_version(
    "version-owner",
    owner.dataset_id,
    "accepted",
    45L,
    accepted_episode_ids=[other_episode.episode_id],
    quality_run_ids=[other_quality.quality_run_id],
  )
  let owner_export = @moondata_core.export_manifest(
    "export-owner",
    owner_version.version_id,
    owner.dataset_id,
    "jsonl",
    "{\"payload\":\"frame.payload_ref\"}",
    [],
    46L,
    quality_run_ids=[other_quality.quality_run_id],
  )
  let owner_persisted = match @moondata_store.write_dataset(root, owner) {
    Ok(value) => value
    Err(_) => fail("write owner dataset failed")
  }
  let other_persisted = match @moondata_store.write_dataset(root, other) {
    Ok(value) => value
    Err(_) => fail("write other dataset failed")
  }
  let episode_persisted = match
    @moondata_store.write_episode(root, other_episode) {
    Ok(value) => value
    Err(_) => fail("write other episode failed")
  }
  let quality_persisted = match
    @moondata_store.write_quality_run(root, other_quality) {
    Ok(value) => value
    Err(_) => fail("write other quality failed")
  }
  let version_persisted = match
    @moondata_store.write_dataset_version(root, owner_version) {
    Ok(value) => value
    Err(_) => fail("write owner version failed")
  }
  let export_persisted = match
    @moondata_store.write_export_manifest(root, owner_export) {
    Ok(value) => value
    Err(_) => fail("write owner export failed")
  }
  ignore(
    @moondata_store.write_catalog(
      root,
      @moondata_core.moondata_catalog(root, 47L, [
        @moondata_core.catalog_entry(
          owner_persisted.artifact_kind,
          owner_persisted.artifact_id,
          owner_persisted.path,
          status=owner.status,
        ),
        @moondata_core.catalog_entry(
          other_persisted.artifact_kind,
          other_persisted.artifact_id,
          other_persisted.path,
          status=other.status,
        ),
        @moondata_core.catalog_entry(
          episode_persisted.artifact_kind,
          episode_persisted.artifact_id,
          episode_persisted.path,
          status=other_episode.status,
        ),
        @moondata_core.catalog_entry(
          quality_persisted.artifact_kind,
          quality_persisted.artifact_id,
          quality_persisted.path,
          status=other_quality.status,
        ),
        @moondata_core.catalog_entry(
          version_persisted.artifact_kind,
          version_persisted.artifact_id,
          version_persisted.path,
          status=owner_version.status,
        ),
        @moondata_core.catalog_entry(
          export_persisted.artifact_kind,
          export_persisted.artifact_id,
          export_persisted.path,
          status=owner_export.status,
        ),
      ]),
    ),
  )
  let report = match
    @moondata_validate.validate_root(root, generated_at_ms=48L) {
    Ok(value) => value
    Err(_) => fail("validate graph failed")
  }
  assert_eq(report.status, "blocked")
  assert_true(
    has_finding(report, "moondata-ref-dataset-mismatch", "dataset-version"),
  )
  assert_true(
    has_finding(report, "moondata-ref-dataset-mismatch", "export-manifest"),
  )
}
