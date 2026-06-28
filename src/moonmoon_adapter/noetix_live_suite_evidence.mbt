///|
pub(all) struct MoonmoonNoetixLiveSuiteEvidence {
  evidence_id : String
  regeneration_mode : String
  contract_id : String
  robot_id : String
  walk_clip_id : String
  source : String
  sample_count : Int
  profile_joint_count : Int
  required_motion_joint_count : Int
  authored_joint_sample_count : Int
  authored_motion_sample_count : Int
  authored_contact_frame_count : Int
  authored_motor_frame_count : Int
  active_contact_frame_count : Int
  loaded_contact_count : Int
  driven_motor_frame_count : Int
  motor_review_count : Int
  contact_review_count : Int
  blocker_count : Int
  blockers : Array[String]
  ready : Bool
  status : String
} derive(Debug, Eq, ToJson, FromJson)

///|
fn noetix_live_suite_evidence_blockers(
  contract : MoonmoonNoetixLocomotionContract,
) -> Array[String] {
  let blockers : Array[String] = []
  if !contract.ready {
    blockers.push("contract:\{contract.status}")
  }
  for blocker in contract.blockers {
    blockers.push("contract-blocker:\{blocker}")
  }
  let clip = contract.walk_clip
  if !clip.ready {
    blockers.push("walk-clip:\{clip.status}")
  }
  for blocker in clip.blockers {
    blockers.push("walk-clip-blocker:\{blocker}")
  }
  if clip.authored_joint_samples.length() != clip.sample_count {
    blockers.push("authored-joint-sample-count")
  }
  if clip.authored_motion_samples.length() != clip.sample_count {
    blockers.push("authored-motion-sample-count")
  }
  if clip.authored_contact_frames.length() != clip.sample_count {
    blockers.push("authored-contact-frame-count")
  }
  if clip.authored_motor_frames.length() != clip.sample_count {
    blockers.push("authored-motor-frame-count")
  }
  for frame in clip.authored_contact_frames {
    if frame.active_footprint_count <= 0 || frame.status.contains("review") {
      blockers.push("contact-frame-review:\{frame.frame_index}")
    }
  }
  for frame in clip.authored_motor_frames {
    if frame.review_count > 0 || frame.status.contains("review") {
      blockers.push("motor-frame-review:\{frame.frame_index}")
    }
  }
  blockers
}

///|
pub fn noetix_e1_moonmoon_live_suite_evidence() -> MoonmoonNoetixLiveSuiteEvidence {
  let contract = noetix_e1_moonmoon_locomotion_contract()
  let clip = contract.walk_clip
  let blockers = noetix_live_suite_evidence_blockers(contract)
  let mut active_contact_frame_count = 0
  let mut loaded_contact_count = 0
  let mut contact_review_count = 0
  for frame in clip.authored_contact_frames {
    if frame.active_footprint_count > 0 {
      active_contact_frame_count += 1
    }
    if frame.status.contains("review") {
      contact_review_count += 1
    }
    for contact in frame.contacts {
      if contact.footprint.active && contact.applied_force_n.z > 0.0 {
        loaded_contact_count += 1
      }
    }
  }
  let mut driven_motor_frame_count = 0
  let mut motor_review_count = 0
  for frame in clip.authored_motor_frames {
    if frame.driven_joint_count > 0 {
      driven_motor_frame_count += 1
    }
    motor_review_count += frame.review_count
    if frame.status.contains("review") {
      motor_review_count += 1
    }
  }
  {
    evidence_id: "\{contract.robot_id}/moonmoon-live-suite-evidence",
    regeneration_mode: "live-moonrobo-typed-adapter",
    contract_id: contract.contract_id,
    robot_id: contract.robot_id,
    walk_clip_id: clip.clip_id,
    source: "vectie/moonrobo/src/moonmoon_adapter#noetix_e1_moonmoon_live_suite_evidence",
    sample_count: clip.sample_count,
    profile_joint_count: contract.profile_joint_ids.length(),
    required_motion_joint_count: contract.required_motion_joint_ids.length(),
    authored_joint_sample_count: clip.authored_joint_samples.length(),
    authored_motion_sample_count: clip.authored_motion_samples.length(),
    authored_contact_frame_count: clip.authored_contact_frames.length(),
    authored_motor_frame_count: clip.authored_motor_frames.length(),
    active_contact_frame_count,
    loaded_contact_count,
    driven_motor_frame_count,
    motor_review_count,
    contact_review_count,
    blocker_count: blockers.length(),
    blockers,
    ready: blockers.is_empty(),
    status: if blockers.is_empty() {
      "moonmoon-noetix-live-suite-evidence-ready"
    } else {
      "moonmoon-noetix-live-suite-evidence-blocked"
    },
  }
}
