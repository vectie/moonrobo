///|
pub struct IsoMesh {
  vertices : Array[Double]
  indices : Array[Int32]
} derive(ToJson)

///|
/// Actual source MC cases/edge interpolation/0.02..0.98 clamp and reversed
/// faces. CPU deterministic block/cell order replaces GPU atomic append order.
/// No resource upload, SDK call or Mesh/BVH construction occurs here.
pub fn SparseSdf::isomesh(
  self : SparseSdf,
  isovalue : Double,
  max_triangles~ : Int32 = 1000000,
) -> IsoMesh? raise {
  self.validate()
  guard finite(isovalue) &&
    !Float::from_double(isovalue).is_inf() &&
    max_triangles >= 1 &&
    max_triangles <= 4000000 else {
    fail("invalid bounded isosurface request")
  }
  let ranges = mc_ranges()
  let triangles = mc_triangles()
  let corners = [
    [0, 0, 0],
    [1, 0, 0],
    [1, 1, 0],
    [0, 1, 0],
    [0, 0, 1],
    [1, 0, 1],
    [1, 1, 1],
    [0, 1, 1],
  ]
  let edges = [
    (0, 1),
    (1, 2),
    (2, 3),
    (3, 0),
    (4, 5),
    (5, 6),
    (6, 7),
    (7, 4),
    (0, 4),
    (1, 5),
    (2, 6),
    (3, 7),
  ]
  let vertices = []
  let indices = []
  for bx in 0..<self.slot_shape[0] {
    for by in 0..<self.slot_shape[1] {
      for bz in 0..<self.slot_shape[2] {
        let slot = word(
          self.slots,
          ((bx * self.slot_shape[1] + by) * self.slot_shape[2] + bz) * 4,
        )
        if slot == 0xffffffffU {
          continue
        }
        for x in 0..<8 {
          for y in 0..<8 {
            for z in 0..<8 {
              let origin = [bx * 8 + x, by * 8 + y, bz * 8 + z]
              let values = corners.map(c => {
                Float::from_double(
                  self.sample_voxel([
                    origin[0] + c[0],
                    origin[1] + c[1],
                    origin[2] + c[2],
                  ]),
                )
              })
              let mut case_id = 0
              for i in 0..<8 {
                if values[i] < Float::from_double(isovalue) {
                  case_id = case_id | (1 << i)
                }
              }
              let start = ranges[case_id]
              let end = ranges[case_id + 1]
              guard indices.length() / 3 + (end - start) / 3 <= max_triangles else {
                fail("isosurface triangle budget exceeded")
              }
              for face in 0..<((end - start) / 3) {
                let base = vertices.length() / 3
                for vertex in 0..<3 {
                  let (a, b) = edges[triangles[start + face * 3 + vertex]]
                  let delta = values[b] - values[a]
                  let t = if delta.abs() < 1.0e-10F {
                    0.5F
                  } else {
                    Float::from_double(
                      clampd(
                        ((Float::from_double(isovalue) - values[a]) / delta).to_double(),
                        0.02F.to_double(),
                        0.98F.to_double(),
                      ),
                    )
                  }
                  for k in 0..<3 {
                    let p = Float::from_int(corners[a][k]) +
                      t * Float::from_int(corners[b][k] - corners[a][k])
                    let world = Float::from_double(self.lower[k]) +
                      (Float::from_int(origin[k]) + p) *
                      Float::from_double(self.cell_size[k])
                    guard !world.is_nan() && !world.is_inf() else {
                      fail("isosurface coordinate overflows float32")
                    }
                    vertices.push(world.to_double())
                  }
                }
                indices.push(base + 2)
                indices.push(base + 1)
                indices.push(base)
              }
            }
          }
        }
      }
    }
  }
  if indices.is_empty() {
    None
  } else {
    Some({ vertices, indices, })
  }
}
