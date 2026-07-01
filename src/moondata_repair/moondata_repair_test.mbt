///|
fn action_category_count(
  actions : Array[MoonDataRepairAction],
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
test "repair plan categorizes missing and unmanaged payload actions" {
  let root = "target/moondata-repair-payload-plan-test"
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
