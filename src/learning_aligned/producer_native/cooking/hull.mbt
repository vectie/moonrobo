///|
priv type NativeHull

///|
#borrow(adapter, library, points)
extern "c" fn hull_open(
  adapter : Bytes,
  library : Bytes,
  points : Bytes,
  maximum : Int32,
) -> NativeHull = "moonrobo_hull_open"

///|
#borrow(hull)
extern "c" fn hull_error(hull : NativeHull) -> Bytes = "moonrobo_hull_error"

///|
#borrow(hull)
extern "c" fn hull_points(hull : NativeHull) -> Bytes = "moonrobo_hull_points"

///|
#borrow(hull)
extern "c" fn hull_indices(hull : NativeHull) -> Bytes = "moonrobo_hull_indices"

///|
#borrow(hull)
extern "c" fn hull_joggled(hull : NativeHull) -> Int32 = "moonrobo_hull_joggled"

///|
#borrow(hull)
extern "c" fn hull_close(hull : NativeHull) -> Unit = "moonrobo_hull_close"

///|
pub(all) struct HullRequest {
  vertices : Array[Double]
  max_vertices : Int32
  rank_epsilon : Double
} derive(FromJson, ToJson)

///|
pub struct HullMesh {
  vertices : Array[Double]
  indices : Array[Int32]
  rank : Int32
  receipt : Json
}

///|
pub fn HullMesh::prepare(self : HullMesh) -> PreparedMesh raise {
  guard self.rank == 3 else {
    fail(
      "rank<3 hull has zero-volume/degenerate faces; not a volumetric collider",
    )
  }
  prepare_mesh({
    vertices: self.vertices,
    indices: self.indices,
    velocities: [],
    groups: [],
    bvh_constructor: "sah",
    bvh_leaf_size: 4,
    support_winding_number: false,
  })
}

///|
fn output_hull(
  v : Array[Double],
  idx : Array[Int32],
  rank : Int32,
  receipt : Json,
) -> HullMesh raise {
  let bytes = floats(v)
  {
    vertices: Array::makei(bytes.length() / 4, i => {
      Float::reinterpret_from_int(word(bytes, i * 4).to_int()).to_double()
    }),
    indices: idx,
    rank,
    receipt,
  }
}

///|
fn point_hull(p : Array[Double], rank : Int32) -> HullMesh raise {
  output_hull(
    [p[0], p[1], p[2], p[0], p[1], p[2], p[0], p[1], p[2]],
    [0, 1, 2, 0, 2, 1],
    rank,
    { "degenerate_zero_volume": true, "native_qhull_called": false },
  )
}

///|
/// Rank-0/1/2 fallback semantics and full-rank reentrant Qhull Qt/TA + explicit
/// QJ retry. No scipy runtime or replacement convex-model object is involved.
pub async fn convex_hull(
  request : HullRequest,
  adapter : String,
  qhull_library : String,
) -> HullMesh {
  let v = request.vertices
  let n = v.length() / 3
  let eps = request.rank_epsilon
  guard v.length() % 3 == 0 &&
    n >= 1 &&
    n <= 2000000 &&
    v.all(finite) &&
    finite(eps) &&
    eps > 0 &&
    (request.max_vertices == 0 || request.max_vertices >= 3) else {
    fail("invalid convex input count/rank epsilon/vertex budget")
  }
  let center = Array::make(3, 0.0)
  for i in 0..<n {
    for k in 0..<3 {
      center[k] += v[i * 3 + k] / n.to_double()
    }
  }
  if n == 1 {
    return point_hull(center, 0)
  }
  let cov = Array::make(9, 0.0)
  for i in 0..<n {
    for a in 0..<3 {
      for b in 0..<3 {
        cov[a * 3 + b] += (v[i * 3 + a] - center[a]) *
          (v[i * 3 + b] - center[b])
      }
    }
  }
  let (values, basis) = eigen3(cov)
  let s0 = maxd(0, values[2]).sqrt()
  let s1 = maxd(0, values[1]).sqrt()
  let s2 = maxd(0, values[0]).sqrt()
  let scale = maxd(s0, eps)
  if s0 <= eps {
    return point_hull(center, 0)
  }
  let projections : Array[(Double, Double, Int32)] = []
  for i in 0..<n {
    let mut x = 0.0
    let mut y = 0.0
    for k in 0..<3 {
      x += (v[i * 3 + k] - center[k]) * basis[k * 3 + 2]
      y += (v[i * 3 + k] - center[k]) * basis[k * 3 + 1]
    }
    projections.push((x, y, i))
  }
  if s1 <= eps * scale {
    let mut lo = 0
    let mut hi = 0
    for i in 1..<n {
      if projections[i].0 < projections[lo].0 {
        lo = i
      }
      if projections[i].0 > projections[hi].0 {
        hi = i
      }
    }
    let out = []
    for i in [lo, hi] {
      for k in 0..<3 {
        out.push(v[i * 3 + k])
      }
    }
    for k in 0..<3 {
      out.push((v[lo * 3 + k] + v[hi * 3 + k]) / 2)
    }
    return output_hull(out, [0, 1, 2, 0, 2, 1], 1, {
      "degenerate_zero_volume": true,
      "native_qhull_called": false,
    })
  }
  if s2 <= eps * scale {
    projections.sort()
    let unique : Array[(Double, Double, Int32)] = []
    for p in projections {
      if unique.is_empty() ||
        unique.last().unwrap().0 != p.0 ||
        unique.last().unwrap().1 != p.1 {
        unique.push(p)
      }
    }
    fn cross(
      a : (Double, Double, Int32),
      b : (Double, Double, Int32),
      c : (Double, Double, Int32),
    ) -> Double {
      (b.0 - a.0) * (c.1 - a.1) - (b.1 - a.1) * (c.0 - a.0)
    }
    let lower : Array[(Double, Double, Int32)] = []
    let upper : Array[(Double, Double, Int32)] = []
    for p in unique {
      while lower.length() >= 2 &&
            cross(lower[lower.length() - 2], lower[lower.length() - 1], p) <= 0 {
        ignore(lower.pop())
      }
      lower.push(p)
    }
    for i = unique.length() - 1; i >= 0; i = i - 1 {
      let p = unique[i]
      while upper.length() >= 2 &&
            cross(upper[upper.length() - 2], upper[upper.length() - 1], p) <= 0 {
        ignore(upper.pop())
      }
      upper.push(p)
    }
    ignore(lower.pop())
    ignore(upper.pop())
    for p in upper {
      lower.push(p)
    }
    guard lower.length() >= 3 else {
      fail("planar hull numerically collapsed below rank-two support")
    }
    let keep = if request.max_vertices > 0 &&
      lower.length() > request.max_vertices {
      Array::makei(request.max_vertices, i => {
        lower[i * lower.length() / request.max_vertices].2
      })
    } else {
      lower.map(p => p.2)
    }
    let out = []
    for i in keep {
      for k in 0..<3 {
        out.push(v[i * 3 + k])
      }
    }
    let idx = []
    for i in 1..<(keep.length() - 1) {
      idx.push(0)
      idx.push(i)
      idx.push(i + 1)
    }
    for i in 1..<(keep.length() - 1) {
      idx.push(0)
      idx.push(i + 1)
      idx.push(i)
    }
    return output_hull(out, idx, 2, {
      "degenerate_zero_volume": true,
      "native_qhull_called": false,
    })
  }
  guard request.max_vertices == 0 || request.max_vertices >= 4 else {
    fail("full-rank hull needs max_vertices=0 or >=4")
  }
  let ad = explicit_file(adapter)
  let lib = explicit_file(qhull_library)
  let ad_sha = @artifacts.sha256(@fs.read_file(ad).binary())
  let lib_sha = @artifacts.sha256(@fs.read_file(lib).binary())
  let raw = []
  for value in v {
    let bits = value.reinterpret_as_int64().reinterpret_as_uint64()
    for k in 0..<8 {
      raw.push(((bits >> (k * 8)) & 255UL).to_byte())
    }
  }
  let native = hull_open(
    @utf8.encode(ad),
    @utf8.encode(lib),
    Bytes::from_array(raw),
    request.max_vertices,
  )
  defer hull_close(native)
  let error = @utf8.decode(hull_error(native))
  guard error.is_empty() else { fail(error) }
  let points = hull_points(native)
  let indices = hull_indices(native)
  guard points.length() % 12 == 0 &&
    points.length() >= 48 &&
    indices.length() % 12 == 0 &&
    indices.length() >= 12 else {
    fail("invalid native convex hull output cardinality")
  }
  let out = Array::makei(points.length() / 4, i => {
    Float::reinterpret_from_int(word(points, i * 4).to_int()).to_double()
  })
  let idx = Array::makei(indices.length() / 4, i => {
    word(indices, i * 4).reinterpret_as_int()
  })
  guard out.all(finite) &&
    idx.all(i => i >= 0 && i < out.length() / 3) &&
    @artifacts.sha256(@fs.read_file(ad).binary()) == ad_sha &&
    @artifacts.sha256(@fs.read_file(lib).binary()) == lib_sha else {
    fail("invalid hull output or changed native inputs")
  }
  {
    vertices: out,
    indices: idx,
    rank: 3,
    receipt: {
      "native_qhull_called": true,
      "qhull_version": "2020.2.r 2020/08/31",
      "adapter_sha256": Json(ad_sha),
      "library_sha256": Json(lib_sha),
      "joggled_retry": Json(hull_joggled(native) != 0),
      "numeric_equivalence_verified": false,
      "full_newton_cooking_complete": false,
    },
  }
}
