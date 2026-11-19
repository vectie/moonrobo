///|
test "audit collision option defaults false and accepts explicit true or false" {
  assert_eq(requested_self_collisions(["audit", "run"]), false)
  assert_eq(
    requested_self_collisions(["audit", "run", "--self-collisions", "true"]),
    true,
  )
  assert_eq(
    requested_self_collisions(["audit", "run", "--self-collisions", "false"]),
    false,
  )
}

///|
test "audit collision option rejects malformed or duplicate values" {
  for
    args in [
      ["audit", "run", "--self-collisions"],
      ["audit", "run", "--self-collisions", "True"],
      ["audit", "run", "--self-collisions", "1"],
      [
        "audit", "run", "--self-collisions", "true", "--self-collisions", "false",
      ],
    ] {
    try requested_self_collisions(args) catch {
      _ => ()
    } noraise {
      _ => fail("malformed collision option accepted")
    }
  }
}
