///|
fn action_category_count(
  actions : Array[@moondata_core.RepairAction],
  category : String,
) -> Int {
  let mut count = 0
  for action in actions {
    if action.category == category {
      count += 1
    }
  }
  count
}

///|
fn action_operation_count(
  actions : Array[@moondata_core.RepairAction],
  operation_kind : String,
) -> Int {
  let mut count = 0
  for action in actions {
    if action.operation_kind == operation_kind {
      count += 1
    }
  }
  count
}

///|
fn action_target_count(
  actions : Array[@moondata_core.RepairAction],
  target_ref : String,
) -> Int {
  let mut count = 0
  for action in actions {
    if action.target_ref == target_ref {
      count += 1
    }
  }
  count
}

///|
test "repair plan categorizes missing and unmanaged payload actions" {
  let root = "target/moondata-repair-payload-plan-routing-test"
  ignore(@moondata_store.initialize_root(root))
  @fsx.create_dir(root + "/media/imports/repair-plan") catch {
    _ => ()
  }
  @fsx.write_string_to_file(
    root + "/media/imports/repair-plan/unmanaged.json",
    "{\"unmanaged\":true}\n",
  ) catch {
    _ => fail("write unmanaged payload failed")
  }
  let missing_ref = @moondata_core.data_ref(
    "repair-missing-payload",
    "raw-file",
    "moondata://media/imports/repair-plan/missing.json",
    content_type="application/json",
    byte_count=3L,
    checksum="text-sum-v1:3:123",
  )
  let dataset = @moondata_core.dataset_manifest(
    "dataset-repair-plan",
    "raw",
    "imported",
    10L,
    data_refs=[missing_ref],
  )
  let persisted = match @moondata_store.write_dataset(root, dataset) {
    Ok(value) => value
    Err(_) => fail("write repair dataset failed")
  }
  ignore(
    @moondata_store.write_catalog(
      root,
      @moondata_core.moondata_catalog(root, 11L, [
        @moondata_core.catalog_entry(
          persisted.artifact_kind,
          persisted.artifact_id,
          persisted.path,
          status=dataset.status,
        ),
      ]),
    ),
  )
  let plan = match @moondata_repair.plan_repairs(root, generated_at_ms=12L) {
    Ok(value) => value
    Err(_) => fail("plan repairs failed")
  }
  assert_eq(plan.validation_status, "blocked")
  assert_eq(plan.action_count, 2)
  assert_eq(plan.blocker_count, 2)
  assert_eq(plan.missing_payload_count, 1)
  assert_eq(plan.unmanaged_payload_count, 1)
  assert_eq(action_category_count(plan.actions, "missing-payload"), 1)
  assert_eq(action_category_count(plan.actions, "unmanaged-payload"), 1)
  assert_eq(
    action_operation_count(plan.actions, "restore-or-remove-payload-ref"),
    1,
  )
  assert_eq(
    action_operation_count(plan.actions, "declare-or-remove-payload"),
    1,
  )
  assert_eq(action_target_count(plan.actions, "dataset:dataset-repair-plan"), 1)
  assert_eq(plan.refs.length(), 2)
}

///|
test "repair plan categorizes duplicate URI metadata conflicts" {
  let root = "target/moondata-repair-conflict-plan-test"
  ignore(@moondata_store.initialize_root(root))
  @fsx.create_dir(root + "/media/imports/repair-conflict") catch {
    _ => ()
  }
  @fsx.write_string_to_file(
    root + "/media/imports/repair-conflict/shared.json",
    "{\"shared\":true}\n",
  ) catch {
    _ => fail("write shared payload failed")
  }
  let uri = "moondata://media/imports/repair-conflict/shared.json"
  let left_ref = @moondata_core.data_ref(
    "repair-conflict-left",
    "raw-file",
    uri,
    content_type="application/json",
    byte_count=16L,
    checksum="text-sum-v1:16:100",
  )
  let right_ref = @moondata_core.data_ref(
    "repair-conflict-right",
    "raw-file",
    uri,
    content_type="application/json",
    byte_count=17L,
    checksum="text-sum-v1:17:200",
  )
  let source = @moondata_core.data_source(
    "source-repair-conflict",
    "sidecar",
    "repair conflict source",
    "robot-repair",
    "bridge-repair",
    "sidecar://repair-conflict",
    20L,
    source_refs=[left_ref],
  )
  let dataset = @moondata_core.dataset_manifest(
    "dataset-repair-conflict",
    "raw",
    "imported",
    21L,
    source_ids=[source.source_id],
    data_refs=[right_ref],
  )
  let source_persisted = match @moondata_store.write_source(root, source) {
    Ok(value) => value
    Err(_) => fail("write repair source failed")
  }
  let dataset_persisted = match @moondata_store.write_dataset(root, dataset) {
    Ok(value) => value
    Err(_) => fail("write repair conflict dataset failed")
  }
  ignore(
    @moondata_store.write_catalog(
      root,
      @moondata_core.moondata_catalog(root, 22L, [
        @moondata_core.catalog_entry(
          source_persisted.artifact_kind,
          source_persisted.artifact_id,
          source_persisted.path,
          status="active",
        ),
        @moondata_core.catalog_entry(
          dataset_persisted.artifact_kind,
          dataset_persisted.artifact_id,
          dataset_persisted.path,
          status=dataset.status,
        ),
      ]),
    ),
  )
  let plan = match @moondata_repair.plan_repairs(root, generated_at_ms=23L) {
    Ok(value) => value
    Err(_) => fail("plan repair conflicts failed")
  }
  assert_eq(plan.validation_status, "blocked")
  assert_true(plan.metadata_conflict_count >= 2)
  assert_true(action_category_count(plan.actions, "metadata-conflict") >= 2)
}

///|
test "repair plan routes undeclared robot model URDF assets" {
  let root = "target/moondata-repair-robot-model-hidden-asset-test"
  ignore(@moondata_store.initialize_root(root))
  @fsx.create_dir(root + "/media/robot_models/repair-hidden") catch {
    _ => ()
  }
  @fsx.create_dir(root + "/media/robot_models/repair-hidden/meshes") catch {
    _ => ()
  }
  let hidden_mesh_uri = "moondata://media/robot_models/repair-hidden/meshes/base.stl"
  let urdf_text = "<robot name=\"repair-hidden\"><link name=\"base_link\"><visual><geometry><mesh filename=\"\{hidden_mesh_uri}\"/></geometry></visual></link></robot>"
  @fsx.write_string_to_file(
    root + "/media/robot_models/repair-hidden/robot.urdf",
    urdf_text,
  ) catch {
    _ => fail("write hidden repair URDF failed")
  }
  @fsx.write_string_to_file(
    root + "/media/robot_models/repair-hidden/meshes/base.stl",
    "solid repair-hidden\n",
  ) catch {
    _ => fail("write hidden repair mesh failed")
  }
  let urdf_ref = @moondata_core.data_ref(
    "repair-hidden-urdf",
    "urdf",
    "moondata://media/robot_models/repair-hidden/robot.urdf",
    content_type="application/xml",
    byte_count=urdf_text.length().to_int64(),
    checksum=@moondata_core.text_checksum(urdf_text),
  )
  let model = @moondata_core.robot_model_manifest(
    "robot-model-repair-hidden",
    "robot-repair",
    "urdf",
    "active",
    urdf_ref,
    24L,
    link_names=["base_link"],
    validation_status="pending",
    summary="hidden repair robot model asset refs",
  )
  let persisted = match @moondata_store.write_robot_model(root, model) {
    Ok(value) => value
    Err(_) => fail("write hidden repair robot model failed")
  }
  ignore(
    @moondata_store.write_catalog(
      root,
      @moondata_core.moondata_catalog(root, 25L, [
        @moondata_core.catalog_entry(
          persisted.artifact_kind,
          persisted.artifact_id,
          persisted.path,
          status=model.status,
        ),
      ]),
    ),
  )
  let plan = match @moondata_repair.plan_repairs(root, generated_at_ms=26L) {
    Ok(value) => value
    Err(_) => fail("plan hidden robot model asset repairs failed")
  }
  assert_eq(plan.validation_status, "blocked")
  assert_eq(plan.manifest_surface_ref_count, 1)
  assert_eq(action_category_count(plan.actions, "manifest-surface-ref"), 1)
  assert_eq(
    action_operation_count(plan.actions, "declare-or-remove-embedded-asset-ref"),
    1,
  )
  assert_eq(
    action_target_count(plan.actions, "robot-model:robot-model-repair-hidden"),
    1,
  )
}

///|
test "repair run is persisted and cataloged as MoonData-owned repair evidence" {
  let root = "target/moondata-repair-stored-run-test"
  ignore(@moondata_store.initialize_root(root))
  let dataset = @moondata_core.dataset_manifest(
    "dataset-stored-repair", "canonical", "active", 30L,
  )
  let persisted = match @moondata_store.write_dataset(root, dataset) {
    Ok(value) => value
    Err(_) => fail("write stored repair dataset failed")
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
    @moondata_repair.write_repair_run(root, generated_at_ms=32L) {
    Ok(value) => value
    Err(_) => fail("write repair run failed")
  }
  assert_eq(result.repair_run_id, "repair-32")
  assert_eq(result.repair_run.validation_report_id, "validation-32")
  assert_true(@fsx.path_exists(result.repair_run_path))
  let loaded = match
    @moondata_store.read_repair_run(root, result.repair_run_id) {
    Ok(value) => value
    Err(_) => fail("read repair run failed")
  }
  assert_eq(loaded.repair_run_id, result.repair_run_id)
  let catalog = match @moondata_store.read_catalog(root) {
    Ok(value) => value
    Err(_) => fail("read repair catalog failed")
  }
  let mut found = false
  for entry in catalog.entries {
    if entry.artifact_kind == "repair-run" &&
      entry.artifact_id == result.repair_run_id {
      found = true
    }
  }
  assert_true(found)
}

///|
test "repair receipt records execution evidence for a repair action" {
  let root = "target/moondata-repair-receipt-test"
  ignore(@moondata_store.initialize_root(root))
  let missing_ref = @moondata_core.data_ref(
    "repair-receipt-missing-payload",
    "raw-file",
    "moondata://media/imports/repair-receipt/missing.json",
    content_type="application/json",
    byte_count=3L,
    checksum="text-sum-v1:3:123",
  )
  let dataset = @moondata_core.dataset_manifest(
    "dataset-repair-receipt",
    "raw",
    "imported",
    40L,
    data_refs=[missing_ref],
  )
  let persisted = match @moondata_store.write_dataset(root, dataset) {
    Ok(value) => value
    Err(_) => fail("write receipt dataset failed")
  }
  ignore(
    @moondata_store.write_catalog(
      root,
      @moondata_core.moondata_catalog(root, 41L, [
        @moondata_core.catalog_entry(
          persisted.artifact_kind,
          persisted.artifact_id,
          persisted.path,
          status=dataset.status,
        ),
      ]),
    ),
  )
  let run = match @moondata_repair.write_repair_run(root, generated_at_ms=42L) {
    Ok(value) => value.repair_run
    Err(_) => fail("write receipt repair run failed")
  }
  let result = match
    @moondata_repair.record_repair_receipt(
      root,
      run.repair_run_id,
      run.actions[0].action_id,
      "applied",
      "operator",
      43L,
      validation_report_id="validation-43",
    ) {
    Ok(value) => value
    Err(error) => fail("record repair receipt failed: " + error.message)
  }
  assert_true(@fsx.path_exists(result.repair_receipt_path))
  assert_eq(result.repair_receipt.repair_run_id, run.repair_run_id)
  assert_eq(result.repair_receipt.action_id, run.actions[0].action_id)
  assert_eq(result.repair_receipt.operation_kind, run.actions[0].operation_kind)
  assert_eq(result.repair_receipt.target_ref, run.actions[0].target_ref)
}
