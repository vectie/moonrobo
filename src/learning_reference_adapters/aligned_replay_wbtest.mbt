///|
/// Hand-written primitive checkpoint schema; never invokes Python, Torch RNG,
/// MuJoCo, corpus loading, export or training.
fn fixture() -> @artifacts.TorchValue {
  let data : Map[String, @artifacts.TorchValue] = {}
  for
    (name, width) in [
      ("s", 71),
      ("s1", 71),
      ("a", 29),
      ("a_prev", 29),
      ("xi", 33),
    ] {
    data[name] = @artifacts.TorchTensor({
      shape: [2, 2, width],
      dtype: "<f4",
      values: Array::makei(4 * width, i => (i / width).to_double()),
    })
  }
  for
    (name, dtype, values) in [
      ("r", "<f4", [1.0, 2.0, 3.0, 4.0]),
      ("f", "<i8", [8.0, 18.0, 9.0, 30.0]),
      ("ep_step", "<i4", [0.0, 3.0, 1.0, 0.0]),
      ("done", "|b1", [0.0, 1.0, 1.0, 0.0]),
      ("terminated", "|b1", [0.0, 1.0, 0.0, 0.0]),
      ("truncated", "|b1", [0.0, 0.0, 1.0, 0.0]),
    ] {
    data[name] = @artifacts.TorchTensor({ shape: [2, 2], dtype, values, })
  }
  @artifacts.TorchDict({
    "format": @artifacts.TorchString("moonrobo.aligned-checkpoint.v1"),
    "identity": @artifacts.TorchDict({}),
    "config": @artifacts.TorchDict({}),
    "replay": @artifacts.TorchDict({
      "format": @artifacts.TorchString("moonrobo.aligned-replay.v1"),
      "size": @artifacts.TorchInt(2L),
      "capacity": @artifacts.TorchInt(8L),
      "num_envs": @artifacts.TorchInt(2L),
      "data": @artifacts.TorchDict(data),
    }),
  })
}

///|
fn fixture_fields(
  value : @artifacts.TorchValue,
) -> Map[String, @artifacts.TorchValue] raise {
  guard value.field("replay").field("data") is TorchDict(fields) else {
    fail("fixture")
  }
  fields
}

///|
test "original chronological occupied replay preserves environments and termination distinctions" {
  let replay = replay_from_torch(fixture())
  assert_eq(replay.rows.length(), 2)
  assert_eq(replay.rows[0].length(), 2)
  assert_eq(replay.rows[0][1].s[0], 1.0)
  assert_eq(replay.rows[1][0].s[0], 2.0)
  assert_eq(replay.rows[1][1].frame, 30)
  assert_eq(replay.rows[1][0].r, 3.0)
  assert_true(replay.rows[0][1].terminated && !replay.rows[0][1].truncated)
  assert_true(!replay.rows[1][0].terminated && replay.rows[1][0].truncated)
}

///|
test "original replay refuses inconsistent done and absent tensor fields" {
  let input = fixture()
  let fields = fixture_fields(input)
  fields["done"] = @artifacts.TorchTensor({
    shape: [2, 2],
    dtype: "|b1",
    values: [0.0, 0.0, 1.0, 0.0],
  })
  assert_true(
    try {
      ignore(replay_from_torch(input))
      false
    } catch {
      _ => true
    },
  )
  fields["done"] = @artifacts.TorchTensor({
    shape: [2, 2],
    dtype: "|b1",
    values: [0.0, 1.0, 1.0, 0.0],
  })
  fields.remove("a_prev")
  assert_true(
    try {
      ignore(replay_from_torch(input))
      false
    } catch {
      _ => true
    },
  )
}

///|
test "original replay refuses fractional frames wrong dtype and tensor dimensions" {
  let input = fixture()
  let fields = fixture_fields(input)
  fields["f"] = @artifacts.TorchTensor({
    shape: [2, 2],
    dtype: "<i8",
    values: [8.5, 18.0, 9.0, 30.0],
  })
  assert_true(
    try {
      ignore(replay_from_torch(input))
      false
    } catch {
      _ => true
    },
  )
  fields["f"] = @artifacts.TorchTensor({
    shape: [2, 2],
    dtype: "<f4",
    values: [8.0, 18.0, 9.0, 30.0],
  })
  assert_true(
    try {
      ignore(replay_from_torch(input))
      false
    } catch {
      _ => true
    },
  )
  fields["f"] = @artifacts.TorchTensor({
    shape: [2, 2],
    dtype: "<i8",
    values: [8.0, 18.0, 9.0, 30.0],
  })
  fields["s"] = @artifacts.TorchTensor({
    shape: [2, 2, 70],
    dtype: "<f4",
    values: Array::make(280, 0.0),
  })
  assert_true(
    try {
      ignore(replay_from_torch(input))
      false
    } catch {
      _ => true
    },
  )
}
