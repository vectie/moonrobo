///|
priv struct OracleBatch {
  rows : Int32
  physical_steps : Int32
  learner_updates : Int32
  flat : Array[Double]
  window : Array[Double]
  context : Array[Double]
  action : Array[Double]
  value : Array[Double]
  next_aux : Array[Double]
  next_reduced : Array[Double]
} derive(@json.FromJson)

///|
test "trained production weights predict the same actions, values and dynamics as the author modules" {
  guard @env.get_env_var("MOONROBO_GENCOORD_ORACLE") is Some(oracle) else {
    return
  }
  guard @env.get_env_var("MOONROBO_GENCOORD_CHECKPOINT") is Some(root) &&
    @env.get_env_var("MOONROBO_GENCOORD_LAYOUT") is Some(layout) &&
    @env.get_env_var("MOONROBO_TENSOR_LIBRARY") is Some(plugin) else {
    fail(
      "checkpoint oracle requires a checkpoint directory, G1 layout and LibTorch plugin",
    )
  }
  let test_case : OracleBatch = @json.from_json(
    @json.parse(@fs.read_file_to_string(oracle)),
  )
  let b = @tensor.Backend::open(plugin)
  let put = (shape : Array[Int32], v : Array[Double]) => {
    b.from_values(shape, v, cuda_device=-1, dtype=Float32, requires_grad=false)
  }
  guard @json.parse(@fs.read_file_to_string(layout)) is Object(fields) else {
    fail("invalid G1 layout")
  }
  let kin : @aligned.Kinematics = @json.from_json(fields["geometry"])
  let model = GenModel::new(
    b,
    put([29], Array::make(29, 0.0)),
    put([29], Array::make(29, 0.0)),
    context_dim=33,
    device=-1,
    dt=0.02,
    decimation=4,
  )
  let learner = GenLearner::new(model, @geometry.Context::new(b, kin, -1))
  assert_eq(
    learner.load_weights(root),
    (test_case.learner_updates, test_case.physical_steps),
  )
  let n = test_case.rows
  let curr = GenState::from_replay(b, put([n, 71], test_case.flat))
  let goal = curr.goals(b, put([n, 10, 71], test_case.window))
  let ctx = put([n, 33], test_case.context)
  let act = model.act(curr, goal, frozen=true)
  let next = model.step(curr, act, ctx, frozen=true)
  let check = (name : String, tensor : @tensor.Tensor, expect : Array[Double]) => {
    let data = tensor.values()
    assert_eq(data.length(), expect.length())
    let mut peak = 0.0
    for i, x in data {
      let diff = (x - expect[i]).abs()
      assert_true(
        diff <= 0.00002 * (1.0 + expect[i].abs()),
        msg="\{name}[\{i}] actual \{x}, upstream \{expect[i]}",
      )
      peak = peak.max(diff)
    }
    println("\{name} max_abs_error=\{peak} entries=\{data.length()}")
  }
  check("action", act, test_case.action)
  check("critic", model.value(curr, goal, ctx, frozen=true), test_case.value)
  check(
    "next_aux",
    b.concat([next.position, next.quat], axis=1),
    test_case.next_aux,
  )
  check("next_reduced", next.reduced, test_case.next_reduced)
}
