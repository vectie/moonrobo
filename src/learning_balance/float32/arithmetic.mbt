///|
/// Float32-rounded operators, exposing results as Double only at package boundaries. Every arithmetic operator rounds independently, including accumulations and transcendental results.
pub fn round(x : Double) -> Double {
  x.to_float().to_double()
}

///|
fn add(a : Double, b : Double) -> Double {
  (a.to_float() + b.to_float()).to_double()
}

///|
fn sub(a : Double, b : Double) -> Double {
  (a.to_float() - b.to_float()).to_double()
}

///|
fn mul(a : Double, b : Double) -> Double {
  (a.to_float() * b.to_float()).to_double()
}

///|
fn div(a : Double, b : Double) -> Double {
  (a.to_float() / b.to_float()).to_double()
}

///|
fn sqrt(a : Double) -> Double {
  round(round(a).sqrt())
}

///|
fn dot(a : Array[Double], b : Array[Double]) -> Double {
  let mut s = 0.0
  for i in 0..<a.length() {
    s = add(s, mul(a[i], b[i]))
  }
  s
}

///|
fn matvec(a : Array[Double], b : Array[Double]) -> Array[Double] {
  Array::makei(3, fn(i) {
    add(
      add(mul(a[3 * i], b[0]), mul(a[3 * i + 1], b[1])),
      mul(a[3 * i + 2], b[2]),
    )
  })
}

///|
fn matmul(a : Array[Double], b : Array[Double]) -> Array[Double] {
  Array::makei(9, fn(i) {
    let r = i / 3
    let c = i % 3
    add(
      add(mul(a[r * 3], b[c]), mul(a[r * 3 + 1], b[3 + c])),
      mul(a[r * 3 + 2], b[6 + c]),
    )
  })
}

///|
fn skew(v : Array[Double]) -> Array[Double] {
  [
    0.0,
    -round(v[2]),
    round(v[1]),
    round(v[2]),
    0.0,
    -round(v[0]),
    -round(v[1]),
    round(v[0]),
    0.0,
  ]
}

///|
fn quaternion_matrix(q : Array[Double]) -> Array[Double] {
  let n = sqrt(dot(q, q))
  let w = div(q[0], n)
  let x = div(q[1], n)
  let y = div(q[2], n)
  let z = div(q[3], n)
  [
    sub(1.0, mul(2.0, add(mul(y, y), mul(z, z)))),
    mul(2.0, sub(mul(x, y), mul(z, w))),
    mul(2.0, add(mul(x, z), mul(y, w))),
    mul(2.0, add(mul(x, y), mul(z, w))),
    sub(1.0, mul(2.0, add(mul(x, x), mul(z, z)))),
    mul(2.0, sub(mul(y, z), mul(x, w))),
    mul(2.0, sub(mul(x, z), mul(y, w))),
    mul(2.0, add(mul(y, z), mul(x, w))),
    sub(1.0, mul(2.0, add(mul(x, x), mul(y, y)))),
  ]
}

///|
fn rotation_vector(v : Array[Double]) -> Array[Double] {
  let angle = sqrt(dot(v, v))
  let a = if angle == 0.0 { 1.0 } else { div(round(@math.sin(angle)), angle) }
  let half = div(angle, 2.0)
  let sinc_half = if half == 0.0 {
    1.0
  } else {
    div(round(@math.sin(half)), half)
  }
  let b = mul(0.5, mul(sinc_half, sinc_half))
  let k = skew(v)
  let kk = matmul(k, k)
  let id = @balance.identity()
  Array::makei(9, fn(i) { add(add(id[i], mul(a, k[i])), mul(b, kk[i])) })
}
