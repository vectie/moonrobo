///|
fn digest_fixture() -> @gpu.SharedStateDigest {
  {
    format: "moonrobo.shared-learner-state.v1",
    sha256: "same-state",
    learner_config_sha256: "same-config",
    normalizers_sha256: "same-normalizers",
    optimizers: [],
    host_chunk_values: 65536,
  }
}

///|
struct DerivedOptionalDigest {
  shared_state_digest : @gpu.SharedStateDigest?
} derive(ToJson, FromJson)

///|
test "audit accepts legacy and both attested v1 field encodings" {
  let fields : Map[String, Json] = {
    "format": "moonrobo.native-tensor-checkpoint-pointer.v1",
    "generation": "generation-1-fixture",
    "iteration": 1,
    "files": {},
  }
  assert_true(decode_receipt(Json(fields)).shared_state_digest is None)
  fields["shared_state_digest"] = Json::null()
  assert_true(decode_receipt(Json(fields)).shared_state_digest is None)
  let expected = digest_fixture()
  fields["shared_state_digest"] = Json(expected)
  let direct = decode_receipt(Json(fields)).shared_state_digest
  assert_eq(Json(direct.unwrap()), Json(expected))
  fields["shared_state_digest"] = Json(Some(expected))
  let wrapped = decode_receipt(Json(fields)).shared_state_digest
  assert_eq(Json(wrapped.unwrap()), Json(expected))
  assert_eq(verify_attestation(direct, wrapped, expected), Some(true))
  assert_eq(verify_attestation(None, None, expected), None)
  let derived : DerivedOptionalDigest = { shared_state_digest: Some(expected), }
  assert_eq(Json(decode_attestation(Json(derived)).unwrap()), Json(expected))
  // Derived fields have different encoding rules from standalone Option JSON.
  let roundtrip : DerivedOptionalDigest = @json.from_json(Json(derived))
  assert_eq(Json(roundtrip.shared_state_digest.unwrap()), Json(expected))
}

///|
test "audit refuses malformed attestation encodings and unsupported schema" {
  let expected = Json(digest_fixture())
  let invalid : Array[Json] = [
    [],
    [expected, expected],
    [[expected]],
    [null],
    "bad",
    1,
    {},
    Json({ ..digest_fixture(), format: "unsupported-v2", }),
  ]
  for value in invalid {
    try decode_attestation({ "shared_state_digest": value }) catch {
      _ => ()
    } noraise {
      _ => fail("invalid attestation encoding/schema was accepted")
    }
  }
}

///|
test "audit requires both attestations to match actual held state" {
  let actual = digest_fixture()
  let different = { ..actual, sha256: "different-state", }
  for
    (receipt, state) in [
      (None, Some(actual)),
      (Some(actual), None),
      (Some(different), Some(actual)),
      (Some(actual), Some(different)),
    ] {
    try verify_attestation(receipt, state, actual) catch {
      _ => ()
    } noraise {
      _ => fail("attestation mismatch must fail closed")
    }
  }
}

///|
test "stream-v2 audit requires the complete typed receipt inventory and bounded payload" {
  let blob : @stream.BlobDescriptor = {
    file: "replay.bin",
    dtype: "u8",
    shape: [0],
    count: 0L,
    byte_length: 0L,
    sha256: "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
  }
  let files : Map[String, String] = {
    "world.pt": "world",
    "policy.pt": "policy",
    "critic.pt": "critic",
    "state.json": "state",
    "replay.bin": blob.sha256,
  }
  assert_eq(stream_inventory([blob], files, 128L), 0L)
  let oversized = {
    ..blob,
    shape: [536870912],
    count: 536870912L,
    byte_length: 536870912L,
  }
  for blobs in [[blob, blob], [{ ..blob, file: "policy.pt", }], [oversized]] {
    try stream_inventory(blobs, files, 128L) catch {
      _ => ()
    } noraise {
      _ => fail("invalid typed sidecar inventory must fail closed")
    }
  }
  let unexpected = files.copy()
  unexpected["unreferenced.bin"] = blob.sha256
  try stream_inventory([blob], unexpected, 128L) catch {
    _ => ()
  } noraise {
    _ => fail("unreferenced receipt member must fail closed")
  }
  let mismatched = files.copy()
  mismatched[blob.file] = "wrong"
  try stream_inventory([blob], mismatched, 128L) catch {
    _ => ()
  } noraise {
    _ => fail("descriptor and receipt hashes must agree")
  }
}

///|
async test "stream-v2 audit uses bounded exact sidecar byte verification" {
  let directory = @fs.tmpdir(prefix="moonrobo-audit-stream-")
  defer @fs.rmdir(directory, recursive=true)
  let bytes : Array[Byte] = [b'1', b'2', b'3']
  let blob = @stream.write_u8(directory, "catalog.json", [3], (offset, count) => {
    bytes[offset.to_int():offset.to_int() + count].to_array()
  })
  let files : Map[String, String] = {
    "world.pt": "world",
    "policy.pt": "policy",
    "critic.pt": "critic",
    "state.json": "state",
    "catalog.json": blob.sha256,
  }
  assert_eq(stream_inventory([blob], files, 128L), 3L)
  @stream.verify_blob(directory, blob)
  @fs.write_file(
    directory + "/catalog.json",
    b"124",
    create_mode=TruncateExisting,
  )
  try @stream.verify_blob(directory, blob) catch {
    _ => ()
  } noraise {
    _ => fail("changed payload must fail SHA verification")
  }
}
