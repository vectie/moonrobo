///|
test "stationary preview preserves trained channel order and inactive padding" {
  let rotation = [0.0, -1.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 1.0]
  let positions = Array::makei(23, i => i.to_double() / 100.0)
  let goals = hold_preview(positions[:], rotation[:])
  assert_eq(goals.length(), 730)
  for frame in 0..<10 {
    let offset = frame * 73
    assert_eq(goals[offset:offset + 3].to_owned(), [0.0, 0.0, 0.0])
    assert_eq(goals[offset + 3:offset + 9].to_owned(), [
      1.0, 0.0, 0.0, 1.0, 0.0, 0.0,
    ])
    assert_eq(goals[offset + 15:offset + 38].to_owned(), positions)
    assert_true(goals[offset + 38:offset + 73].iter().all(x => x == 0.0))
  }
}

///|
test "stationary preview retains roll and handles a vertical forward axis" {
  let a = 0.5.sqrt()
  let rolled = [1.0, 0.0, 0.0, 0.0, a, -a, 0.0, a, a]
  let goal = hold_preview(Array::make(23, 0.0)[:], rolled[:])
  assert_eq(goal[3:9].to_owned(), [1.0, 0.0, 0.0, a, 0.0, a])
  let vertical = [0.0, 0.0, 1.0, 0.0, 1.0, 0.0, -1.0, 0.0, 0.0]
  let goal = hold_preview(Array::make(23, 0.0)[:], vertical[:])
  assert_eq(goal[3:9].to_owned(), [0.0, 0.0, 0.0, 1.0, -1.0, 0.0])
}

///|
test "prepared reference alignment changes heading while retaining tilt" {
  let a = 0.5.sqrt()
  let reference = [1.0, 0.0, 0.0, 0.0, a, -a, 0.0, a, a]
  let measured = [0.0, -1.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 1.0]
  let alignment = heading_alignment(measured[:], reference[:])
  assert_eq(alignment, [0.0, 1.0])
  assert_eq(align_heading(alignment[:], reference[:]), [
    0.0,
    -a,
    a,
    1.0,
    0.0,
    0.0,
    0.0,
    a,
    a,
  ])
}
