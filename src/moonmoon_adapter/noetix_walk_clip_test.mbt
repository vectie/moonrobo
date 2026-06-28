///|
test "Noetix Moonmoon walk clip records endless forward gait authority" {
  let clip = noetix_e1_moonmoon_walk_clip_contract()
  assert_true(clip.ready)
  assert_eq(clip.status, "moonmoon-noetix-walk-clip-ready")
  assert_eq(clip.clip_id, "noetix-e1-lab-01/endless-forward-walk")
  assert_eq(clip.sample_count, 24)
  assert_eq(clip.cycle_hz, 0.46)
  assert_eq(clip.root_speed_mps, 0.18)
  assert_eq(clip.stride_m, 0.38)
  assert_eq(clip.foot_phase_sequence.length(), 6)
  assert_true(clip.foot_phase_sequence.contains("contact"))
  assert_true(clip.foot_phase_sequence.contains("stance"))
  assert_true(clip.foot_phase_sequence.contains("swing"))
  assert_true(clip.phase_labels.contains("left-stance-right-swing"))
  assert_true(clip.phase_labels.contains("right-stance-left-swing"))
  assert_eq(clip.required_joint_ids.length(), 10)
  assert_true(clip.required_joint_ids.contains("leg_l4_joint"))
  assert_true(clip.required_joint_ids.contains("arm_r4_joint"))
}

///|
test "Noetix Moonmoon walk clip anchors all required motion joints" {
  let clip = noetix_e1_moonmoon_walk_clip_contract()
  for joint_id in clip.required_joint_ids {
    assert_true(
      clip.joint_anchors.any(fn(anchor) { anchor.joint_id == joint_id }),
    )
  }
  assert_true(
    clip.foot_phase_specs.any(fn(spec) {
      spec.role == "stance" && spec.support && spec.lock_window
    }),
  )
  assert_true(
    clip.foot_phase_specs.any(fn(spec) {
      spec.role == "swing" && !spec.support && !spec.lock_window
    }),
  )
}
