///|
/// Pending structural regressions. No test/physical algorithm run in migration.
fn example_request() -> Request {
  {
    nworld: 2,
    nv: 3,
    nv_compact: 4,
    njmax: 2,
    mass_nnz: 6,
    jacobian_capacity: 6,
    gather_nnz: 9,
    jacobian_layout: "dense",
    compact: false,
    stable_fast: true,
    kernels: supported_kernels(),
  }
}

///|
test "adapter source uses real entries and sticky status" {
  let l = lower(example_request())
  assert_eq(l.entries.length(), 18)
  assert_true(l.entries.all(e => !e.forward.contains("-")))
  assert_true(!l.source.contains("index(s.status,w)=0"))
  assert_true(l.source.contains("state_changed_count"))
}

///|
test "adapter rejects invalid padded layout and absent actual immutable bytes" {
  let bad = { ..example_request(), nv_compact: 2, }
  assert_true(
    try {
      ignore(lower(bad))
      false
    } catch {
      _ => true
    },
  )
  assert_true(
    try {
      validate_metadata(example_request(), "compact-mass-gather", {})
      false
    } catch {
      _ => true
    },
  )
}

///|
test "source context owns intentional empty optional workspaces" {
  let ws = allocate_solver_context({
    nworld: 2,
    nv: 3,
    nv_pad: 4,
    njmax: 2,
    solver: "newton",
    incremental: true,
  })
  assert_eq(ws.filter(w => w.name == "Mgrad")[0].bytes.length(), 0)
  assert_eq(ws.filter(w => w.name == "grad")[0].bytes.length(), 32)
  let controls = native_control_buffers(2, 4)
  assert_eq(
    controls.filter(w => w.name == "nsolving")[0].bytes,
    b"\x02\x00\x00\x00",
  )
}
