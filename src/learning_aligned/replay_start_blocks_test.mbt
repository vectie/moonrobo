///|
test "actor block API exposes at most 256 starts without changing history padding" {
  let replay = @learning_aligned.ReplayBuffer::new(1, 1)
  let transition : @learning_aligned.Transition = {
    s: Array::make(71, 0.0),
    s1: Array::make(71, 0.0),
    a: Array::make(29, 0.0),
    a_prev: Array::make(29, 0.0),
    xi: Array::make(33, 0.0),
    r: 1.0,
    frame: 7,
    ep_step: 0,
    terminated: false,
    truncated: false,
  }
  replay.add([transition])
  let blocks : Array[Int32] = []
  replay.with_sampled_start_blocks(257, 10, _ => 0, starts => {
    blocks.push(starts.length())
    for start in starts {
      assert_eq(start.start.frame, 7)
      assert_eq(start.history.length(), 10)
      assert_true(start.history.all(past => past.frame == 7))
    }
  })
  assert_eq(blocks, [256, 1])
}
