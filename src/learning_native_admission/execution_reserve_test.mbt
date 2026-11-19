///|
test "execution reserve preserves every baseline phase and the original plan" {
  let baseline = @learning_native_admission.plan_paper_stream(fixture())
  let revised = baseline.with_execution_reserve({ "execution_cache": 123456L })
  assert_eq(revised.peak_bytes, baseline.peak_bytes + 123456L)
  assert_eq(
    revised.minimum_output_free_bytes,
    baseline.minimum_output_free_bytes,
  )
  assert_true(!baseline.counts.contains("execution_cache"))
  for i, p in baseline.phases {
    assert_eq(revised.phases[i].envelope_bytes, p.envelope_bytes + 123456L)
    for name, value in p.components {
      assert_eq(revised.phases[i].components[name], value)
    }
  }
  assert_true(
    (try? baseline.with_execution_reserve({ "execution_negative": -1L }))
    is Err(_),
  )
  assert_true(
    (try? baseline.with_execution_reserve({ "discount": 1L })) is Err(_),
  )
}
