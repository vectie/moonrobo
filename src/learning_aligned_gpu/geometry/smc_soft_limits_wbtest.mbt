///|
test "SMC Float32 soft-limit boundary preserves original ReLU derivative" {
  guard @env.get_env_var("MOONROBO_TENSOR_LIBRARY") is Some(path) else {
    println("SKIP soft-limit gate: set MOONROBO_TENSOR_LIBRARY")
    return
  }
  let backend = @tensor.Backend::open(path)
  let kin : @aligned.Kinematics = {
    bodies: [
      {
        name: "root",
        parent: -1,
        joint: -1,
        axis: [0.0, 0.0, 1.0],
        offset_p: [0.0, 0.0, 0.0],
        offset_rotation: @aligned.identity(),
        pivot: [0.0, 0.0, 0.0],
        qref: 0.0,
      },
    ],
    tracked: [0],
    q_lo: Array::make(29, -0.1),
    q_hi: Array::make(29, 1.1),
  }
  let original = Context::new(backend, kin, -1, dtype=Float32)
  let aligned = original.with_smc_soft_limits()
  // Explicit IEEE Float32 values from SMC's eager midpoint/half-span steps.
  assert_eq(aligned.soft_lo.values(), Array::make(29, -0.04000002145767212))
  assert_eq(aligned.soft_hi.values(), Array::make(29, 1.0399999618530273))
  assert_eq(original.soft_lo.values(), Array::make(29, -0.03999999910593033))
  let q = backend.from_values(
    [1, 29],
    aligned.soft_lo.values(),
    cuda_device=-1,
    dtype=Float32,
    requires_grad=true,
  )
  original.soft_lo.sub(q).relu().sum().backward()
  assert_eq(q.gradient_values(), Array::make(29, -1.0))
  q.zero_gradient()
  aligned.soft_lo.sub(q).relu().sum().backward()
  assert_eq(q.gradient_values(), Array::make(29, 0.0))
}
