///|
async fn main {
  let args = @env.args()
  guard args.length() >= 3 && args.length() <= 5 else {
    fail(
      "usage: moon run cmd/learning_compare PYTHON_EXPORT MOONBIT_EXPORT [ATOL [RTOL]]",
    )
  }
  let atol = if args.length() > 3 {
    @string.parse_double(args[3])
  } else {
    1.0e-6
  }
  let rtol = if args.length() > 4 {
    @string.parse_double(args[4])
  } else {
    1.0e-5
  }
  let reference = @fs.read_file(args[1]).binary()
  let candidate = @fs.read_file(args[2]).binary()
  let failures : Array[Json] = []
  if args[1].has_suffix(".npz") {
    let expected = @artifacts.decode_npz(reference)
    let actual = @artifacts.decode_npz(candidate)
    guard expected.keys().collect().length() == actual.keys().collect().length() else {
      fail("NPZ member count differs")
    }
    for key, array in expected {
      guard actual.get(key) is Some(value) else {
        fail("missing NPZ member: " + key)
      }
      for diff in @artifacts.compare_numeric(array, value, atol~, rtol~) {
        failures.push({ "tensor": Json(key), "difference": Json(diff) })
      }
    }
  } else if args[1].has_suffix(".npy") {
    for
      diff in @artifacts.compare_numeric(
        @artifacts.decode_npy(reference),
        @artifacts.decode_npy(candidate),
        atol~,
        rtol~,
      ) {
      failures.push(Json(diff))
    }
  } else {
    let expected = @json.parse(@fs.read_file(args[1]).text())
    let actual = @json.parse(@fs.read_file(args[2]).text())
    for diff in @artifacts.compare_json(expected, actual, atol~, rtol~) {
      failures.push(Json(diff))
    }
  }
  println(
    (
      {
        "format": "moonrobo.learning-artifact-comparison.v1",
        "reference_sha256": Json(@artifacts.sha256(reference)),
        "candidate_sha256": Json(@artifacts.sha256(candidate)),
        "atol": Json(atol),
        "rtol": Json(rtol),
        "passed": Json(failures.is_empty()),
        "differences": Json(failures),
      } : Json).stringify(indent=2),
  )
  guard failures.is_empty() else { fail("learning artifacts differ") }
}
