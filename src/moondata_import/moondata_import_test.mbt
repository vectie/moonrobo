///|
fn ensure_dir(path : String) -> Unit raise {
  if !@fsx.path_exists(path) {
    @fsx.create_dir(path) catch {
      _ => fail("failed to create " + path)
    }
  }
}

///|
test "local file import stores raw payloads and rebuilds catalog" {
  let root = "target/moondata-import-test"
  let input = "target/moondata-import-input"
  ensure_dir("target")
  ensure_dir(input)
  @fsx.write_string_to_file(input + "/frame-a.json", "{\"t\":1}") catch {
    _ => fail("write input a failed")
  }
  @fsx.write_string_to_file(input + "/frame-b.csv", "t,x\n2,4\n") catch {
    _ => fail("write input b failed")
  }
  let result = match
    @moondata_import.import_local_files(
      @moondata_import.local_file_import_request(
        root, input, "ds-import-1", "robot-import", "bridge-import", "session-import",
        100L,
      ),
    ) {
    Ok(value) => value
    Err(error) => fail("import failed: " + error.message)
  }
  assert_eq(result.payload_count, 2)
  assert_eq(result.dataset.kind, "raw")
  assert_eq(result.dataset.status, "imported")
  assert_eq(result.episode.status, "stopped")
  assert_eq(result.episode.frame_count, 2)
  assert_true(@fsx.path_exists(result.payloads[0].stored_path))
  assert_true(@fsx.path_exists(result.payloads[1].stored_path))
  let catalog = match @moondata_store.read_catalog(root) {
    Ok(value) => value
    Err(_) => fail("read catalog failed")
  }
  assert_eq(catalog.entry_count, 6)
}

///|
test "local file import rejects empty inputs explicitly" {
  let root = "target/moondata-import-empty-test"
  let input = "target/moondata-import-empty-input"
  ensure_dir("target")
  ensure_dir(input)
  match
    @moondata_import.import_local_files(
      @moondata_import.local_file_import_request(
        root, input, "ds-empty", "robot-import", "bridge-import", "session-import",
        200L,
      ),
    ) {
    Ok(_) => fail("expected empty import to fail")
    Err(error) => assert_eq(error.code, "input-empty")
  }
}
