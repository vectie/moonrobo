///|
test "SDK oracle readback converts world XYZW COM velocity to local WXYZ link state" {
  let half = 0.5.sqrt()
  let q = Array::makei(29, i => i.to_double() * 0.01)
  let qd = Array::makei(29, i => -i.to_double() * 0.02)
  let state = oracle_state71(
    [1.0, 2.0, 3.0, 0.0, 0.0, half, half],
    [0.8, -0.3, 0.4, 0.0, 0.0, 2.0],
    [0.1, 0.0, 0.0],
    q,
    qd,
    [0.2, 0.3, 0.4],
  )
  assert_eq(state.length(), 71)
  for
    (index, expected) in [
      (0, 0.8),
      (1, 1.7),
      (2, 2.6),
      (3, half),
      (4, 0.0),
      (5, 0.0),
      (6, half),
      (7, 1.0),
      (8, -0.3),
      (9, 0.4),
      (12, 2.0),
    ] {
    assert_true((state[index] - expected).abs() < 1.0e-12)
  }
  assert_eq(state[13:42].to_array(), q)
  assert_eq(state[42:71].to_array(), qd)
}

///|
fn oracle_test_operation(
  id : String,
  kind : String,
  ids~ : Array[Int32] = [],
  states71~ : Array[Array[Double]] = [],
  targets~ : Array[Array[Double]] = [],
  context~ : Array[Array[Double]] = [],
) -> OracleOperation {
  { id, kind, ids, states71, targets, context, ground_mu: 0.3, }
}

///|
fn oracle_test_tape(n : Int32) -> OracleTape {
  let state = Array::make(71, 0.0)
  state[3] = 1.0
  let context = Array::make(33, 0.0)
  context[0] = 0.6
  let worlds = oracle_worlds(n)
  let operations = [
    oracle_test_operation(
      "reset-all",
      "reset",
      ids=Array::makei(n, i => i),
      states71=Array::makei(n, _ => state.copy()),
    ),
    oracle_test_operation("empty", "reset"),
    oracle_test_operation(
      "step",
      "step",
      targets=Array::makei(n, _ => Array::make(29, 0.0)),
    ),
    oracle_test_operation("refresh-1", "refresh"),
    oracle_test_operation("refresh-2", "refresh"),
  ]
  for world in worlds {
    operations.push(
      oracle_test_operation("reset-\{world}", "reset", ids=[world], states71=[
        state.copy(),
      ]),
    )
    operations.push(
      oracle_test_operation("context-\{world}", "context", ids=[world], context=[
        context.copy(),
      ]),
    )
  }
  {
    format: "moonrobo.apic-audit-tape.v2",
    num_envs: n,
    selected_worlds: Some(worlds),
    operations,
  }
}

///|
test "SDK oracle v2 validates N4 N8 and rejects unsafe world selections before SDK launch" {
  for n in [4, 8, 128] {
    assert_eq(
      oracle_test_tape(n).validate(n, "fixture", diagnostic=false),
      Some([0, n / 2, n - 1]),
    )
  }
  let valid = oracle_test_tape(4)
  assert_true((try? valid.validate(8, "fixture", diagnostic=false)) is Err(_))
  assert_true((try? valid.validate(4, "fixture", diagnostic=true)) is Err(_))
  assert_true(
    (try? oracle_test_tape(129).validate(129, "fixture", diagnostic=false))
    is Err(_),
  )
  for worlds in [[0, 1, 3], [0, 2, 2], [0, 2, 4]] {
    assert_true(
      (try? { ..valid, selected_worlds: Some(worlds), }.validate(
        4,
        "fixture",
        diagnostic=false,
      ))
      is Err(_),
    )
  }
  let bad = valid.operations.copy()
  bad[0] = { ..bad[0], ids: [0, 0, 2, 3], }
  assert_true(
    (try? { ..valid, operations: bad, }.validate(4, "fixture", diagnostic=false))
    is Err(_),
  )
}

///|
test "paper-4096 SDK oracle requires explicit capacity while retaining selected worlds" {
  let tape = oracle_test_tape(4096)
  assert_true((try? tape.validate(4096, "fixture", diagnostic=false)) is Err(_))
  assert_eq(
    tape.validate(4096, "fixture", diagnostic=false, max_envs=4096),
    Some([0, 2048, 4095]),
  )
  assert_true(
    (try? tape.validate(4096, "fixture", diagnostic=false, max_envs=4095))
    is Err(_),
  )
}

///|
test "SDK oracle rejects malformed payloads excessive steps and v1 SHA changes" {
  let valid = oracle_test_tape(4)
  let bad = valid.operations.copy()
  bad[2] = { ..bad[2], targets: Array::makei(4, _ => Array::make(28, 0.0)), }
  assert_true(
    (try? { ..valid, operations: bad, }.validate(4, "fixture", diagnostic=false))
    is Err(_),
  )
  bad[2] = {
    ..valid.operations[2],
    targets: Array::makei(4, _ => Array::make(29, 1.0 / 0.0)),
  }
  assert_true(
    (try? { ..valid, operations: bad, }.validate(4, "fixture", diagnostic=false))
    is Err(_),
  )
  let many = valid.operations.copy()
  for i in 0..<16 {
    many.push({ ..valid.operations[2], id: "extra-step-\{i}", })
  }
  assert_true(
    (try? { ..valid, operations: many, }.validate(
      4,
      "fixture",
      diagnostic=false,
    ))
    is Err(_),
  )
  let v1 = oracle_test_tape(2)
  while v1.operations.length() < 20 {
    v1.operations.push(
      oracle_test_operation("padding-\{v1.operations.length()}", "refresh"),
    )
  }
  let v1 = {
    ..v1,
    format: "moonrobo.apic-audit-tape.v1",
    selected_worlds: None,
  }
  let sha = "cb4ffbf27aac69d5b539484f85d94273252f1496d5df9796b8c9f4564a1db860"
  assert_eq(v1.validate(2, sha, diagnostic=false), None)
  assert_true((try? v1.validate(2, "changed", diagnostic=false)) is Err(_))
}

///|
async test "APIC payload inventory hashes in bounded chunks and records actual sizes" {
  @async.with_task_group() <| group => {
    let root = @fs.tmpdir(prefix="apic-inventory-")
    group.add_defer(() => @fs.rmdir(root, recursive=true))
    let bytes = Bytes::make(70000, b'\x2a')
    @fs.write_file(root + "/graph.wrp", bytes, create_mode=CreateNew)
    @fs.mkdir(root + "/payload")
    @fs.write_file(root + "/payload/data", b"payload", create_mode=CreateNew)
    let files = []
    let sizes = [0L, 0L]
    inventory(
      root + "/",
      "",
      files,
      sizes,
      @capacity.CapacityProfile::parse("initial").limits(),
    )
    assert_eq(sizes, [70007L, 70000L])
    assert_eq(files.length(), 2)
    assert_true(
      files.any(file => {
        file
        is {
          "path": "graph.wrp",
          "byte_length": "70000",
          "sha256": String(sha),
          ..
        } &&
        sha == @artifacts.sha256(bytes)
      }),
    )
  }
}
