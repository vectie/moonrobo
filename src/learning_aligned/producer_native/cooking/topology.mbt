///|
pub(all) struct MeshTopology {
  canonical_ids : Array[Int32]
  edges : Array[Int32]
  adjacent_faces : Array[Array[Int32]]
  angles : Array[Double?]
  average_normals : Array[Double]
  area_sums : Array[Double?]
  watertight : Bool
} derive(ToJson)

///|
fn bucket(value : Double) -> Int64 raise {
  // NumPy performs the multiplication in float32, then ties-to-even rint.
  let scaled = (Float::from_double(value) * 10000000.0F).to_double()
  guard finite(scaled) && scaled.abs() < 9.0e18 else {
    fail("mesh exceeds canonical 1e-7 bucket range")
  }
  let lo = @math.floor(scaled)
  let fraction = scaled - lo
  let base = lo.to_int64()
  if fraction < 0.5 {
    base
  } else if fraction > 0.5 {
    base + 1L
  } else if base % 2L == 0L {
    base
  } else {
    base + 1L
  }
}

///|
/// Actual geometric edge grouping/first-slot order, watertight counts and
/// dihedral filtering. Canonical group numbering is first occurrence rather
/// than NumPy's byte-sorted labels; grouping and emitted edge order match.
pub fn mesh_topology(
  mesh : PreparedMesh,
  lower_angle : Double,
) -> MeshTopology raise {
  guard finite(lower_angle) else {
    fail("finite edge angle threshold required")
  }
  let v = mesh.vertices()
  let idx = mesh.triangles()
  let canonical = []
  let seen : Map[(Int64, Int64, Int64), Int32] = {}
  for i in 0..<mesh.vertex_count {
    let p = point(v, i)
    let key = (bucket(p.x), bucket(p.y), bucket(p.z))
    let id = if seen.get(key) is Some(id) {
      id
    } else {
      let id = seen.length()
      seen[key] = id
      id
    }
    canonical.push(id)
  }
  let groups : Map[(Int32, Int32), Array[(Int32, Int32, Int32)]] = {}
  let order = []
  let normals = []
  for t in 0..<mesh.triangle_count {
    let a = idx[t * 3]
    let b = idx[t * 3 + 1]
    let c = idx[t * 3 + 2]
    normals.push(
      point(v, b).sub(point(v, a)).cross(point(v, c).sub(point(v, a))),
    )
    for (x, y) in [(a, b), (b, c), (a, c)] {
      let ca = canonical[x]
      let cb = canonical[y]
      let key = if ca < cb { (ca, cb) } else { (cb, ca) }
      if !groups.contains(key) {
        groups[key] = []
        order.push(key)
      }
      groups[key].push((t, x, y))
    }
  }
  let edges = []
  let faces = []
  let angles = []
  let averages = []
  let areas = []
  let mut watertight = !order.is_empty()
  for key in order {
    let group = groups[key]
    if group.length() != 2 {
      watertight = false
    }
    let (t, x, y) = group[0]
    let mut angle : Double? = None
    let mut area : Double? = None
    let mut normal = @geo.vec3(0, 0, 0)
    let mut keep = true
    if group.length() == 2 {
      let (other, _, _) = group[1]
      let a = normals[t]
      let b = normals[other]
      let na = a.length()
      let nb = b.length()
      if na > 0 && nb > 0 {
        let cosine = maxd(-1, -maxd(-a.dot(b) / (na * nb), -1))
        angle = Some(@math.acos(cosine))
        area = Some((na + nb) * 0.5)
        let sum = a.scale(1 / na).add(b.scale(1 / nb))
        let length = sum.length()
        if length > 1.0e-6 {
          normal = sum.scale(1 / length)
        }
        keep = lower_angle <= 0 || cosine <= @math.cos(lower_angle)
      }
    }
    if keep {
      edges.push(x)
      edges.push(y)
      faces.push(group.map(slot => slot.0))
      angles.push(angle)
      areas.push(area)
      push_point(averages, normal)
    }
  }
  {
    canonical_ids: canonical,
    edges,
    adjacent_faces: faces,
    angles,
    average_normals: averages,
    area_sums: areas,
    watertight,
  }
}

///|
pub(all) struct ConvexSupport {
  certified : Bool
  offsets : Array[Int32]
  neighbors : Array[Int32]
  seed_lut : Array[Int32]
  lut_resolution : Int32
} derive(ToJson)

///|
/// Strict full-rank, closed supporting-plane hull certification and exact
/// sorted adjacency. No acceleration is fabricated for a concave/open mesh.
pub fn convex_support(mesh : PreparedMesh) -> ConvexSupport raise {
  guard mesh.vertex_count <= 65536 && mesh.triangle_count <= 131072 else {
    fail("convex certification capacity exceeded")
  }
  let v = mesh.vertices()
  let idx = mesh.triangles()
  let n = mesh.vertex_count
  let empty = {
    certified: false,
    offsets: [],
    neighbors: [],
    seed_lut: [],
    lut_resolution: 0,
  }
  if n < 4 {
    return empty
  }
  let minimum = [v[0], v[1], v[2]]
  let maximum = minimum.copy()
  let mean = Array::make(3, 0.0)
  for i in 0..<n {
    for k in 0..<3 {
      let x = v[i * 3 + k]
      minimum[k] = -maxd(-minimum[k], -x)
      maximum[k] = maxd(maximum[k], x)
      mean[k] += x / n.to_double()
    }
  }
  let scale = maxd(
    1.0e-6,
    maxd(
      maximum[0] - minimum[0],
      maxd(maximum[1] - minimum[1], maximum[2] - minimum[2]),
    ),
  )
  let covariance = Array::make(9, 0.0)
  for i in 0..<n {
    for a in 0..<3 {
      for b in 0..<3 {
        covariance[a * 3 + b] += (v[i * 3 + a] - mean[a]) *
          (v[i * 3 + b] - mean[b])
      }
    }
  }
  let (eig, _) = eigen3(covariance)
  if eig[0] <= scale * scale * 1.0e-20 {
    return empty
  }
  let groups : Map[(Int64, Int64, Int64), Array[Int32]] = {}
  let welded = []
  // Strict source certification normalizes relative to the first vertex and
  // welds 12 decimal places. bucket uses f32, so use a separate double rint.
  fn rounded12(x : Double) -> Int64 raise {
    let value = x * 1.0e12
    guard finite(value) && value.abs() < 9.0e18 else {
      fail("convex weld coordinate overflows")
    }
    let lo = @math.floor(value)
    let i = lo.to_int64()
    let f = value - lo
    if f < 0.5 {
      i
    } else if f > 0.5 {
      i + 1L
    } else if i % 2L == 0L {
      i
    } else {
      i + 1L
    }
  }
  for i in 0..<n {
    let key = (
      rounded12((v[i * 3] - v[0]) / scale),
      rounded12((v[i * 3 + 1] - v[1]) / scale),
      rounded12((v[i * 3 + 2] - v[2]) / scale),
    )
    if !groups.contains(key) {
      groups[key] = []
    }
    let group = groups[key]
    welded.push(if group.is_empty() { i } else { group[0] })
    group.push(i)
  }
  let incidence : Map[(Int32, Int32), Int32] = {}
  let faces : Map[(Int32, Int32, Int32), Unit] = {}
  let adjacent : Array[Map[Int32, Unit]] = Array::makei(n, _ => Map([]))
  for t in 0..<mesh.triangle_count {
    let a = idx[t * 3]
    let b = idx[t * 3 + 1]
    let c = idx[t * 3 + 2]
    let normal = point(v, b)
      .sub(point(v, a))
      .cross(point(v, c).sub(point(v, a)))
    let length = normal.length()
    if length <= scale * scale * 1.0e-12 {
      continue
    }
    let unit = normal.scale(1 / length)
    let offset = unit.dot(point(v, a))
    let tolerance = scale * 1.0e-12
    let mut positive = true
    let mut negative = true
    for i in 0..<n {
      let p = unit.dot(point(v, i))
      if p > offset + tolerance {
        positive = false
      }
      if p < offset - tolerance {
        negative = false
      }
    }
    if !positive && !negative {
      return empty
    }
    let wa = welded[a]
    let wb = welded[b]
    let wc = welded[c]
    if wa == wb || wb == wc || wa == wc {
      continue
    }
    let f = [wa, wb, wc]
    f.sort()
    let key = (f[0], f[1], f[2])
    if faces.contains(key) {
      return empty
    }
    faces[key] = ()
    for (x, y) in [(wa, wb), (wb, wc), (wc, wa)] {
      let key = if x < y { (x, y) } else { (y, x) }
      incidence[key] = incidence.get(key).unwrap_or(0) + 1
    }
    for (x, y) in [(a, b), (a, c), (b, c)] {
      if x != y {
        adjacent[x][y] = ()
        adjacent[y][x] = ()
      }
    }
  }
  if incidence.is_empty() || incidence.values().any(count => count != 2) {
    return empty
  }
  for group in groups.values() {
    if group.length() > 1 {
      let merged : Map[Int32, Unit] = {}
      for i in group {
        merged[i] = ()
        for j in adjacent[i].keys() {
          merged[j] = ()
        }
      }
      for i in group {
        for j in merged.keys() {
          if j != i {
            adjacent[i][j] = ()
          }
        }
      }
    }
  }
  let mut first = -1
  for i in 0..<n {
    if !adjacent[i].is_empty() {
      first = i
      break
    }
  }
  if first < 0 {
    return empty
  }
  let visited : Map[Int32, Unit] = {}
  let stack = [first]
  while !stack.is_empty() {
    let i = stack.pop().unwrap()
    if visited.contains(i) {
      continue
    }
    visited[i] = ()
    for j in adjacent[i].keys() {
      stack.push(j)
    }
  }
  for i in 0..<n {
    if !adjacent[i].is_empty() && !visited.contains(i) {
      return empty
    }
  }
  let offsets = [0]
  let neighbors = []
  for row in adjacent {
    let sorted = row.keys().collect()
    sorted.sort()
    for j in sorted {
      neighbors.push(j)
    }
    offsets.push(neighbors.length())
  }
  let lut = []
  if n >= 256 && adjacent.all(row => !row.is_empty()) {
    for iy in 0..<32 {
      for ix in 0..<32 {
        let mut x = Float::from_double(-1.0 + 2.0 * ix.to_double() / 31)
        let mut y = Float::from_double(-1.0 + 2.0 * iy.to_double() / 31)
        let z = 1.0F - x.abs() - y.abs()
        if z < 0 {
          let old = x
          x = (1.0F - y.abs()) * (if old >= 0 { 1.0F } else { -1.0F })
          y = (1.0F - old.abs()) * (if y >= 0 { 1.0F } else { -1.0F })
        }
        let length = (x * x + y * y + z * z).sqrt()
        let dx = x / length
        let dy = y / length
        let dz = z / length
        let mut best = 0
        let mut score = dx * Float::from_double(v[0]) +
          dy * Float::from_double(v[1]) +
          dz * Float::from_double(v[2])
        for i in 1..<n {
          let dot = dx * Float::from_double(v[i * 3]) +
            dy * Float::from_double(v[i * 3 + 1]) +
            dz * Float::from_double(v[i * 3 + 2])
          if dot > score {
            score = dot
            best = i
          }
        }
        lut.push(best)
      }
    }
  }
  {
    certified: true,
    offsets,
    neighbors,
    seed_lut: lut,
    lut_resolution: if lut.is_empty() {
      0
    } else {
      32
    },
  }
}
