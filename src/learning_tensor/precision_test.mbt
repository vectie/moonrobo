///|
fn precision_round_bf16(value : Double) -> Double {
  let bits = Float::from_double(value).reinterpret_as_uint()
  let rounded = (bits + 0x7fffU + ((bits >> 16) & 1U)) & 0xffff0000U
  Float::reinterpret_from_uint(rounded).to_double()
}

///|
fn precision_device() -> Int32 raise {
  match @env.get_env_var("MOONROBO_OPTIMIZATION_TEST_DEVICE") {
    None | Some("cpu") => -1
    Some("cuda:0") => 0
    _ => fail("MOONROBO_OPTIMIZATION_TEST_DEVICE must be cpu or cuda:0")
  }
}

///|
fn precision_exact(
  actual : Array[Double],
  expected : Array[Double],
  label : String,
) -> Unit raise {
  assert_eq(actual.length(), expected.length())
  for i in 0..<actual.length() {
    guard !actual[i].is_nan() && !actual[i].is_inf() && actual[i] == expected[i] else {
      fail("BF16 primitive \{label}[\{i}]: \{actual[i]} vs \{expected[i]}")
    }
  }
}

///|
test "BF16 Linear has independently rounded forward gradients and FP32 Adam across four updates" {
  let device = precision_device()
  guard @env.get_env_var("MOONROBO_TENSOR_LIBRARY") is Some(path) else {
    guard device < 0 else {
      fail("explicit CUDA precision test requires plugin")
    }
    println("SKIP BF16 precision primitive: set MOONROBO_TENSOR_LIBRARY")
    return
  }
  let backend = @learning_tensor.Backend::open(path)
  assert_true(backend.has_bf16_linear())
  let make = (shape, values, grad) => {
    backend.from_values(
      shape,
      values,
      cuda_device=device,
      requires_grad=grad,
      dtype=Float32,
    )
  }
  let xv = [0.11, -0.27, 0.39, -0.43, 0.58, 0.67]
  let wv = [0.21, -0.34, 0.46, -0.51, 0.62, 0.73]
  let bv = [0.13, -0.19]
  let upstream = [0.25, -0.5, 0.75, 0.125]
  let x = make([2, 3], xv, true)
  let w = make([2, 3], wv, true)
  let b = make([2], bv, true)
  let rw = make([2, 3], wv, true)
  let rb = make([2], bv, true)
  let g = make([2, 2], upstream, false)
  let opt = backend.adam([w, b], learning_rate=0.03125)
  let reference = backend.adam([rw, rb], learning_rate=0.03125)
  let xq = xv.map(precision_round_bf16)
  let wg = Array::makei(6, i => {
    precision_round_bf16(
      xq[i % 3] * upstream[i / 3] + xq[3 + i % 3] * upstream[2 + i / 3],
    )
  })
  let bg = [
    precision_round_bf16(upstream[0] + upstream[2]),
    precision_round_bf16(upstream[1] + upstream[3]),
  ]
  for iteration in 0..<4 {
    opt.zero_grad()
    reference.zero_grad()
    x.zero_gradient()
    let wq = rw.values().map(precision_round_bf16)
    let bq = rb.values().map(precision_round_bf16)
    let expected = Array::makei(4, i => {
      let row = i / 2
      let out = i % 2
      precision_round_bf16(
        bq[out] +
        xq[row * 3] * wq[out * 3] +
        xq[row * 3 + 1] * wq[out * 3 + 1] +
        xq[row * 3 + 2] * wq[out * 3 + 2],
      )
    })
    let y = x.linear_bf16(w, b)
    assert_eq(y.dtype(), BFloat16)
    precision_exact(y.values(), expected, "forward iteration \{iteration}")
    let fp32 = y.cast_float(Float32)
    assert_eq(fp32.dtype(), Float32)
    fp32.mul(g).sum().backward()
    rw
    .mul(make([2, 3], wg, false))
    .sum()
    .add(rb.mul(make([2], bg, false)).sum())
    .backward()
    precision_exact(w.gradient_values(), wg, "weight gradient \{iteration}")
    precision_exact(b.gradient_values(), bg, "bias gradient \{iteration}")
    let xg = Array::makei(6, i => {
      precision_round_bf16(
        wq[i % 3] * upstream[i / 3 * 2] +
        wq[3 + i % 3] * upstream[i / 3 * 2 + 1],
      )
    })
    precision_exact(x.gradient_values(), xg, "input gradient \{iteration}")
    for parameter in [x, w, b] {
      assert_eq(parameter.dtype(), Float32)
      assert_eq(parameter.gradient().dtype(), Float32)
    }
    // Ordinary ops after the call must not inherit its autocast setting.
    assert_eq(x.matmul(w.transpose()).dtype(), Float32)
    opt.step(clip_norm=1.0, clip_value=0.5)
    reference.step(clip_norm=1.0, clip_value=0.5)
    assert_eq(opt.audit_metadata(), reference.audit_metadata())
    for parameter in 0..<2 {
      for kind in 0..<3 {
        let actual = opt.audit_tensor(parameter, kind~)
        assert_eq(actual.dtype(), Float32)
        precision_exact(
          actual.values(),
          reference.audit_tensor(parameter, kind~).values(),
          "Adam \{iteration}/\{parameter}/\{kind}",
        )
      }
    }
  }
  // Mixed precision retains the existing fail-before-mutation Adam contract.
  let before = opt.audit_metadata()
  let snapshots = Array::makei(6, i => {
    opt.audit_tensor(i / 3, kind=i % 3).values()
  })
  opt.zero_grad()
  x.linear_bf16(w, b).cast_float(Float32).affine(0.0 / 0.0).sum().backward()
  try opt.step(clip_norm=1.0) catch {
    _ => ()
  } noraise {
    _ => fail("nonfinite BF16 gradient accepted")
  }
  assert_eq(opt.audit_metadata(), before)
  for i in 0..<6 {
    precision_exact(
      opt.audit_tensor(i / 3, kind=i % 3).values(),
      snapshots[i],
      "nonfinite rejection state",
    )
  }
}

///|
test "precision extension validates casts contracts and legacy capability" {
  let device = precision_device()
  guard @env.get_env_var("MOONROBO_TENSOR_LIBRARY") is Some(path) else {
    guard device < 0 else {
      fail("explicit CUDA precision test requires plugin")
    }
    return
  }
  let backend = @learning_tensor.Backend::open(path)
  let x = backend.from_values(
    [2, 3],
    [0.1, 0.2, 0.3, 0.4, 0.5, 0.6],
    cuda_device=device,
    requires_grad=true,
    dtype=Float32,
  )
  x.cast_float(BFloat16).cast_float(Float32).sum().backward()
  precision_exact(
    x.gradient_values(),
    Array::make(6, 1.0),
    "cast chain input gradient",
  )
  for dtype in [@learning_tensor.Int64, @learning_tensor.Bool] {
    try x.cast_float(dtype) catch {
      _ => ()
    } noraise {
      _ => fail("nonfloating cast accepted")
    }
  }
  let w = backend.from_values(
    [1, 3],
    [0.1, 0.2, 0.3],
    cuda_device=device,
    requires_grad=true,
    dtype=Float32,
  )
  let b = backend.from_values(
    [1],
    [0.0],
    cuda_device=device,
    requires_grad=true,
    dtype=Float32,
  )
  try x.linear_bf16(w.cast_float(BFloat16), b) catch {
    _ => ()
  } noraise {
    _ => fail("non-FP32 master weight accepted")
  }
  try x.cast_float(Float64).linear_bf16(w, b) catch {
    _ => ()
  } noraise {
    _ => fail("FP64 BF16-linear input accepted")
  }
  try x.linear_bf16(w, x) catch {
    _ => ()
  } noraise {
    _ => fail("invalid bias shape accepted")
  }
  assert_eq(x.matmul(w.transpose()).dtype(), Float32)
  if @env.get_env_var("MOONROBO_LEGACY_TENSOR_LIBRARY") is Some(path) {
    let legacy = @learning_tensor.Backend::open(path)
    assert_false(legacy.has_bf16_linear())
    let old = legacy.from_values(
      [1, 1],
      [1.0],
      cuda_device=-1,
      requires_grad=false,
      dtype=Float32,
    )
    precision_exact(
      old.matmul(old).values(),
      [1.0],
      "legacy FP32 remains usable",
    )
    try old.cast_float(BFloat16) catch {
      _ => ()
    } noraise {
      _ => fail("legacy plugin cast must fail explicitly")
    }
  }
}
