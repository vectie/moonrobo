///|
fn typed_allocation(
  base : PyValue,
  scalar_type : @contracts.ScalarType,
  origin : String?,
) -> @contracts.Allocation raise {
  {
    owner_id: base.identity().to_string(),
    address: base.attr("ptr").uint64(),
    bytes: base.attr("capacity").int64(),
    scalar_type,
    capture_origin: origin,
  }
}

///|
/// Validate facts read from actual live allocations. The normalized capture
/// origin is assigned only after comparing exact native recording pointers.
fn Scene::audit_native(
  self : Scene,
  graphs : Array[PyValue],
  regions : Array[Region],
  views : Map[String, View],
  context_writes : Json,
  mesh_base : PyValue,
  mesh_ids : Array[PyValue],
  rows : Int32,
) -> Unit raise {
  let py = self.py
  let initial = regions.map(r => {
    typed_allocation(r.base, @contracts.scalar_type(r.scalar_type), None)
  })
  let mesh : @contracts.MeshHandles? = if mesh_base.text() == "None" {
    None
  } else {
    let ids : Array[UInt64] = []
    for raw in mesh_ids {
      let id = raw.uint64()
      if !ids.contains(id) {
        ids.push(id)
      }
    }
    let handles = py
      .method(py.method(mesh_base, "numpy"), "tolist")
      .list(py)
      .map(raw => raw.uint64())
    Some({
      allocation: typed_allocation(mesh_base, U64, None),
      owned: self.base(mesh_base).identity() == mesh_base.identity(),
      contiguous: mesh_base.attr("is_contiguous").bool(),
      handles,
      registered_mesh_ids: ids,
    })
  }
  let captures : Array[@contracts.GraphCapture] = []
  let roles : Array[@contracts.GraphRole] = [Step, Reset, Context, Refresh]
  guard graphs.length() == roles.length() else {
    fail("four native capture contracts required")
  }
  for index, graph in graphs {
    let capture = graph.attr("_apic_capture")
    let state = capture.attr("apic_state").uint64()
    let entries = py.method(capture.attr("_regions"), "values").list(py)
    let transient_ids = capture.attr("_transient_regions")
    let captured : Array[@contracts.CapturedRegion] = []
    for entry in entries {
      let base = self.base(py.index(entry, 3))
      let ptr = base.attr("ptr").uint64()
      guard ptr == py.index(entry, 1).uint64() &&
        base.attr("capacity").uint64() == py.index(entry, 2).uint64() else {
        fail("recorded APIC allocation differs from its live owner")
      }
      let transient = py
        .method(transient_ids, "__contains__", args=[py.index(entry, 0)])
        .bool()
      let origin = if base.has_attr("_apic_capture_origin") {
        let observed = base.attr("_apic_capture_origin").uint64()
        if observed == 0UL {
          None
        } else {
          guard observed == state && transient else {
            fail("capture allocation ownership escaped its original graph")
          }
          Some(roles[index].name())
        }
      } else {
        None
      }
      let scalar_type = if mesh is Some(value) &&
        ptr == value.allocation.address {
        @contracts.ScalarType::U64
      } else if transient {
        @contracts.ScalarType::Opaque(base.attr("dtype").text())
      } else {
        let (name, _) = self.classify(base.attr("dtype"))
        @contracts.scalar_type(name)
      }
      captured.push({
        allocation: typed_allocation(base, scalar_type, origin),
        transient,
      })
    }
    let keys = py
      .method(capture.attr("collected_modules"), "keys")
      .list(py)
      .map(value => value.text())
    captures.push({ role: roles[index], regions: captured, module_keys: keys, })
  }
  let union = @contracts.NumericUnion::build(initial, captures, mesh?)
  let components : Map[String, @contracts.BufferView] = @json.from_json(
    views.to_json(),
  )
  union.validate_components(components, rows)
  let writes : @contracts.ContextWrites = @json.from_json(context_writes)
  writes.validate(union, rows)
}
