///|
struct RingCorner {
  previous : Int32
  next : Int32
  normal : @geo.Vec3
  valid : Bool
}

///|
fn edge_key(a : Int32, b : Int32) -> (Int32, Int32) {
  if a < b {
    (a, b)
  } else {
    (b, a)
  }
}

///|
/// Conservative full pinned closed-one-ring/angle-weighted-normal concavity
/// filter. Boundary/nonmanifold/saddle/flat/ambiguous vertices stay intact.
pub fn fully_concave_edges(
  mesh : PreparedMesh,
  edges : Array[Int32],
) -> Array[Int32] raise {
  guard edges.length() % 2 == 0 &&
    edges.all(i => i >= 0 && i < mesh.vertex_count) else {
    fail("invalid collision edge indices")
  }
  let topology = mesh_topology(mesh, 0)
  let canonical = topology.canonical_ids
  let v = mesh.vertices()
  let idx = mesh.triangles()
  let positions : Map[Int32, @geo.Vec3] = {}
  let minimum = point(v, 0)
  let maximum = point(v, 0)
  let mut lo = minimum
  let mut hi = maximum
  for i in 0..<mesh.vertex_count {
    let p = point(v, i)
    positions[canonical[i]] = p
    lo = @geo.vec3(-maxd(-lo.x, -p.x), -maxd(-lo.y, -p.y), -maxd(-lo.z, -p.z))
    hi = @geo.vec3(maxd(hi.x, p.x), maxd(hi.y, p.y), maxd(hi.z, p.z))
  }
  let origin = lo.add(hi).scale(0.5)
  let diagonal = maxd(hi.sub(lo).length(), 1)
  let mut signed_volume = 0.0
  let normals = []
  let lengths = []
  for t in 0..<mesh.triangle_count {
    let a = point(v, idx[t * 3])
    let b = point(v, idx[t * 3 + 1])
    let c = point(v, idx[t * 3 + 2])
    signed_volume += a.sub(origin).dot(b.sub(origin).cross(c.sub(origin))) / 6
    let normal = b.sub(a).cross(c.sub(a))
    normals.push(normal)
    lengths.push(normal.length())
  }
  if signed_volume.abs() <=
    2.220446049250313e-16 *
    diagonal *
    diagonal *
    diagonal *
    mesh.triangle_count.to_double() {
    return edges.copy()
  }
  let orientation = if signed_volume > 0 { 1.0 } else { -1.0 }
  let counts : Map[(Int32, Int32), Int32] = {}
  let groups : Map[(Int32, Int32), Array[Int32]] = {}
  for i in 0..<(topology.edges.length() / 2) {
    let key = edge_key(
      canonical[topology.edges[i * 2]],
      canonical[topology.edges[i * 2 + 1]],
    )
    counts[key] = topology.adjacent_faces[i].length()
    groups[key] = topology.adjacent_faces[i]
  }
  let rings : Map[Int32, Array[RingCorner]] = {}
  for t in 0..<mesh.triangle_count {
    let tri = [
      canonical[idx[t * 3]],
      canonical[idx[t * 3 + 1]],
      canonical[idx[t * 3 + 2]],
    ]
    for k in 0..<3 {
      let vertex = tri[k]
      let previous = tri[(k + (if orientation > 0 { 2 } else { 1 })) % 3]
      let next = tri[(k + (if orientation > 0 { 1 } else { 2 })) % 3]
      let a = positions[previous].sub(positions[vertex])
      let b = positions[next].sub(positions[vertex])
      let la = a.length()
      let lb = b.length()
      let valid = tri[0] != tri[1] &&
        tri[1] != tri[2] &&
        tri[2] != tri[0] &&
        lengths[t] > 1.0e-15 &&
        la > 1.0e-15 &&
        lb > 1.0e-15 &&
        counts.get(edge_key(vertex, previous)).unwrap_or(0) == 2 &&
        counts.get(edge_key(vertex, next)).unwrap_or(0) == 2
      let angle = if valid {
        @math.acos(maxd(-1, -maxd(-1, -a.dot(b) / (la * lb))))
      } else {
        0.0
      }
      let normal = if lengths[t] > 1.0e-15 {
        normals[t].scale(angle * orientation / lengths[t])
      } else {
        @geo.vec3(0, 0, 0)
      }
      if !rings.contains(vertex) {
        rings[vertex] = []
      }
      rings[vertex].push({ previous, next, normal, valid, })
    }
  }
  let fully : Map[Int32, Unit] = {}
  let tolerance = 1.0e-7 * diagonal
  for vertex, corners in rings {
    if corners.length() < 3 || !corners.all(c => c.valid) {
      continue
    }
    let successor : Map[Int32, Int32] = {}
    let incoming : Map[Int32, Unit] = {}
    let mut valid = true
    let mut sum = @geo.vec3(0, 0, 0)
    for corner in corners {
      if successor.contains(corner.previous) || incoming.contains(corner.next) {
        valid = false
      }
      successor[corner.previous] = corner.next
      incoming[corner.next] = ()
      sum = sum.add(corner.normal)
    }
    if !valid || successor.keys().any(k => !incoming.contains(k)) {
      continue
    }
    let first = corners[0].previous
    let mut current = first
    let visited : Map[Int32, Unit] = {}
    while !visited.contains(current) && successor.contains(current) {
      visited[current] = ()
      current = successor[current]
    }
    if current != first ||
      visited.length() != corners.length() ||
      sum.length() <= 1.0e-15 {
      continue
    }
    let normal = sum.scale(1 / sum.length())
    let mut min_height = 0.0
    let mut max_height = 0.0
    for corner in corners {
      let height = positions[corner.next].sub(positions[vertex]).dot(normal)
      min_height = -maxd(-min_height, -height)
      max_height = maxd(max_height, height)
    }
    if min_height >= -tolerance && max_height > tolerance {
      fully[vertex] = ()
    }
  }
  let out = []
  for i in 0..<(edges.length() / 2) {
    let a = edges[i * 2]
    let b = edges[i * 2 + 1]
    let ca = canonical[a]
    let cb = canonical[b]
    let key = edge_key(ca, cb)
    let mut remove = false
    if fully.contains(ca) &&
      fully.contains(cb) &&
      groups.get(key) is Some(faces) &&
      faces.length() == 2 {
      let ta = faces[0]
      let tb = faces[1]
      let opposite_a = [idx[ta * 3], idx[ta * 3 + 1], idx[ta * 3 + 2]].filter(j => {
        canonical[j] != ca && canonical[j] != cb
      })
      let opposite_b = [idx[tb * 3], idx[tb * 3 + 1], idx[tb * 3 + 2]].filter(j => {
        canonical[j] != ca && canonical[j] != cb
      })
      if opposite_a.length() == 1 &&
        opposite_b.length() == 1 &&
        lengths[ta] > 1.0e-15 &&
        lengths[tb] > 1.0e-15 {
        let side_b = normals[ta]
          .scale(orientation / lengths[ta])
          .dot(point(v, opposite_b[0]).sub(point(v, a)))
        let side_a = normals[tb]
          .scale(orientation / lengths[tb])
          .dot(point(v, opposite_a[0]).sub(point(v, a)))
        remove = side_a > tolerance && side_b > tolerance
      }
    }
    if !remove {
      out.push(a)
      out.push(b)
    }
  }
  out
}

///|
struct EdgeBox {
  center : @geo.Vec3
  direction : @geo.Vec3
  tangent : @geo.Vec3
  normal : @geo.Vec3
  half : Array[Double]
}

///|
/// Exact containment/angle-gated absorb graph and greedy source ordering,
/// using exhaustive CPU candidates instead of the Warp SAP acceleration.
pub fn absorb_edges(
  mesh : PreparedMesh,
  lower_angle : Double,
  upper_angle : Double,
  half_normal : Double,
  half_lateral : Double,
) -> Array[Int32] raise {
  guard finite(lower_angle) &&
    lower_angle >= 0 &&
    finite(upper_angle) &&
    finite(half_normal) &&
    half_normal >= 0 &&
    finite(half_lateral) &&
    half_lateral >= 0 else {
    fail("invalid collision edge box/angle options")
  }
  let t = mesh_topology(mesh, lower_angle)
  if half_normal == 0 || half_lateral == 0 {
    return t.edges.copy()
  }
  let n = t.edges.length() / 2
  guard n <= 4096 else {
    fail(
      "CPU exhaustive absorption subset supports at most 4096 candidate edges",
    )
  }
  let v = mesh.vertices()
  let boxes : Array[EdgeBox?] = []
  for i in 0..<n {
    let a = point(v, t.edges[i * 2])
    let b = point(v, t.edges[i * 2 + 1])
    let delta = b.sub(a)
    let normal = point(t.average_normals, i)
    if delta.length() <= 1.0e-15 || normal.length() <= 1.0e-15 {
      boxes.push(None)
      continue
    }
    let direction = delta.scale(1 / delta.length())
    let tang = normal.scale(1 / normal.length()).cross(direction)
    if tang.length() <= 1.0e-15 {
      boxes.push(None)
      continue
    }
    let tangent = tang.scale(1 / tang.length())
    boxes.push(
      Some({
        center: a.add(b).scale(0.5),
        direction,
        tangent,
        normal: direction.cross(tangent),
        half: [delta.length() * 0.5 + half_lateral, half_lateral, half_normal],
      }),
    )
  }
  let vmin = [v[0], v[1], v[2]]
  let vmax = vmin.copy()
  for i in 0..<mesh.vertex_count {
    for k in 0..<3 {
      vmin[k] = -maxd(-vmin[k], -v[i * 3 + k])
      vmax[k] = maxd(vmax[k], v[i * 3 + k])
    }
  }
  let dx = vmax[0] - vmin[0]
  let dy = vmax[1] - vmin[1]
  let dz = vmax[2] - vmin[2]
  let eps = 1.0e-6 * maxd((dx * dx + dy * dy + dz * dz).sqrt(), 1.0e-6)
  fn contains(box : EdgeBox, p : @geo.Vec3) -> Bool {
    let d = p.sub(box.center)
    d.dot(box.direction).abs() <= box.half[0] + eps &&
    d.dot(box.tangent).abs() <= box.half[1] + eps &&
    d.dot(box.normal).abs() <= box.half[2] + eps
  }
  let absorbed : Array[Array[Int32]] = Array::makei(n, _ => [])
  for i in 0..<n {
    if boxes[i] is Some(box) {
      for j in 0..<n {
        if i == j || !t.angles[j].map(a => a < upper_angle).unwrap_or(false) {
          continue
        }
        if contains(box, point(v, t.edges[j * 2])) &&
          contains(box, point(v, t.edges[j * 2 + 1])) {
          absorbed[i].push(j)
        }
      }
    }
  }
  let order = Array::makei(n, i => i)
  order.sort_by((a, b) => {
    let count = absorbed[b].length().compare(absorbed[a].length())
    if count != 0 {
      count
    } else {
      let area = t.area_sums[b]
        .unwrap_or(0)
        .compare(t.area_sums[a].unwrap_or(0))
      if area != 0 {
        area
      } else {
        a.compare(b)
      }
    }
  })
  let kept = Array::make(n, false)
  let removed = Array::make(n, false)
  for i in order {
    if absorbed[i].is_empty() {
      break
    }
    if removed[i] {
      continue
    }
    kept[i] = true
    for j in absorbed[i] {
      if !kept[j] {
        removed[j] = true
      }
    }
  }
  let out = []
  for i in 0..<n {
    if !removed[i] {
      out.push(t.edges[i * 2])
      out.push(t.edges[i * 2 + 1])
    }
  }
  out
}

///|
pub(all) struct CollisionEdgeOptions {
  lower_angle : Double
  upper_angle : Double
  box_absorption : Bool
  concave_filter : Bool
  sign_method : String
  half_normal : Double?
  half_normal_relative : Double?
  half_lateral : Double?
  half_lateral_relative : Double?
} derive(FromJson, ToJson)

///|
fn resolve_extent(
  absolute : Double?,
  relative : Double?,
  fallback : Double,
  diagonal : Double,
) -> Double raise {
  guard !(absolute is Some(_) && relative is Some(_)) &&
    absolute.map(x => finite(x) && x >= 0).unwrap_or(true) &&
    relative.map(x => finite(x) && x >= 0).unwrap_or(true) else {
    fail("edge extents require one nonnegative absolute or relative value")
  }
  let value = absolute.unwrap_or(relative.unwrap_or(fallback) * diagonal)
  guard finite(value) else { fail("resolved edge extent overflows") }
  value
}

///|
/// Mesh._build_collision_edges semantics: retain boundary/nonmanifold edges,
/// apply manifold-only absorption removals, then the fully-concave pass.
/// None means negative-angle lazy fallback to the full unique edge set.
pub fn collision_edges(
  mesh : PreparedMesh,
  options : CollisionEdgeOptions,
) -> Array[Int32]? raise {
  guard finite(options.lower_angle) &&
    finite(options.upper_angle) &&
    ["auto", "parity", "winding", "normal"].contains(options.sign_method) &&
    !(options.lower_angle < 0 && options.box_absorption) else {
    fail("invalid collision edge policy")
  }
  let v = mesh.vertices()
  let low = [v[0], v[1], v[2]]
  let high = low.copy()
  for i in 0..<mesh.vertex_count {
    for k in 0..<3 {
      low[k] = -maxd(-low[k], -v[i * 3 + k])
      high[k] = maxd(high[k], v[i * 3 + k])
    }
  }
  let diagonal = point(high, 0).sub(point(low, 0)).length()
  let normal = resolve_extent(
    options.half_normal,
    options.half_normal_relative,
    1.0e-3,
    diagonal,
  )
  let lateral = resolve_extent(
    options.half_lateral,
    options.half_lateral_relative,
    5.0e-3,
    diagonal,
  )
  if options.lower_angle < 0 {
    return None
  }
  let edges = if options.box_absorption {
    absorb_edges(
      mesh,
      options.lower_angle,
      options.upper_angle,
      normal,
      lateral,
    )
  } else {
    mesh_topology(mesh, options.lower_angle).edges
  }
  Some(
    if options.concave_filter && options.sign_method != "normal" {
      fully_concave_edges(mesh, edges)
    } else {
      edges
    },
  )
}
