///|
async test "stream-v2 runner preserves ring histories counters and bits; corruption is atomic" {
  guard @env.get_env_var("MOONROBO_TENSOR_LIBRARY") is Some(path) else {
    println("SKIP stream-v2 runner CPU fixture: set MOONROBO_TENSOR_LIBRARY")
    return
  }
  @async.with_task_group() <| group => {
    let root = @fs.tmpdir(prefix="moonrobo-runtime-v2-")
    group.add_defer(() => @fs.rmdir(root, recursive=true))
    let backend = @tensor.Backend::open(path)
    let (kin, motion, config) = fixture()
    let learner = @gpu.Learner::new(
      backend,
      @geometry.Context::new(backend, kin, -1),
      config~,
    )
    let runner = TrainingRunner::new(learner, motion, 4, 2, seed=17U)
    for i in 0..<6 {
      let tr = transition(motion, i, i)
      tr.s[1] = -0.0
      runner.replay.add([tr, transition(motion, i + 1, i, done=i == 3)])
    }
    runner.histories[0] = Array::makei(2, t => {
      Array::makei(93, j => (t * 93 + j).to_double() / 10.0)
    })
    runner.iteration = 7
    runner.step_accumulator = 0.25
    runner.counters.physical_transitions = 12L
    runner.counters.actor_updates = 2L
    let before = runner.snapshot().to_json()
    let saved = runner.write_snapshot_v2(root)
    assert_eq(saved.replay.rows, 4)
    assert_eq(saved.catalog.sha256, saved.catalog_digest)
    assert_eq(saved.blobs().length(), 6)
    let fresh = TrainingRunner::new(learner, motion, 4, 2, seed=999U)
    let fresh_before = fresh.snapshot().to_json()
    let prepared = fresh.prepare_snapshot_v2(root, saved)
    assert_eq(fresh.snapshot().to_json(), fresh_before)
    try runner.commit_snapshot_v2(prepared, true) catch {
      _ => ()
    } noraise {
      _ => fail("foreign runner accepted restore token")
    }
    assert_eq(runner.snapshot().to_json(), before)
    fresh.commit_snapshot_v2(prepared, true)
    try fresh.commit_snapshot_v2(prepared, true) catch {
      _ => ()
    } noraise {
      _ => fail("consumed restore token was accepted")
    }
    assert_eq(fresh.snapshot().to_json(), before)
    let restored = fresh.replay.snapshot()
    assert_eq(restored[0][0].frame, 2)
    assert_eq(restored[3][1].frame, 6)
    assert_eq(
      restored[0][0].s[1].reinterpret_as_int64(),
      (-0.0).reinterpret_as_int64(),
    )
    assert_true(fresh.histories[1].is_empty())
    let bad_shape = {
      ..saved,
      history_values: { ..saved.history_values, shape: [2, 1, 186], },
    }
    try fresh.restore_v2(root, bad_shape, true) catch {
      _ => ()
    } noraise {
      _ => fail("incompatible history shape accepted")
    }
    assert_eq(fresh.snapshot().to_json(), before)
    let distributed = {
      ..saved,
      distributed: Some({
        rank: 0,
        world_size: 2,
        collection_seed: 17U,
        exact_distributed_resume_supported: false,
      }),
    }
    try fresh.restore_v2(root, distributed, false) catch {
      _ => ()
    } noraise {
      _ => fail("distributed restore accepted")
    }
    assert_eq(fresh.snapshot().to_json(), before)
    fresh.restore_v2(root, saved, false)
    assert_eq(fresh.replay.size(), 0)
    assert_true(fresh.histories.all(h => h.is_empty()))
    assert_eq(fresh.iteration, 7)
    assert_eq(fresh.counters.physical_transitions, 12L)
    assert_eq(fresh.rng.state(), saved.rng)
    let warm_before = fresh.snapshot().to_json()
    let corrupt = @fs.open(
      root + "/" + saved.replay.values.file,
      mode=ReadWrite,
    )
    corrupt.write_at(b"\xff", position=0L)
    corrupt.close()
    for exact in [false, true] {
      try fresh.restore_v2(root, saved, exact) catch {
        _ => ()
      } noraise {
        _ => fail("corrupt replay accepted")
      }
      assert_eq(fresh.snapshot().to_json(), warm_before)
    }
  }
}

///|
async test "stream-v2 empty runner roundtrip and valid-hash invalid transition rejection" {
  guard @env.get_env_var("MOONROBO_TENSOR_LIBRARY") is Some(path) else {
    println("SKIP stream-v2 runner CPU fixture: set MOONROBO_TENSOR_LIBRARY")
    return
  }
  @async.with_task_group() <| group => {
    let root = @fs.tmpdir(prefix="moonrobo-runtime-v2-empty-")
    let bad_root = @fs.tmpdir(prefix="moonrobo-runtime-v2-invalid-")
    group.add_defer(() => @fs.rmdir(root, recursive=true))
    group.add_defer(() => @fs.rmdir(bad_root, recursive=true))
    let backend = @tensor.Backend::open(path)
    let (kin, motion, config) = fixture()
    let learner = @gpu.Learner::new(
      backend,
      @geometry.Context::new(backend, kin, -1),
      config~,
    )
    let runner = TrainingRunner::new(learner, motion, 4, 1)
    let empty = runner.write_snapshot_v2(root)
    assert_eq(empty.replay.values.byte_length, 0L)
    runner.restore_v2(root, empty, true)
    assert_eq(runner.replay.size(), 0)
    // A legitimate checksum is not sufficient: invalid reference indices must
    // fail after staging without changing the existing counters or replay.
    runner.replay.add([{ ..transition(motion, 0, 0), frame: 999, }])
    let invalid = runner.write_snapshot_v2(bad_root)
    runner.restore_v2(root, empty, true)
    let before = runner.snapshot().to_json()
    try runner.restore_v2(bad_root, invalid, true) catch {
      _ => ()
    } noraise {
      _ => fail("invalid reference frame accepted")
    }
    assert_eq(runner.snapshot().to_json(), before)
  }
}
