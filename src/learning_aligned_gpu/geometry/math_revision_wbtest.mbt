///|
fn math_rotation(
  backend : @tensor.Backend,
  t : @tensor.Tensor,
  pitch~ : Bool = false,
) -> @tensor.Tensor raise {
  let c = t.cos()
  let s = t.sin()
  let z = t.affine(0.0)
  let o = z.affine(1.0, bias=1.0)
  if pitch {
    mat(backend, [c, z, s, z, o, z, s.affine(-1.0), z, c])
  } else {
    mat(backend, [o, z, z, z, c, s.affine(-1.0), z, s, c])
  }
}

///|
test "math revision heading full pitch roll and analytic geodesic derivatives" {
  guard @env.get_env_var("MOONROBO_TENSOR_LIBRARY") is Some(path) else {
    println("SKIP math revision gate: set MOONROBO_TENSOR_LIBRARY")
    return
  }
  let b = @tensor.Backend::open(path)
  let scalar = (x : Double, grad : Bool) => {
    b.from_values(
      [1, 1],
      [x],
      dtype=Float64,
      cuda_device=-1,
      requires_grad=grad,
    )
  }
  let eye = math_rotation(b, scalar(0.0, false))
  for pitch in [false, true] {
    for i in -128..<129 {
      let t = scalar(i.to_double() * @math.PI / 64.0, true)
      let h = yaw_mat(b, math_rotation(b, t, pitch~), mode=OrthonormalAtlas)
      for j, x in h.matmul(tr(h)).values() {
        assert_true(
          (x - (if j == 0 || j == 4 || j == 8 { 1.0 } else { 0.0 })).abs() <
          1.0e-12,
        )
      }
      // At inverted equal-length axes the explicit chart seam can choose pi
      // instead of zero. Invertibility, not global smooth yaw, is the contract.
    }
  }
  for
    angle in [
      0.0,
      1.0e-8,
      1.0e-6,
      1.0e-4,
      0.001,
      0.7,
      @math.PI - 1.0e-6,
      @math.PI + 1.0e-6,
    ] {
    let t = scalar(angle, true)
    let loss = angle_square(b, math_rotation(b, t), eye, mode=GeodesicSquared)
    let principal = if angle > @math.PI {
      2.0 * @math.PI - angle
    } else {
      angle
    }
    assert_true((loss.values()[0] - principal * principal).abs() < 1.0e-11)
    loss.sum().backward()
    let expected = 2.0 * principal * (if angle > @math.PI { -1.0 } else { 1.0 })
    assert_true((t.gradient().values()[0] - expected).abs() < 1.0e-9)
    let other = scalar(angle, true)
    let axis = [1.0 / 14.0.sqrt(), 2.0 / 14.0.sqrt(), 3.0 / 14.0.sqrt()]
    let general = angle_square(
      b,
      axis_angle(b, axis, other),
      eye,
      mode=GeodesicSquared,
    )
    general.sum().backward()
    assert_true((general.values()[0] - principal * principal).abs() < 1.0e-10)
    assert_true((other.gradient().values()[0] - expected).abs() < 1.0e-8)
  }
  assert_eq(
    (OrthonormalAtlas : HeadingMode).to_json(),
    Json("OrthonormalAtlas"),
  )
}

///|
test "math revision 32 step analytic gradient through vertical and inverted poses" {
  guard @env.get_env_var("MOONROBO_TENSOR_LIBRARY") is Some(path) else {
    println("SKIP math revision gate: set MOONROBO_TENSOR_LIBRARY")
    return
  }
  let b = @tensor.Backend::open(path)
  let theta = b.from_values(
    [1, 1],
    [0.012],
    dtype=Float64,
    cuda_device=-1,
    requires_grad=true,
  )
  let zero = theta.affine(0.0)
  let delta = columns(b, [theta, theta.affine(0.3), zero.affine(1.0, bias=0.01)])
  let mut p = delta.affine(0.0)
  let mut r = math_rotation(b, zero, pitch=true)
  let increment = math_rotation(
    b,
    theta.affine(1.0 / 32.0, bias=@math.PI / 16.0),
    pitch=true,
  )
  let mut loss = zero.sum()
  let mut expected = 0.0
  for t in 1..<33 {
    let n = t.to_double()
    r = r.matmul(increment)
    let target = math_rotation(
      b,
      zero.affine(1.0, bias=n * @math.PI / 16.0 + 0.012 * n / 32.0 + 0.003),
      pitch=true,
    )
    p = p.add(mv(yaw_mat(b, r, mode=OrthonormalAtlas), delta))
    loss = loss
      .add(p.square().sum())
      .add(angle_square(b, r, target, mode=GeodesicSquared).sum().affine(0.1))
    expected += 2.0 * 1.09 * 0.012 * n * n - 0.0006 * n / 32.0
  }
  loss.backward()
  assert_true((theta.gradient().values()[0] - expected).abs() < 1.0e-8)
  println("math revision cross-step analytic gradient passed")
}
