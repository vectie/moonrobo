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
  assert_true(clip.joint_curve_params.length() >= 20)
  assert_true(
    clip.joint_curve_params.any(fn(param) {
      param.name == "knee_swing_lift_rad" && param.value > 0.7
    }),
  )
  assert_true(
    clip.joint_curve_params.any(fn(param) {
      param.name == "arm_phase_lag" && param.value == 0.44
    }),
  )
  assert_eq(clip.authored_joint_samples.length(), clip.sample_count)
  assert_eq(clip.authored_joint_samples[0].phase, 0.0)
  assert_true(
    clip.authored_joint_samples.any(fn(sample) {
      sample.left_knee_rad < -0.75 || sample.right_knee_rad < -0.75
    }),
  )
  assert_eq(clip.authored_motion_samples.length(), clip.sample_count)
  assert_eq(clip.authored_motion_samples[0].phase, 0.0)
  assert_true(
    clip.authored_motion_samples.any(fn(sample) {
      sample.root_bob_m < -0.03 && sample.root_cycle_forward_m > 0.08
    }),
  )
  assert_true(
    clip.authored_motion_samples.any(fn(sample) {
      sample.torso_counter_rotation_rad > 0.12 ||
      sample.torso_counter_rotation_rad < -0.12
    }),
  )
  assert_eq(clip.authored_contact_frames.length(), clip.sample_count)
  assert_eq(clip.authored_contact_frames[0].phase, 0.0)
  assert_true(
    clip.authored_contact_frames.all(fn(frame) {
      frame.contact_count == 2 &&
      frame.active_footprint_count > 0 &&
      frame.status == "moonrobo-authored-contact-frame-ready"
    }),
  )
  assert_true(
    clip.authored_contact_frames.any(fn(frame) {
      frame.center_of_mass_velocity.y > 0.0 &&
      frame.contacts.any(fn(contact) { contact.footprint.active })
    }),
  )
  assert_eq(clip.authored_motor_frames.length(), clip.sample_count)
  assert_true(
    clip.authored_motor_frames.any(fn(frame) { frame.driven_joint_count > 0 }),
  )
  assert_true(
    clip.authored_motor_frames.all(fn(frame) {
      frame.joint_count == clip.required_joint_ids.length() &&
      frame.review_count == 0
    }),
  )
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
  for
    required in [
      "hip_swing_start_rad", "hip_swing_end_rad", "hip_stance_start_rad", "hip_stance_end_rad",
      "knee_base_rad", "knee_swing_lift_rad", "ankle_stance_start_rad", "ankle_stance_end_rad",
      "arm_phase_lag", "shoulder_hip_scale", "elbow_base_rad",
    ] {
    assert_true(
      clip.joint_curve_params.any(fn(param) { param.name == required }),
    )
  }
  for sample in clip.authored_joint_samples {
    assert_true(sample.left_knee_rad <= 0.0)
    assert_true(sample.right_knee_rad <= 0.0)
    assert_true(sample.left_elbow_rad >= 0.0)
    assert_true(sample.right_elbow_rad >= 0.0)
  }
  for sample in clip.authored_motion_samples {
    assert_true(sample.left_foot_x_m > 0.0)
    assert_true(sample.right_foot_x_m < 0.0)
    assert_true(sample.left_foot_y_m < -0.5)
    assert_true(sample.right_foot_y_m < -0.5)
  }
  for frame in clip.authored_contact_frames {
    assert_true(frame.center_of_mass.z > 0.8)
    assert_true(frame.center_of_mass_velocity.y > 0.0)
    for contact in frame.contacts {
      assert_eq(contact.patch.sample_count, 4)
      if contact.footprint.active {
        assert_eq(contact.patch.contact_count, 4)
        assert_eq(contact.patch.status, "patch-contact")
        assert_true(contact.applied_force_n.z > 0.0)
      } else {
        assert_eq(contact.patch.contact_count, 0)
        assert_eq(contact.patch.status, "patch-clear")
      }
    }
  }
  for frame in clip.authored_motor_frames {
    assert_true(frame.max_abs_velocity_rad_s <= 3.0)
    for step in frame.steps {
      assert_true(step.position_within_limits)
      assert_true(step.velocity_within_limits)
      assert_true(!step.torque_saturated)
    }
  }
}
