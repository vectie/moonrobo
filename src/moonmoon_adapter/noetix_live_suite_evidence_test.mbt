///|
test "Noetix Moonmoon live suite evidence regenerates from typed adapter" {
  let evidence = noetix_e1_moonmoon_live_suite_evidence()
  assert_true(evidence.ready)
  assert_eq(evidence.status, "moonmoon-noetix-live-suite-evidence-ready")
  assert_eq(evidence.regeneration_mode, "live-moonrobo-typed-adapter")
  assert_eq(
    evidence.contract_id,
    "noetix-e1-lab-01/moonmoon-locomotion-source-contract",
  )
  assert_eq(evidence.walk_clip_id, "noetix-e1-lab-01/endless-forward-walk")
  assert_eq(evidence.sample_count, 24)
  assert_eq(evidence.profile_joint_count, 24)
  assert_eq(evidence.required_motion_joint_count, 10)
  assert_eq(evidence.authored_joint_sample_count, evidence.sample_count)
  assert_eq(evidence.authored_motion_sample_count, evidence.sample_count)
  assert_eq(evidence.authored_contact_frame_count, evidence.sample_count)
  assert_eq(evidence.authored_motor_frame_count, evidence.sample_count)
  assert_eq(evidence.active_contact_frame_count, evidence.sample_count)
  assert_true(evidence.loaded_contact_count >= evidence.sample_count)
  assert_eq(evidence.driven_motor_frame_count, evidence.sample_count)
  assert_eq(evidence.motor_review_count, 0)
  assert_eq(evidence.contact_review_count, 0)
  assert_eq(evidence.blocker_count, 0)
}
