///|
fn add_contacts(layout : HostLayout, c : ContactCapacity) -> Unit raise {
  guard c.rigid_max >= 0 &&
    c.rigid_max <= 1000000 &&
    c.soft_max == 0 &&
    !c.requires_grad else {
    fail(
      "contact subset requires 0<=rigid_max<=1000000, soft_max=0 and requires_grad=false",
    )
  }
  guard !c.contact_report || c.contact_matching else {
    fail("contact_report requires contact_matching")
  }
  let n = c.rigid_max
  let a = layout.arrays
  fn ints(name : String, count : Int32, value : Int32) -> Unit raise {
    a["contacts." + name] = integers(Array::make(count, value), [count])
  }
  fn zeros(name : String, count : Int32, components : Int32) -> Unit raise {
    a["contacts." + name] = floating(
      Array::make(count * components, 0.0),
      [count],
      layout.scalar_type,
      components~,
    )
  }
  ints("contact_counters", 3, 0)
  for
    (name, offset) in [
      ("rigid_contact_count", 0),
      ("soft_contact_count", 4),
      ("_reduction_overflow", 8),
    ] {
    layout.aliases["contacts." + name] = {
      base: "contacts.contact_counters",
      offset_bytes: offset,
      shape: [1],
      components: 1,
    }
  }
  ints("contact_generation", 1, 0)
  ints("rigid_contact_point_id", n, 0)
  for
    name in [
      "rigid_contact_shape0", "rigid_contact_shape1", "rigid_contact_tids",
    ] {
    ints(name, n, -1)
  }
  for
    name in [
      "rigid_contact_point0", "rigid_contact_point1", "rigid_contact_offset0", "rigid_contact_offset1",
      "rigid_contact_normal", "rigid_contact_force",
    ] {
    zeros(name, n, 3)
  }
  for name in ["rigid_contact_margin0", "rigid_contact_margin1"] {
    zeros(name, n, 1)
  }
  layout.aliases["contacts.rigid_contact_diff_normal"] = {
    base: "contacts.rigid_contact_normal",
    offset_bytes: 0,
    shape: [n],
    components: 3,
  }
  if c.surface_velocity {
    zeros("rigid_contact_surface_velocity", n, 3)
  }
  if c.per_contact_shape_properties {
    for
      name in [
        "rigid_contact_stiffness", "rigid_contact_damping", "rigid_contact_friction",
      ] {
      zeros(name, n, 1)
    }
  }
  if c.contact_matching {
    ints("rigid_contact_match_index", n, -1)
    ints("rigid_contact_match_generation", 1, -1)
  }
  if c.contact_report {
    for name in ["rigid_contact_new_indices", "rigid_contact_broken_indices"] {
      ints(name, n, 0)
    }
    for name in ["rigid_contact_new_count", "rigid_contact_broken_count"] {
      ints(name, 1, 0)
    }
  }
  // Actual zero-capacity soft arrays remain represented by zero-byte owners.
  a["contacts.soft_contact_indices"] = integers([], [0], components=3)
  for
    name in ["soft_contact_particle", "soft_contact_shape", "soft_contact_tids"] {
    ints(name, 0, -1)
  }
  for
    name in [
      "soft_contact_barycentric", "soft_contact_body_pos", "soft_contact_body_vel",
      "soft_contact_normal",
    ] {
    zeros(name, 0, 3)
  }
}

///|
/// Prepare actual shape and Contacts storage for explicit resolved primitives.
/// Does not perform cooking, mass inference, broadphase/narrowphase or solve.
pub fn prepare_collision(request : CollisionRequest) -> HostLayout raise {
  let base = prepare(request.base)
  let pairs = add_shapes(
    base,
    request.shapes,
    request.filters,
    request.candidate_limit,
  )
  add_contacts(base, request.contacts)
  let unresolved = base.unresolved_semantics.copy()
  for
    text in [
      "USD/Newton/Mjcf schema resolution and shape ordering are caller responsibilities",
      "shape-derived mass/inertia aggregation and body inertia correction are not implemented",
      "mesh, convex cooking, heightfield, SDF, hydroelastic and site geometry are rejected",
      "generic-branch static eligible pairs only; dynamic AABB broadphase and contact generation are not implemented",
      "constraint, particle, soft, tendon and custom/solver namespace storage remain incomplete",
      "f64 buffers are a Double reference layout; pinned Newton Warp fields use float32",
      "zero-byte arrays have no device allocation and cannot be passed as dispatch array arguments",
    ] {
    unresolved.push(text)
  }
  {
    ..base,
    unresolved_semantics: unresolved,
    storage_scope: {
      "kind": "rigid-tree-resolved-primitive-shape-and-contacts-subset",
      "shape_count": Json(request.shapes.length()),
      "shape_contact_pair_count": Json(pairs),
      "shape_pair_algorithm": "Newton._find_shape_contact_pairs.generic",
      "rigid_contact_max": Json(request.contacts.rigid_max),
      "soft_contact_max": 0,
      "per_contact_shape_properties": Json(
        request.contacts.per_contact_shape_properties,
      ),
      "contact_matching": Json(request.contacts.contact_matching),
      "contact_report": Json(request.contacts.contact_report),
      "surface_velocity": Json(request.contacts.surface_velocity),
      "contact_counters_shared_allocation": true,
      "contacts_initialized_empty": true,
      "dynamic_broadphase_complete": false,
      "contact_generation_complete": false,
      "full_finalize_complete": false,
    },
  }
}
