///|
test "writer diagnostics compare every actual output exactly" {
  let original : Json = {
    "effort": { "available": true, "values": [[1.0, 2.0], [3.0, 4.0]] },
    "position": { "available": true, "values": [[0.0, 0.1], [0.2, 0.3]] },
  }
  let same = diagnostic_exact_checks(original, original)
  assert_true(same.all(c => c is { "exactly_equal": true, .. }))
  let missing_write : Json = {
    "effort": { "available": true, "values": [[1.0, 2.0], [3.0, 32.0]] },
    "position": { "available": true, "values": [[0.0, 0.1], [0.2, 0.3]] },
  }
  let changed = diagnostic_exact_checks(missing_write, original)
  assert_true(
    changed.any(c => c is { "field": "effort", "exactly_equal": false, .. }),
  )
}
