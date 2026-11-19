///|
test "pooled normalizer includes between-rank variance and accumulated count" {
  guard @env.get_env_var("MOONROBO_TENSOR_LIBRARY") is Some(path) else {
    println("SKIP pooled-normalizer CPU check: set MOONROBO_TENSOR_LIBRARY")
    return
  }
  let backend = @tensor.Backend::open(path)
  let norm = RunningNorm::new(backend, 1)
  let constant = (value : Double) => {
    backend.from_values(
      [1],
      [value],
      cuda_device=-1,
      requires_grad=false,
      dtype=Float32,
    )
  }
  // Rank A has [0,2], rank B has [8,10]. Mean(var_per_rank)=1 is wrong;
  // the pooled population variance is 17, including the differing means.
  norm.merge_raw_moments(constant(20.0), constant(168.0), 4.0)
  assert_eq(norm.count, 4.0)
  assert_eq(norm.mean.values(), [5.0])
  assert_eq(norm.variance.values(), [17.0])
  norm.merge_raw_moments(constant(0.0), constant(0.0), 0.0)
  assert_eq(norm.count, 4.0)
  norm.merge_raw_moments(constant(10.0), constant(50.0), 2.0)
  assert_eq(norm.mean.values(), [5.0])
  assert_eq(norm.count, 6.0)
  assert_true((norm.variance.values()[0] - 68.0 / 6.0).abs() < 0.00001)
  assert_eq(rank_seed(123U, None), 123U)
}
