///|
test "hard allocator cap changes only the native cache estimate, never physical or host reserves" {
  let i = { ..fixture(), actor_microbatch: 0, world_microbatch: 0, }
  let uncapped = @learning_native_admission.plan_paper_stream(i)
  let guarded = @learning_native_admission.plan_paper_stream(
    i,
    verified_compiled_allocator_cap=21474836480L,
  )
  assert_eq(uncapped.phases.length(), guarded.phases.length())
  for index, p in uncapped.phases {
    let g = guarded.phases[index]
    assert_eq(p.name, g.name)
    assert_eq(p.components.length(), g.components.length())
    for name, n in p.components {
      if name == "device_working_cache_envelope" {
        assert_eq(g.components[name], 28L * 1073741824L)
      } else {
        assert_eq(g.components[name], n)
      }
    }
  }
  let d = @learning_native_admission.assess(
    guarded,
    64L * 1073741824L,
    64L * 1073741824L,
    memory_admission_percent=80,
  )
  assert_true(!d.accepted)
  assert_eq(d.minimum_free_reserve_bytes, 16L * 1073741824L)
  try
    @learning_native_admission.plan_paper_stream(
      i,
      verified_compiled_allocator_cap=1L,
    )
  catch {
    _ => ()
  } noraise {
    _ => fail("forged small cap admitted")
  }
}
