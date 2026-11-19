///|
fn stream_transition(i : Int32) -> Transition {
  {
    s: Array::makei(71, j => {
      if j == 1 {
        -0.0
      } else {
        (i * 71 + j).to_double() / 7.0
      }
    }),
    s1: Array::makei(71, j => (i * 71 + j + 1).to_double() / 11.0),
    a: Array::make(29, i.to_double()),
    a_prev: Array::make(29, -i.to_double()),
    xi: Array::makei(33, j => j.to_double() / 10.0),
    r: i.to_double() / 13.0,
    frame: i,
    ep_step: i % 7,
    terminated: i % 7 == 6,
    truncated: i % 11 == 10,
  }
}

///|
async test "stream-v2 replay crosses chunks without changing ring order or bits" {
  @async.with_task_group() <| group => {
    let root = @fs.tmpdir(prefix="moonrobo-replay-v2-")
    group.add_defer(() => @fs.rmdir(root, recursive=true))
    let replay = ReplayBuffer::new(40, 2)
    for i in 0..<45 {
      replay.add([stream_transition(i), stream_transition(i + 100)])
    }
    let saved = replay.write_checkpoint_v2(root)
    assert_true(saved.values.byte_length > 65536L)
    let target = ReplayBuffer::new(40, 2)
    target.add([stream_transition(999), stream_transition(999)])
    let prior = target.snapshot().to_json()
    let count = [0]
    let staged = target.prepare_checkpoint_v2(root, saved, tr => {
      assert_true(tr.frame >= 5 && tr.frame < 145)
      count[0] += 1
    })
    assert_eq(count[0], 80)
    assert_eq(target.snapshot().to_json(), prior)
    target.commit_checkpoint_v2(staged)
    assert_eq(target.snapshot().to_json(), replay.snapshot().to_json())
    for row in target.snapshot() {
      for tr in row {
        assert_eq(tr.s[1].reinterpret_as_int64(), (-0.0).reinterpret_as_int64())
      }
    }
    // Later-row business validation failure must leave the previous live ring.
    let stable = target.snapshot().to_json()
    try
      target.prepare_checkpoint_v2(root, saved, tr => {
        guard tr.frame < 140 else { fail("synthetic late business rejection") }
      })
    catch {
      _ => ()
    } noraise {
      _ => fail("late validation did not reject")
    }
    assert_eq(target.snapshot().to_json(), stable)
  }
}

///|
async test "stream-v2 sampler snapshots direct arrays and commits only fully verified state" {
  @async.with_task_group() <| group => {
    let root = @fs.tmpdir(prefix="moonrobo-sampler-v2-")
    group.add_defer(() => @fs.rmdir(root, recursive=true))
    let bins : Array[ResetBin] = [
      { start: 0, clip_end: 100, },
      { start: 50, clip_end: 100, },
    ]
    let sampler = ReturnBinSampler::new(bins)
    sampler.update([
      { bin: 0, discounted_return: 3.0, bootstrap: Some((4, 0.25, false)), },
    ])
    ignore(sampler.probabilities(update_average=true))
    let saved = sampler.write_checkpoint_v2(root)
    let target = ReturnBinSampler::new(bins)
    let prior = target.snapshot()
    let staged = target.prepare_checkpoint_v2(root, saved)
    assert_eq(target.snapshot(), prior)
    target.commit_checkpoint_v2(staged)
    assert_eq(target.snapshot(), sampler.snapshot())
    assert_eq(target.probabilities(), sampler.probabilities())
    let stable = target.snapshot()
    let corrupt = @fs.open(root + "/" + saved.completed.file, mode=ReadWrite)
    corrupt.write_at(b"\xff", position=0L)
    corrupt.close()
    try target.prepare_checkpoint_v2(root, saved) catch {
      _ => ()
    } noraise {
      _ => fail("corrupt sampler accepted")
    }
    assert_eq(target.snapshot(), stable)
  }
}
