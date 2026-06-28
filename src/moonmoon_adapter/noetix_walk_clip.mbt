///|
pub(all) struct MoonmoonNoetixFootPhaseSpec {
  role : String
  phase_start : Double
  phase_end : Double
  support : Bool
  lock_window : Bool
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct MoonmoonNoetixJointAnchor {
  joint_id : String
  side : String
  field : String
  phase : Double
  position_rad : Double
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct MoonmoonNoetixWalkClipContract {
  clip_id : String
  source : String
  cycle_hz : Double
  root_speed_mps : Double
  stride_m : Double
  sample_count : Int
  foot_phase_sequence : Array[String]
  phase_labels : Array[String]
  foot_phase_specs : Array[MoonmoonNoetixFootPhaseSpec]
  required_joint_ids : Array[String]
  joint_anchors : Array[MoonmoonNoetixJointAnchor]
  blocker_count : Int
  blockers : Array[String]
  ready : Bool
  status : String
} derive(Debug, Eq, ToJson, FromJson)

///|
fn foot_phase_spec(
  role : String,
  phase_start : Double,
  phase_end : Double,
  support : Bool,
  lock_window : Bool,
) -> MoonmoonNoetixFootPhaseSpec {
  { role, phase_start, phase_end, support, lock_window }
}

///|
fn joint_anchor(
  joint_id : String,
  side : String,
  field : String,
  phase : Double,
  position_rad : Double,
) -> MoonmoonNoetixJointAnchor {
  { joint_id, side, field, phase, position_rad }
}

///|
pub fn noetix_e1_moonmoon_foot_phase_sequence() -> Array[String] {
  ["contact", "loading", "stance", "passing", "swing", "release"]
}

///|
pub fn noetix_e1_moonmoon_walk_phase_labels() -> Array[String] {
  ["left-stance-right-swing", "right-stance-left-swing"]
}

///|
pub fn noetix_e1_moonmoon_foot_phase_specs() -> Array[
  MoonmoonNoetixFootPhaseSpec,
] {
  [
    foot_phase_spec("contact", 0.0, 0.08, true, false),
    foot_phase_spec("loading", 0.08, 0.18, true, true),
    foot_phase_spec("stance", 0.18, 0.50, true, true),
    foot_phase_spec("passing", 0.50, 0.72, true, false),
    foot_phase_spec("swing", 0.72, 0.92, false, false),
    foot_phase_spec("release", 0.92, 1.0, true, false),
  ]
}

///|
pub fn noetix_e1_moonmoon_joint_anchors() -> Array[MoonmoonNoetixJointAnchor] {
  [
    joint_anchor("leg_l1_joint", "left", "hip", 0.0, -0.35),
    joint_anchor("leg_l1_joint", "left", "hip", 0.5, 0.28),
    joint_anchor("leg_l4_joint", "left", "knee", 0.0, -0.08),
    joint_anchor("leg_l4_joint", "left", "knee", 0.75, -0.82),
    joint_anchor("leg_l6_joint", "left", "ankle", 0.0, 0.12),
    joint_anchor("leg_l6_joint", "left", "ankle", 0.75, -0.28),
    joint_anchor("leg_r1_joint", "right", "hip", 0.0, 0.28),
    joint_anchor("leg_r1_joint", "right", "hip", 0.5, -0.35),
    joint_anchor("leg_r4_joint", "right", "knee", 0.25, -0.82),
    joint_anchor("leg_r4_joint", "right", "knee", 0.5, -0.08),
    joint_anchor("leg_r6_joint", "right", "ankle", 0.25, -0.28),
    joint_anchor("leg_r6_joint", "right", "ankle", 0.5, 0.12),
    joint_anchor("arm_l1_joint", "left", "shoulder", 0.0, -0.21),
    joint_anchor("arm_l4_joint", "left", "elbow", 0.0, 0.25),
    joint_anchor("arm_r1_joint", "right", "shoulder", 0.0, 0.21),
    joint_anchor("arm_r4_joint", "right", "elbow", 0.0, 0.25),
  ]
}

///|
fn noetix_walk_clip_blockers() -> Array[String] {
  let blockers : Array[String] = []
  let phase_specs = noetix_e1_moonmoon_foot_phase_specs()
  if noetix_e1_moonmoon_foot_phase_sequence().length() != phase_specs.length() {
    blockers.push("foot-phase-spec-count")
  }
  let anchors = noetix_e1_moonmoon_joint_anchors()
  for joint_id in noetix_e1_moonmoon_required_motion_joint_ids() {
    if !anchors.any(fn(anchor) { anchor.joint_id == joint_id }) {
      blockers.push("missing-joint-anchor:\{joint_id}")
    }
  }
  blockers
}

///|
pub fn noetix_e1_moonmoon_walk_clip_contract() -> MoonmoonNoetixWalkClipContract {
  let blockers = noetix_walk_clip_blockers()
  {
    clip_id: "noetix-e1-lab-01/endless-forward-walk",
    source: "vectie/moonrobo/src/moonmoon_adapter#noetix_e1_moonmoon_walk_clip_contract",
    cycle_hz: 0.46,
    root_speed_mps: 0.18,
    stride_m: 0.38,
    sample_count: 24,
    foot_phase_sequence: noetix_e1_moonmoon_foot_phase_sequence(),
    phase_labels: noetix_e1_moonmoon_walk_phase_labels(),
    foot_phase_specs: noetix_e1_moonmoon_foot_phase_specs(),
    required_joint_ids: noetix_e1_moonmoon_required_motion_joint_ids(),
    joint_anchors: noetix_e1_moonmoon_joint_anchors(),
    blocker_count: blockers.length(),
    blockers,
    ready: blockers.is_empty(),
    status: if blockers.is_empty() {
      "moonmoon-noetix-walk-clip-ready"
    } else {
      "moonmoon-noetix-walk-clip-blocked"
    },
  }
}
