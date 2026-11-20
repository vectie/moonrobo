///|
fn heading(rotation : ArrayView[Double]) -> (Double, Double) {
  let vertical = rotation[0] * rotation[0] + rotation[3] * rotation[3] < 1.0e-12
  let x = if vertical { rotation[4] } else { rotation[0] }
  let y = if vertical { -rotation[1] } else { rotation[3] }
  let norm = (x * x + y * y).sqrt().max(1.0e-12)
  (x / norm, y / norm)
}

///|
// The preview is already heading-relative. Only its world-frame reference
// attitude needs the fixed initial yaw alignment; retain the source tilt.
fn heading_alignment(
  measured : ArrayView[Double],
  reference : ArrayView[Double],
) -> Array[Double] {
  let (a, b) = heading(measured)
  let (c, d) = heading(reference)
  [a * c + b * d, b * c - a * d]
}

///|
fn align_heading(
  alignment : ArrayView[Double],
  rotation : ArrayView[Double],
) -> Array[Double] {
  let (c, s) = (alignment[0], alignment[1])
  Array::makei(9, i => {
    let col = i % 3
    match i / 3 {
      0 => c * rotation[col] - s * rotation[3 + col]
      1 => s * rotation[col] + c * rotation[3 + col]
      _ => rotation[i]
    }
  })
}
