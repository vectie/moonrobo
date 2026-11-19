///|
/// Mandatory real owner/shape/dtype/stride proof for every generated entry.
pub fn validate_bindings(
  r : Request,
  key : String,
  bindings : Array[Binding],
) -> Unit raise {
  validate(r)
  let ps = parameters(r, key)
  guard bindings.length() == ps.length() else {
    fail("Newton binding cardinality differs from real signature")
  }
  let indexed : Map[String, Binding] = {}
  for v in bindings {
    guard !indexed.contains(v.name) else { fail("duplicate Newton binding") }
    indexed[v.name] = v
  }
  let intervals : Array[(String, Int64, Int64, Bool)] = []
  for p in ps {
    guard indexed.get(p.name) is Some(v) &&
      !v.allocation.is_empty() &&
      v.dtype == p.dtype &&
      v.shape.length() == p.rank &&
      v.byte_strides.length() == p.rank else {
      fail("Newton array descriptor signature mismatch")
    }
    let primitive = if p.dtype == "bool" { 1L } else { 4L }
    let width = if p.dtype == "vec5f" { 20L } else { primitive }
    guard v.shape.all(n => n >= 0) &&
      v.byte_strides.all(n => n > 0 && n.to_int64() % primitive == 0L) &&
      v.byte_offset >= 0L &&
      v.byte_offset % primitive == 0L &&
      v.buffer_bytes >= v.byte_offset else {
      fail("Newton descriptor offset/alignment/extent invalid")
    }
    let shape = expected_shape(r, p.name)
    let broadcast = [
      "opt_tolerance", "opt_ls_tolerance", "stat_meaninertia", "opt_impratio_invsqrt",
    ].contains(p.name)
    guard v.shape == shape || (broadcast && v.shape == [1]) else {
      fail(
        "Newton descriptor differs from concrete specialization shape: " +
        p.name,
      )
    }
    if v.shape.any(n => n == 0) {
      continue
    }
    guard width <= v.buffer_bytes - v.byte_offset else {
      fail("Newton first complete element exceeds owner")
    }
    let mut end = v.byte_offset + width
    for axis in 0..<p.rank {
      let count = (v.shape[axis] - 1).to_int64()
      let stride = v.byte_strides[axis].to_int64()
      guard count <= (v.buffer_bytes - end) / stride else {
        fail("Newton full reachable strided span exceeds owner")
      }
      end += count * stride
    }
    let writes = p.access != "input"
    if writes {
      let axes = Array::makei(p.rank, i => i)
      axes.sort_by(fn(a, b) { v.byte_strides[a].compare(v.byte_strides[b]) })
      let mut covered = width
      for axis in axes {
        if v.shape[axis] > 1 {
          guard v.byte_strides[axis].to_int64() >= covered else {
            fail("Newton writable view aliases elements")
          }
          covered += (v.shape[axis] - 1).to_int64() *
            v.byte_strides[axis].to_int64()
        }
      }
    }
    for (owner, lo, hi, other_writes) in intervals {
      guard owner != v.allocation ||
        !(writes || other_writes) ||
        end <= lo ||
        v.byte_offset >= hi else {
        fail("Newton writable arguments overlap")
      }
    }
    intervals.push((v.allocation, v.byte_offset, end, writes))
  }
}
