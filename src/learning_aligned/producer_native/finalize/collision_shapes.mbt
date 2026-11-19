///|
fn finite_shape(values : Array[Double]) -> Unit raise {
  guard values.all(x => !x.is_nan() && !x.is_inf()) else {
    fail("nonfinite resolved shape input")
  }
}

///|
fn primitive_type(s : ResolvedShape) -> Int32 raise {
  let v = s.scale
  finite_shape([v.x, v.y, v.z, s.margin, s.gap, s.collision_radius])
  guard s.flags >= 0 &&
    (s.flags & 7) == s.flags &&
    s.margin >= 0 &&
    s.collision_radius >= 0 else {
    fail("unsupported flags or negative shape margin/radius")
  }
  match s.kind {
    "plane" => {
      guard v.x >= 0 && v.y >= 0 && v.z == 0 else {
        fail("plane scale is (halfwidth,halfheight,0)")
      }
      1
    }
    "sphere" => {
      guard v.x > 0 && v.y == 0 && v.z == 0 else {
        fail("sphere scale is (radius,0,0)")
      }
      3
    }
    "capsule" => {
      guard v.x > 0 && v.y >= 0 && v.z == 0 else {
        fail("capsule scale is (radius,halfheight,0)")
      }
      4
    }
    "ellipsoid" => {
      guard v.x > 0 && v.y > 0 && v.z > 0 else {
        fail("ellipsoid requires positive radii")
      }
      5
    }
    "cylinder" => {
      guard v.x > 0 && v.y > 0 && v.z == 0 else {
        fail("only plain cylinder (radius,halfheight,0) supported")
      }
      6
    }
    "box" => {
      guard v.x > 0 && v.y > 0 && v.z > 0 else {
        fail("box requires positive half extents")
      }
      7
    }
    "cone" => {
      guard v.x > 0 && v.y > 0 && v.z == 0 else {
        fail("cone scale is (radius,halfheight,0)")
      }
      9
    }
    _ => fail("unresolved/cooked/mesh shape type is unsupported: " + s.kind)
  }
}

///|
fn shape_pose(t : @geo.Transform3) -> Array[Double] raise {
  let q = @constants.rotation_quaternion(t.basis)
  finite_shape([t.translation.x, t.translation.y, t.translation.z])
  [t.translation.x, t.translation.y, t.translation.z, q.x, q.y, q.z, q.w]
}

///|
fn add_shapes(
  layout : HostLayout,
  shapes : Array[ResolvedShape],
  filters : Array[ShapePair],
  limit : Int32,
) -> Int32 raise {
  guard shapes.length() <= 4096 else {
    fail("resolved shape capacity exceeds supported bound")
  }
  let n = shapes.length()
  let a = layout.arrays
  let kinds = []
  let bodies = []
  let worlds = []
  let flags = []
  let groups = []
  let poses = []
  let scales = []
  let margins = []
  let gaps = []
  let radii = []
  let solids : Array[Byte] = []
  let ke = []
  let kd = []
  let kf = []
  let ka = []
  let mu = []
  let restitution = []
  let torsional = []
  let rolling = []
  let kh = []
  // body_world is the prepared global body index map. Read it from the same
  // request in prepare_collision instead of inferring clone widths.
  let body_world = layout.array("model.body_world")
  for s in shapes {
    guard s.body >= -1 &&
      s.body < layout.body_count &&
      s.world >= -1 &&
      s.world < layout.world_count else {
      fail("shape body/world index outside prepared model")
    }
    if s.body >= 0 {
      let b = s.body * 4
      let actual = (body_world.bytes[b].to_uint() |
      (body_world.bytes[b + 1].to_uint() << 8) |
      (body_world.bytes[b + 2].to_uint() << 16) |
      (body_world.bytes[b + 3].to_uint() << 24)).reinterpret_as_int()
      guard s.world == actual else {
        fail("attached shape world differs from body owner")
      }
    }
    kinds.push(primitive_type(s))
    bodies.push(s.body)
    worlds.push(s.world)
    flags.push(s.flags)
    groups.push(s.collision_group)
    for x in shape_pose(s.transform) {
      poses.push(x)
    }
    for x in [s.scale.x, s.scale.y, s.scale.z] {
      scales.push(x)
    }
    margins.push(s.margin)
    gaps.push(s.gap)
    radii.push(s.collision_radius)
    solids.push(if s.is_solid { 1 } else { 0 })
    let m = s.material
    let material = [
      m.ke,
      m.kd,
      m.kf,
      m.ka,
      m.mu,
      m.restitution,
      m.mu_torsional,
      m.mu_rolling,
      m.kh,
    ]
    finite_shape(material)
    guard material.all(x => x >= 0) else {
      fail("negative resolved contact material")
    }
    ke.push(m.ke)
    kd.push(m.kd)
    kf.push(m.kf)
    ka.push(m.ka)
    mu.push(m.mu)
    restitution.push(m.restitution)
    torsional.push(m.mu_torsional)
    rolling.push(m.mu_rolling)
    kh.push(m.kh)
  }
  for
    (name, data) in [
      ("shape_type", kinds),
      ("shape_body", bodies),
      ("shape_world", worlds),
      ("shape_flags", flags),
      ("shape_collision_group", groups),
    ] {
    a["model." + name] = integers(data, [n])
  }
  a["model.shape_world_start"] = integers(
    shape_world_starts(worlds, layout.world_count),
    [layout.world_count + 2],
  )
  a["model.shape_transform"] = floating(
    poses,
    [n],
    layout.scalar_type,
    components=7,
  )
  a["model.shape_scale"] = floating(
    scales,
    [n],
    layout.scalar_type,
    components=3,
  )
  for
    (name, data) in [
      ("shape_margin", margins),
      ("shape_gap", gaps),
      ("shape_collision_radius", radii),
      ("shape_material_ke", ke),
      ("shape_material_kd", kd),
      ("shape_material_kf", kf),
      ("shape_material_ka", ka),
      ("shape_material_mu", mu),
      ("shape_material_restitution", restitution),
      ("shape_material_mu_torsional", torsional),
      ("shape_material_mu_rolling", rolling),
      ("shape_material_kh", kh),
    ] {
    a["model." + name] = floating(data, [n], layout.scalar_type)
  }
  a["model.shape_is_solid"] = {
    scalar_type: "bool",
    shape: [n],
    components: 1,
    bytes: Bytes::from_array(solids),
  }
  a["model.shape_source_ptr"] = words64(Array::make(n, 0UL), "u64")
  a["model._shape_mesh_properties"] = integers(Array::make(n, 0), [n])
  // These are the exact primitive sentinel/fallback values in _finalize_impl.
  let support = []
  for _ in 0..<n {
    for x in [-1, -1, -1, 0] {
      support.push(x)
    }
  }
  a["model._shape_support_data"] = integers(support, [n], components=4)
  for
    name in [
      "_convex_support_lut", "_convex_support_vertex_offsets", "_convex_support_neighbors",
    ] {
    a["model." + name] = integers([0], [1])
  }
  let packed = filter_codes(filters, n)
  a["prepared.shape_collision_filter_packed"] = words64(packed, "i64")
  let pairs = primitive_candidates(shapes, filters, limit)
  let flat = []
  for pair in pairs {
    flat.push(pair.a)
    flat.push(pair.b)
  }
  a["model.shape_contact_pairs"] = integers(
    flat,
    [pairs.length()],
    components=2,
  )
  // Explicit CSR serialization of the host body_shapes dictionary. This is
  // auxiliary prepared data, not an invented Newton device field.
  let starts = [0]
  let indices = []
  for body in 0..<layout.body_count {
    for index, s in shapes {
      if s.body == body {
        indices.push(index)
      }
    }
    starts.push(indices.length())
  }
  a["prepared.body_shape_start"] = integers(starts, [layout.body_count + 1])
  a["prepared.body_shape_indices"] = integers(indices, [indices.length()])
  pairs.length()
}
