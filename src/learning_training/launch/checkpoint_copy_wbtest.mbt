///|
/// Authored regression sources only; execution is deferred with all tests.
async fn copy_contract_folder() -> String {
  @fs.tmpdir(prefix="moonrobo-checkpoint-copy-")
}

///|
async test "native checkpoint copy preserves bytes and exact source takes precedence" {
  let folder = copy_contract_folder()
  defer (@fs.rmdir(folder, recursive=true) catch { _ => () })
  let source = folder + "/dynamics-seed-0.moon.json"
  let old = folder + "/dynamics-seed-0.pt"
  let destination = folder + "/copied.moon.json"
  let checkpoint = @artifacts.Checkpoint::new("residual-dynamics", {
    "source": "fixture",
  })
  checkpoint.put("sample", [2], [1.25, -2.0])
  ignore(@artifacts.save_checkpoint(source, checkpoint))
  @fs.write_file(old, b"PK\x03\x04invalid", create_mode=CreateNew)
  assert_eq(checkpoint_input(source), source)
  let report = copy_checkpoint(source, destination, "residual-dynamics")
  assert_eq(@fs.read_file(source).binary(), @fs.read_file(destination).binary())
  guard report is Object(fields) else { fail("copy report must be object") }
  assert_eq(fields["converted_from_torch"], false.to_json())
  assert_eq(fields["byte_identical"], true.to_json())
}

///|
async test "legacy suffix resolves real pt but malformed Torch never becomes mislabeled native JSON" {
  let folder = copy_contract_folder()
  defer (@fs.rmdir(folder, recursive=true) catch { _ => () })
  let requested = folder + "/dynamics-seed-0.moon.json"
  let actual = folder + "/dynamics-seed-0.pt"
  let destination = folder + "/output.moon.json"
  let bytes = b"PK\x03\x04invalid"
  @fs.write_file(actual, bytes, create_mode=CreateNew)
  assert_eq(checkpoint_input(requested), actual)
  assert_true(
    (try? copy_checkpoint(requested, destination, "residual-dynamics"))
    is Err(_),
  )
  assert_true(!@fs.exists(destination))
  assert_true(!@fs.exists(destination + ".source.json"))
  assert_eq(@fs.read_file(actual).binary(), bytes)
}

///|
async test "checkpoint copy rejects unsupported kind and non-native output before writing" {
  let folder = copy_contract_folder()
  defer (@fs.rmdir(folder, recursive=true) catch { _ => () })
  let source = folder + "/actor-seed-0.pt"
  let target = folder + "/actor-seed-0.moon.json"
  assert_true(
    (try? copy_checkpoint(source, target, "temporal-actor")) is Err(_),
  )
  assert_true(
    (try? copy_checkpoint(source, folder + "/wrong.pt", "g1-actor")) is Err(_),
  )
  assert_true(!@fs.exists(target))
}
