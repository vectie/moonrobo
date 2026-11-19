///|
pub(all) struct FileIdentity {
  path : String
  sha256 : String
} derive(ToJson, FromJson, Debug)

///|
pub(all) struct FixtureManifest {
  format : String
  case_id : String
  oracle_kind : String
  upstream_revision : String
  upstream_sources : Map[String, FileIdentity]
  candidate_sources : Map[String, FileIdentity]
  original_test : FileIdentity
  torch_version : String
  device : String
  threads : Int32
  dtype : String
  config : Json
  input : FileIdentity
  expected : FileIdentity
  rng_before_sha256 : String
  rng_after_sha256 : String
  producer : FileIdentity
  oracle_adapter : FileIdentity?
  input_keys : Array[String]
  expected_keys : Array[String]
} derive(ToJson, FromJson, Debug)

///|
pub(all) struct Fixture {
  manifest : FixtureManifest
  manifest_sha256 : String
  input : Map[String, @artifacts.NumericArray]
  expected : Map[String, @artifacts.NumericArray]
}

///|
pub(all) struct Verification {
  case_id : String
  fixture_sha256 : String
  candidate_sha256 : String
  output_count : Int32
  maxima : Map[String, Double]
  passed : Bool
} derive(ToJson, Debug)

///|
fn finite(x : Double) -> Bool {
  !x.is_nan() && !x.is_inf()
}

///|
fn digest_valid(text : String) -> Bool {
  text.length() == 64 && text.iter().all(c => c is ('0'..<='9' | 'a'..<='f'))
}

///|
fn path(root : String, relative : String) -> String raise {
  guard !relative.is_empty() &&
    !relative.has_prefix("/") &&
    !relative.split("/").any(part => part == "..") else {
    fail("fixture path must stay below its declared root")
  }
  root + "/" + relative
}

///|
async fn verify_file(root : String, identity : FileIdentity) -> Bytes {
  guard digest_valid(identity.sha256) else {
    fail("fixture identity requires a full lowercase SHA256")
  }
  let data = @fs.read_file(path(root, identity.path)).binary()
  guard @artifacts.sha256(data) == identity.sha256 else {
    fail("fixture source/data SHA256 changed: " + identity.path)
  }
  data
}

///|
fn tensor_valid(name : String, array : @artifacts.NumericArray) -> Unit raise {
  guard !name.is_empty() && !array.shape.any(n => n < 0) else {
    fail("invalid differential tensor name/shape")
  }
  let mut count = 1L
  for n in array.shape {
    count *= n.to_int64()
    guard count <= 2147483647L else {
      fail("fixture tensor exceeds bounded loader limit")
    }
  }
  guard count == array.values.length().to_int64() && array.values.all(finite) else {
    fail("fixture tensor count or finite values mismatch: " + name)
  }
  guard ["<f4", "<f8", "<i4", "<i8", "|u1", "|b1"].contains(array.dtype) else {
    fail("unsupported exact differential tensor dtype: " + array.dtype)
  }
  if array.dtype == "<f4" {
    guard array.values.all(v => v.to_float().to_double() == v) else {
      fail("float32 tensor values are not exactly representable: " + name)
    }
  }
  if array.dtype == "<i8" {
    guard array.values.all(v => v.abs() <= 9007199254740991.0 && v.trunc() == v) else {
      fail("int64 fixture values exceed exact Double integer range")
    }
  }
  if array.dtype == "<i4" {
    guard array.values.all(v => {
      v >= -2147483648.0 && v <= 2147483647.0 && v.trunc() == v
    }) else {
      fail("int32 fixture value out of range")
    }
  }
  if array.dtype == "|u1" {
    guard array.values.all(v => v >= 0.0 && v <= 255.0 && v.trunc() == v) else {
      fail("uint8 fixture value out of range")
    }
  }
  if array.dtype == "|b1" {
    guard array.values.all(v => v == 0.0 || v == 1.0) else {
      fail("boolean fixture value must be 0 or 1")
    }
  }
  if name == "rng.before" || name == "rng.after" {
    guard array.dtype == "|u1" &&
      array.values.all(v => v >= 0.0 && v <= 255.0 && v.trunc() == v) else {
      fail("RNG state must contain exact uint8 bytes")
    }
  }
}

///|
pub async fn load_fixture(
  folder : String,
  source_root : String,
  expected_manifest_sha256 : String,
) -> Fixture {
  guard digest_valid(expected_manifest_sha256) else {
    fail("trusted fixture manifest SHA256 is mandatory")
  }
  let raw = @fs.read_file(folder + "/fixture.json").binary()
  guard @artifacts.sha256(raw) == expected_manifest_sha256 else {
    fail("fixture manifest differs from trusted identity")
  }
  let manifest : FixtureManifest = @json.from_json(
    @json.parse(@utf8.decode(raw)),
  )
  guard manifest.format == "moonrobo.smc-differential.fixture.v1" &&
    [
      "executed-upstream-python", "independent-aten-cpp", "independent-mathematics",
      "sdk-protocol-trace",
    ].contains(manifest.oracle_kind) else {
    fail("unknown differential fixture/oracle format")
  }
  ignore(contract(manifest.case_id))
  guard manifest.upstream_revision == "a1508d42c9d1699a52e8233ab16d08c488441ab9" &&
    manifest.device == "cpu" &&
    manifest.threads == 1 &&
    ["float32", "float64"].contains(manifest.dtype) else {
    fail("differential source revision/device/threads/dtype mismatch")
  }
  guard !manifest.upstream_sources.is_empty() &&
    !manifest.candidate_sources.is_empty() else {
    fail("independent oracle and candidate source identities are mandatory")
  }
  for _, identity in manifest.upstream_sources {
    ignore(verify_file(source_root, identity))
  }
  for _, identity in manifest.candidate_sources {
    ignore(verify_file(source_root, identity))
  }
  ignore(verify_file(source_root, manifest.original_test))
  ignore(verify_file(source_root, manifest.producer))
  if manifest.oracle_adapter is Some(adapter) {
    ignore(verify_file(source_root, adapter))
  }
  guard manifest.upstream_sources
    .values()
    .all(up => {
      !manifest.candidate_sources
      .values()
      .any(candidate => up.path == candidate.path)
    }) else {
    fail("oracle and candidate must not be the same implementation")
  }
  let input = @artifacts.decode_npz(verify_file(folder, manifest.input))
  let expected = @artifacts.decode_npz(verify_file(folder, manifest.expected))
  guard manifest.input_keys.length() == input.length() &&
    input.keys().all(key => manifest.input_keys.contains(key)) &&
    manifest.expected_keys.length() == expected.length() &&
    expected.keys().all(key => manifest.expected_keys.contains(key)) else {
    fail("fixture full tensor keyset differs from sealed schema")
  }
  for name, array in input {
    tensor_valid(name, array)
    if name.has_prefix("weights.") ||
      (name.has_prefix("optimizer_before.") && !name.has_suffix(".step")) {
      guard array.dtype ==
        (if manifest.dtype == "float32" { "<f4" } else { "<f8" }) else {
        fail(
          "model/optimizer tensor dtype differs from sealed producer metadata: " +
          name,
        )
      }
    }
  }
  for name, array in expected {
    tensor_valid(name, array)
  }
  validate_case_inputs(manifest.case_id, input)
  guard input.get("rng.before") is Some(before) &&
    expected.get("rng.after") is Some(after) else {
    fail(
      "both explicit RNG states are mandatory; deterministic cases use empty uint8 arrays",
    )
  }
  guard @artifacts.sha256(
      Bytes::from_array(before.values.map(v => v.to_int().to_byte())),
    ) ==
    manifest.rng_before_sha256 &&
    @artifacts.sha256(
      Bytes::from_array(after.values.map(v => v.to_int().to_byte())),
    ) ==
    manifest.rng_after_sha256 else {
    fail("RNG state digests differ")
  }
  validate_required(manifest.case_id, expected)
  validate_learning_evidence(manifest.case_id, input, expected)
  { manifest, manifest_sha256: expected_manifest_sha256, input, expected, }
}

///|
pub fn compare_fixture(
  fixture : Fixture,
  candidate : Map[String, @artifacts.NumericArray],
  candidate_sha256 : String,
) -> Verification raise {
  guard digest_valid(candidate_sha256) else {
    fail("candidate artifact SHA256 required")
  }
  guard candidate.length() == fixture.expected.length() else {
    fail("candidate output set differs from full oracle contract")
  }
  if fixture.manifest.case_id == "data.duplicates" {
    let probabilities = get(candidate, "probabilities").values
    guard probabilities.length() > 2 && probabilities[1] > probabilities[2] else {
      fail("original sampler probability ordering predicate failed")
    }
  }
  let maxima : Map[String, Double] = {}
  for name, expected in fixture.expected {
    guard candidate.get(name) is Some(actual) else {
      fail("missing candidate output " + name)
    }
    tensor_valid(name, actual)
    guard actual.shape == expected.shape && actual.dtype == expected.dtype else {
      fail("candidate dtype/shape differs: " + name)
    }
    let (atol, rtol) = tolerance(fixture.manifest.case_id, name)
    let mut maximum = 0.0
    for i, x in actual.values {
      let difference = (x - expected.values[i]).abs()
      maximum = maximum.max(difference)
      guard difference <= atol + rtol * expected.values[i].abs() else {
        fail(
          "strict upstream differential mismatch: \{fixture.manifest.case_id} \{name}[\{i}], error=\{difference}, atol=\{atol}, rtol=\{rtol}",
        )
      }
    }
    maxima[name] = maximum
  }
  {
    case_id: fixture.manifest.case_id,
    fixture_sha256: fixture.manifest_sha256,
    candidate_sha256,
    output_count: candidate.length(),
    maxima,
    passed: true,
  }
}
