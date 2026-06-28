///|
pub(all) struct MoonmoonNoetixVec3Sample {
  x : Double
  y : Double
  z : Double
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct MoonmoonNoetixFootprintSample {
  footprint_id : String
  center : MoonmoonNoetixVec3Sample
  half_length_m : Double
  half_width_m : Double
  active : Bool
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct MoonmoonNoetixContactProbeSample {
  probe_id : String
  position : MoonmoonNoetixVec3Sample
  surface_elevation_m : Double
  surface_normal : MoonmoonNoetixVec3Sample
  clearance_m : Double
  in_contact : Bool
  local_grade : Double
  status : String
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct MoonmoonNoetixContactPatchSample {
  patch_id : String
  center : MoonmoonNoetixVec3Sample
  half_length_m : Double
  half_width_m : Double
  sample_count : Int
  contact_count : Int
  min_clearance_m : Double
  max_clearance_m : Double
  average_surface_elevation_m : Double
  average_surface_normal : MoonmoonNoetixVec3Sample
  samples : Array[MoonmoonNoetixContactProbeSample]
  status : String
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct MoonmoonNoetixContactEvidenceSample {
  contact_id : String
  footprint : MoonmoonNoetixFootprintSample
  patch : MoonmoonNoetixContactPatchSample
  applied_force_n : MoonmoonNoetixVec3Sample
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct MoonmoonNoetixContactFrameSample {
  frame_index : Int
  time_s : Double
  phase : Double
  phase_label : String
  support_foot : String
  review_id : String
  center_of_mass : MoonmoonNoetixVec3Sample
  center_of_mass_velocity : MoonmoonNoetixVec3Sample
  total_mass_kg : Double
  contact_count : Int
  active_footprint_count : Int
  contacts : Array[MoonmoonNoetixContactEvidenceSample]
  status : String
} derive(Debug, Eq, ToJson, FromJson)

///|
priv struct NoetixRenderTerrainSample {
  height_m : Double
  normal_x : Double
  normal_y : Double
  normal_z : Double
}

///|
fn noetix_contact_max(a : Double, b : Double) -> Double {
  if a > b {
    a
  } else {
    b
  }
}

///|
fn noetix_contact_min(a : Double, b : Double) -> Double {
  if a < b {
    a
  } else {
    b
  }
}

///|
fn noetix_render_normal_to_moonphys(
  x : Double,
  y : Double,
  z : Double,
) -> MoonmoonNoetixVec3Sample {
  { x, y: z, z: y }
}

///|
fn noetix_render_point_to_moonphys(
  point : NoetixRootLocalPoint,
) -> MoonmoonNoetixVec3Sample {
  { x: point.x, y: point.z, z: point.y }
}

///|
fn noetix_vec3_sample(
  x : Double,
  y : Double,
  z : Double,
) -> MoonmoonNoetixVec3Sample {
  { x, y, z }
}

///|
fn noetix_mat4_rotate_y(
  matrix : Array[Double],
  angle : Double,
) -> Array[Double] {
  let c = @math.cos(angle)
  let s = @math.sin(angle)
  noetix_mat4_multiply(matrix, [
    c,
    0.0,
    0.0 - s,
    0.0,
    0.0,
    1.0,
    0.0,
    0.0,
    s,
    0.0,
    c,
    0.0,
    0.0,
    0.0,
    0.0,
    1.0,
  ])
}

///|
fn noetix_root_transform_for_motion(
  motion : MoonmoonNoetixAuthoredMotionSample,
) -> Array[Double] {
  let mut root = noetix_mat4_identity()
  root = noetix_mat4_translate(
    root,
    motion.root_sway_m,
    0.79 + motion.root_bob_m,
    0.0,
  )
  root = noetix_mat4_rotate_y(root, 0.0 - 0.45)
  noetix_mat4_rotate_z(root, motion.root_sway_m * 0.8)
}

///|
fn noetix_contact_foot_support(foot_phase : Double) -> Bool {
  let phase = cycle01(foot_phase)
  for spec in noetix_e1_moonmoon_foot_phase_specs() {
    let in_range = if spec.phase_end >= 1.0 {
      phase >= spec.phase_start && phase <= spec.phase_end
    } else {
      phase >= spec.phase_start && phase < spec.phase_end
    }
    if in_range {
      return spec.support
    }
  }
  true
}

///|
fn noetix_contact_support_transfer_weight_left(phase : Double) -> Double {
  if phase >= 0.42 && phase < 0.58 {
    1.0 - smoothstep((phase - 0.42) / 0.16)
  } else if phase >= 0.92 {
    smoothstep((phase - 0.92) / 0.16)
  } else if phase < 0.08 {
    smoothstep((phase + 0.08) / 0.16)
  } else if phase < 0.42 {
    1.0
  } else {
    0.0
  }
}

///|
fn noetix_terrain_sample_at(
  x : Double,
  z : Double,
  root_forward_m : Double,
) -> NoetixRenderTerrainSample {
  let travel_z = z + root_forward_m
  let a = 0.032 * 0.44
  let b = 0.032 * 0.22
  let kx_a = 0.9
  let kz_a = 3.1
  let kx_b = 2.4
  let kz_b = 0.0 - 1.7
  let phase_a = kx_a * x + kz_a * travel_z
  let phase_b = kx_b * x + kz_b * travel_z + 0.45
  let height_m = a * @math.sin(phase_a) + b * @math.sin(phase_b)
  let dhdx = a * kx_a * @math.cos(phase_a) + b * kx_b * @math.cos(phase_b)
  let dhdz = a * kz_a * @math.cos(phase_a) + b * kz_b * @math.cos(phase_b)
  let nx = 0.0 - dhdx
  let ny = 1.0
  let nz = 0.0 - dhdz
  let len = (nx * nx + ny * ny + nz * nz).sqrt()
  { height_m, normal_x: nx / len, normal_y: ny / len, normal_z: nz / len }
}

///|
fn noetix_contact_probe(
  foot_name : String,
  sample_index : Int,
  point : NoetixRootLocalPoint,
  foot_center : NoetixRootLocalPoint,
  root_forward_m : Double,
  active : Bool,
) -> MoonmoonNoetixContactProbeSample {
  let terrain = noetix_terrain_sample_at(point.x, point.z, root_forward_m)
  let clearance = if active { 0.0 } else { foot_center.y - terrain.height_m }
  {
    probe_id: "\{foot_name}-sole-patch/sample/\{sample_index}",
    position: noetix_render_point_to_moonphys({
      x: point.x,
      y: terrain.height_m,
      z: point.z,
    }),
    surface_elevation_m: terrain.height_m,
    surface_normal: noetix_render_normal_to_moonphys(
      terrain.normal_x,
      terrain.normal_y,
      terrain.normal_z,
    ),
    clearance_m: clearance,
    in_contact: active,
    local_grade: (terrain.normal_x * terrain.normal_x +
    terrain.normal_z * terrain.normal_z).sqrt(),
    status: if active {
      "contact"
    } else {
      "clear"
    },
  }
}

///|
fn noetix_contact_patch(
  foot_name : String,
  center : NoetixRootLocalPoint,
  root_forward_m : Double,
  active : Bool,
) -> MoonmoonNoetixContactPatchSample {
  let offsets : Array[NoetixRootLocalPoint] = [
    { x: -0.045, y: 0.0, z: -0.075 },
    { x: 0.045, y: 0.0, z: -0.075 },
    { x: 0.045, y: 0.0, z: 0.075 },
    { x: -0.045, y: 0.0, z: 0.075 },
  ]
  let samples : Array[MoonmoonNoetixContactProbeSample] = []
  let mut sum_x = 0.0
  let mut sum_y = 0.0
  let mut sum_z = 0.0
  let mut sum_nx = 0.0
  let mut sum_ny = 0.0
  let mut sum_nz = 0.0
  let mut min_clearance = 999.0
  let mut max_clearance = 0.0 - 999.0
  let mut average_surface = 0.0
  for index, offset in offsets {
    let point : NoetixRootLocalPoint = {
      x: center.x + offset.x,
      y: center.y,
      z: center.z + offset.z,
    }
    let probe = noetix_contact_probe(
      foot_name, index, point, center, root_forward_m, active,
    )
    samples.push(probe)
    sum_x += probe.position.x
    sum_y += probe.position.y
    sum_z += probe.position.z
    sum_nx += probe.surface_normal.x
    sum_ny += probe.surface_normal.y
    sum_nz += probe.surface_normal.z
    min_clearance = noetix_contact_min(min_clearance, probe.clearance_m)
    max_clearance = noetix_contact_max(max_clearance, probe.clearance_m)
    average_surface += probe.surface_elevation_m
  }
  let count = samples.length().to_double()
  let nlen = (sum_nx * sum_nx + sum_ny * sum_ny + sum_nz * sum_nz).sqrt()
  {
    patch_id: "\{foot_name}-sole-patch",
    center: noetix_vec3_sample(sum_x / count, sum_y / count, sum_z / count),
    half_length_m: 0.12,
    half_width_m: 0.09,
    sample_count: samples.length(),
    contact_count: if active {
      samples.length()
    } else {
      0
    },
    min_clearance_m: min_clearance,
    max_clearance_m: max_clearance,
    average_surface_elevation_m: average_surface / count,
    average_surface_normal: noetix_vec3_sample(
      sum_nx / nlen,
      sum_ny / nlen,
      sum_nz / nlen,
    ),
    samples,
    status: if active {
      "patch-contact"
    } else {
      "patch-clear"
    },
  }
}

///|
fn noetix_contact_evidence(
  foot_name : String,
  center : NoetixRootLocalPoint,
  root_forward_m : Double,
  active : Bool,
  normal_force_n : Double,
) -> MoonmoonNoetixContactEvidenceSample {
  let patch = noetix_contact_patch(foot_name, center, root_forward_m, active)
  {
    contact_id: "\{foot_name}-contact",
    footprint: {
      footprint_id: "\{foot_name}-sole",
      center: patch.center,
      half_length_m: 0.12,
      half_width_m: 0.09,
      active,
    },
    patch,
    applied_force_n: {
      x: 0.0,
      y: if active {
        normal_force_n * 0.08
      } else {
        0.0
      },
      z: if active {
        normal_force_n
      } else {
        0.0
      },
    },
  }
}

///|
fn noetix_contact_center_of_mass(
  left : MoonmoonNoetixContactEvidenceSample,
  right : MoonmoonNoetixContactEvidenceSample,
  phase : Double,
  motion : MoonmoonNoetixAuthoredMotionSample,
) -> MoonmoonNoetixVec3Sample {
  let left_weight = noetix_contact_support_transfer_weight_left(phase)
  let right_weight = 1.0 - left_weight
  {
    x: left.footprint.center.x * left_weight +
    right.footprint.center.x * right_weight,
    y: left.footprint.center.y * left_weight +
    right.footprint.center.y * right_weight,
    z: 0.95 + motion.root_bob_m,
  }
}

///|
fn noetix_contact_frame_base(
  frame_index : Int,
  motion : MoonmoonNoetixAuthoredMotionSample,
) -> MoonmoonNoetixContactFrameSample {
  let root = noetix_root_transform_for_motion(motion)
  let phase = motion.phase
  let left = noetix_transform_point(root, {
    x: motion.left_foot_x_m,
    y: motion.left_foot_y_m,
    z: motion.left_foot_z_m,
  })
  let right = noetix_transform_point(root, {
    x: motion.right_foot_x_m,
    y: motion.right_foot_y_m,
    z: motion.right_foot_z_m,
  })
  let left_active = noetix_contact_foot_support(phase)
  let right_active = noetix_contact_foot_support(cycle01(phase + 0.5))
  let active_count = (if left_active { 1 } else { 0 }) +
    (if right_active { 1 } else { 0 })
  let total_normal_force = 54.0 * 1.625
  let per_active_force = if active_count > 0 {
    total_normal_force / active_count.to_double()
  } else {
    0.0
  }
  let left_contact = noetix_contact_evidence(
    "left",
    left,
    motion.root_cycle_forward_m,
    left_active,
    per_active_force,
  )
  let right_contact = noetix_contact_evidence(
    "right",
    right,
    motion.root_cycle_forward_m,
    right_active,
    per_active_force,
  )
  let contacts = [left_contact, right_contact]
  let center_of_mass = noetix_contact_center_of_mass(
    left_contact, right_contact, phase, motion,
  )
  {
    frame_index,
    time_s: frame_index.to_double() / (24.0 * 0.46),
    phase,
    phase_label: noetix_phase_label(phase),
    support_foot: noetix_support_foot(phase),
    review_id: "noetix-e1-lab-01/\{noetix_phase_label(phase)}",
    center_of_mass,
    center_of_mass_velocity: noetix_vec3_sample(0.0, 0.0, 0.0),
    total_mass_kg: 54.0,
    contact_count: contacts.length(),
    active_footprint_count: active_count,
    contacts,
    status: if active_count > 0 {
      "moonrobo-authored-contact-frame-ready"
    } else {
      "moonrobo-authored-contact-frame-review"
    },
  }
}

///|
fn noetix_contact_velocity(
  previous : MoonmoonNoetixVec3Sample,
  next : MoonmoonNoetixVec3Sample,
  dt_s : Double,
) -> MoonmoonNoetixVec3Sample {
  {
    x: (next.x - previous.x) / (2.0 * dt_s) * 0.12,
    y: 0.18 * 0.12,
    z: (next.z - previous.z) / (2.0 * dt_s) * 0.12,
  }
}

///|
fn noetix_contact_frame_with_velocity(
  frame : MoonmoonNoetixContactFrameSample,
  velocity : MoonmoonNoetixVec3Sample,
) -> MoonmoonNoetixContactFrameSample {
  {
    frame_index: frame.frame_index,
    time_s: frame.time_s,
    phase: frame.phase,
    phase_label: frame.phase_label,
    support_foot: frame.support_foot,
    review_id: frame.review_id,
    center_of_mass: frame.center_of_mass,
    center_of_mass_velocity: velocity,
    total_mass_kg: frame.total_mass_kg,
    contact_count: frame.contact_count,
    active_footprint_count: frame.active_footprint_count,
    contacts: frame.contacts,
    status: frame.status,
  }
}

///|
pub fn noetix_e1_moonmoon_authored_contact_frames() -> Array[
  MoonmoonNoetixContactFrameSample,
] {
  let motion_samples = noetix_e1_moonmoon_authored_motion_samples()
  let bases : Array[MoonmoonNoetixContactFrameSample] = []
  for index, motion in motion_samples {
    bases.push(noetix_contact_frame_base(index, motion))
  }
  let dt_s = 1.0 / (24.0 * 0.46)
  let frames : Array[MoonmoonNoetixContactFrameSample] = []
  for index, frame in bases {
    let previous_index = if index == 0 { bases.length() - 1 } else { index - 1 }
    let next_index = if index + 1 == bases.length() { 0 } else { index + 1 }
    frames.push(
      noetix_contact_frame_with_velocity(
        frame,
        noetix_contact_velocity(
          bases[previous_index].center_of_mass,
          bases[next_index].center_of_mass,
          dt_s,
        ),
      ),
    )
  }
  frames
}
