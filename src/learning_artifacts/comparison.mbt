///|
pub(all) struct Difference {
  path : String
  reason : String
} derive(Debug, ToJson)

///|
/// Compare exported numeric arrays using |candidate-reference| <= atol+rtol*|reference|.
/// Both shapes and array lengths must agree; nonfinite values always fail.
pub fn compare_numeric(
  reference : NumericArray,
  candidate : NumericArray,
  atol~ : Double = 1.0e-6,
  rtol~ : Double = 1.0e-5,
) -> Array[Difference] raise {
  guard atol >= 0 &&
    rtol >= 0 &&
    atol.abs() <= 1.7976931348623157e308 &&
    rtol.abs() <= 1.7976931348623157e308 else {
    fail("finite nonnegative tolerances required")
  }
  let differences : Array[Difference] = []
  if reference.shape != candidate.shape ||
    reference.values.length() != candidate.values.length() {
    differences.push({ path: "$", reason: "tensor shape differs", })
    return differences
  }
  for i, expected in reference.values {
    let actual = candidate.values[i]
    if !(expected.abs() <= 1.7976931348623157e308 &&
      actual.abs() <= 1.7976931348623157e308) ||
      (actual - expected).abs() > atol + rtol * expected.abs() {
      differences.push({
        path: "$[\{i}]",
        reason: "\{actual} differs from \{expected}",
      })
      if differences.length() == 100 {
        break
      }
    }
  }
  differences
}

///|
pub fn compare_json(
  reference : Json,
  candidate : Json,
  atol~ : Double = 1.0e-6,
  rtol~ : Double = 1.0e-5,
) -> Array[Difference] raise {
  guard atol >= 0 &&
    rtol >= 0 &&
    atol.abs() <= 1.7976931348623157e308 &&
    rtol.abs() <= 1.7976931348623157e308 else {
    fail("finite nonnegative tolerances required")
  }
  let differences : Array[Difference] = []
  compare_json_at(reference, candidate, "$", atol, rtol, differences, 0)
  differences
}

///|
fn compare_json_at(
  reference : Json,
  candidate : Json,
  path : String,
  atol : Double,
  rtol : Double,
  differences : Array[Difference],
  depth : Int32,
) -> Unit raise {
  guard depth <= 256 else { fail("JSON comparison nesting exceeds 256") }
  if differences.length() >= 100 {
    return
  }
  match (reference, candidate) {
    (Number(expected, ..), Number(actual, ..)) =>
      if !(expected.abs() <= 1.7976931348623157e308 &&
        actual.abs() <= 1.7976931348623157e308) ||
        (actual - expected).abs() > atol + rtol * expected.abs() {
        differences.push({ path, reason: "\{actual} differs from \{expected}", })
      }
    (Array(expected), Array(actual)) => {
      if expected.length() != actual.length() {
        differences.push({ path, reason: "array length differs", })
        return
      }
      for i in 0..<expected.length() {
        compare_json_at(
          expected[i],
          actual[i],
          path + "[\{i}]",
          atol,
          rtol,
          differences,
          depth + 1,
        )
      }
    }
    (Object(expected), Object(actual)) => {
      if expected.size() != actual.size() {
        differences.push({ path, reason: "object field count differs", })
      }
      let keys = expected.keys().collect()
      keys.sort()
      for key in keys {
        match actual.get(key) {
          None =>
            differences.push({
              path: path + "." + key,
              reason: "missing candidate field",
            })
          Some(value) =>
            compare_json_at(
              expected.get(key).unwrap(),
              value,
              path + "." + key,
              atol,
              rtol,
              differences,
              depth + 1,
            )
        }
      }
    }
    _ =>
      if reference != candidate {
        differences.push({ path, reason: "value or type differs", })
      }
  }
}
