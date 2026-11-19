///|
fn smc_backend() -> @learning_tensor.Backend? raise {
  guard @env.get_env_var("MOONROBO_TENSOR_LIBRARY") is Some(path) else {
    println("SKIP SMC algebra")
    return None
  }
  let backend = @learning_tensor.Backend::open(path)
  assert_true(backend.has_smc_algebra())
  Some(backend)
}

///|
test "SMC rotation vector identity derivatives and pi values" {
  guard smc_backend() is Some(b) else { return }
  let identity = [1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0]
  let r = b.from_values(
    [1, 3, 3],
    identity,
    cuda_device=-1,
    requires_grad=true,
    dtype=Float64,
  )
  let v = r.rotation_vector_smc()
  assert_eq(v.values(), [0.0, 0.0, 0.0])
  v.sum().backward()
  let expected = [0.0, -0.5, 0.5, 0.5, 0.0, -0.5, -0.5, 0.5, 0.0]
  for i, x in r.gradient_values() {
    assert_true((x - expected[i]).abs() < 1.0e-12)
  }
  let pi = b.from_values(
    [1, 3, 3],
    [1.0, 0.0, 0.0, 0.0, -1.0, 0.0, 0.0, 0.0, -1.0],
    cuda_device=-1,
    requires_grad=true,
    dtype=Float64,
  )
  let p = pi.rotation_vector_smc()
  // SMC deliberately adds 1e-12 to sin_half in the large-angle branch.
  assert_true(
    (p.values()[0] - 3.141592653589793 / (1.0 + 1.0e-12)).abs() < 1.0e-14,
  )
  p.sum().backward()
  assert_true(pi.gradient_values().all(x => x == x && x.abs() < 1.0e20))
  let invalid = b.from_values(
    [3, 3],
    identity,
    cuda_device=-1,
    requires_grad=false,
    dtype=Float64,
  )
  try invalid.rotation_vector_smc() catch {
    _ => ()
  } noraise {
    _ => fail("accepted invalid shape")
  }
}

///|
test "SMC xi normalization values and derivatives" {
  guard smc_backend() is Some(b) else { return }
  let x = b.from_values(
    [2, 33],
    Array::makei(66, i => (i + 1).to_double() / 41.0),
    cuda_device=-1,
    requires_grad=true,
    dtype=Float64,
  )
  let y = x.normalize_xi_smc()
  let values = x.values()
  for i, v in y.values() {
    let j = i % 33
    let expected = if j == 0 {
      (values[i] - 0.75) / 0.45
    } else if j < 30 {
      values[i] / 0.01
    } else {
      values[i] / 0.05
    }
    assert_true((v - expected).abs() < 1.0e-12)
  }
  y.sum().backward()
  for i, v in x.gradient_values() {
    let expected = if i % 33 == 0 {
      1.0 / 0.45
    } else if i % 33 < 30 {
      100.0
    } else {
      20.0
    }
    assert_true((v - expected).abs() < 1.0e-12)
  }
}

///|
fn smc_scalar_return(
  r : Array[Double],
  d : Array[Double],
  v : Array[Double],
) -> Array[Double] {
  let ret = Array::make(2, 0.0)
  let sums = Array::make(2, 0.0)
  let alive = Array::make(2, 1.0)
  for t in 0..<3 {
    for j in 0..<2 {
      sums[j] += alive[j] * r[t * 2 + j]
      ret[j] += [1.0, 0.5, 0.25][t] * alive[j] * r[t * 2 + j]
      alive[j] *= 1.0 - d[t * 2 + j]
    }
  }
  for j in 0..<2 {
    ret[j] += 0.125 * alive[j] * v[j]
  }
  [..ret, ..sums, ..alive]
}

///|
test "SMC cumulative return preserves tail and gradients through zero survival" {
  guard smc_backend() is Some(b) else { return }
  let rewards = [0.2, 0.4, 0.6, 0.8, 1.0, 1.2]
  let failures = [0.0, 0.25, 1.0, 0.5, 0.2, 0.0]
  let tail = [1.4, 1.6]
  let r = b.from_values(
    [3, 2],
    rewards,
    cuda_device=-1,
    requires_grad=true,
    dtype=Float64,
  )
  let d = b.from_values(
    [3, 2],
    failures,
    cuda_device=-1,
    requires_grad=true,
    dtype=Float64,
  )
  let t = b.from_values(
    [2],
    tail,
    cuda_device=-1,
    requires_grad=true,
    dtype=Float64,
  )
  let actual = r.actor_return_smc(d, t, 0.5)
  let expected = smc_scalar_return(rewards, failures, tail)
  for i, v in actual.values() {
    assert_true((v - expected[i]).abs() < 1.0e-12)
  }
  actual.narrow(0, 0, 1).sum().backward()
  for
    (which, tensor, values) in [(0, r, rewards), (1, d, failures), (2, t, tail)] {
    for i, g in tensor.gradient_values() {
      let a = values.copy()
      let c = values.copy()
      a[i] += 1.0e-6
      c[i] -= 1.0e-6
      let sa = match which {
        0 => smc_scalar_return(a, failures, tail)
        1 => smc_scalar_return(rewards, a, tail)
        _ => smc_scalar_return(rewards, failures, a)
      }
      let sc = match which {
        0 => smc_scalar_return(c, failures, tail)
        1 => smc_scalar_return(rewards, c, tail)
        _ => smc_scalar_return(rewards, failures, c)
      }
      assert_true((g - (sa[0] + sa[1] - sc[0] - sc[1]) / 2.0e-6).abs() < 1.0e-9)
    }
  }
  try r.actor_return_smc(d, t, 1.1) catch {
    _ => ()
  } noraise {
    _ => fail("invalid gamma")
  }
}
