///|
/// Every actual strided view, including padded outputs, must be proven against
/// its physical owner before native launch. Different writable operands cannot alias.
pub fn validate_bindings(
  r : Request,
  key : String,
  bindings : Array[Binding],
) -> Unit raise {
  validate(r)
  let ps = parameters(r, key)
  guard bindings.length() == ps.length() else {
    fail("adapter binding cardinality differs from genuine entry")
  }
  let table : Map[String, Binding] = {}
  for b in bindings {
    guard !table.contains(b.name) else { fail("duplicate adapter binding") }
    table[b.name] = b
  }
  let intervals : Array[(String, Int64, Int64, Bool)] = []
  for p in ps {
    guard table.get(p.name) is Some(b) &&
      !b.allocation.is_empty() &&
      b.dtype == p.dtype &&
      b.shape == expected_shape(r, p.name) &&
      b.byte_strides.length() == p.rank else {
      fail("adapter concrete signature mismatch: " + p.name)
    }
    let width = if p.dtype == "bool" { 1L } else { 4L }
    guard b.byte_offset >= 0L &&
      b.byte_offset % width == 0L &&
      b.buffer_bytes >= b.byte_offset &&
      b.byte_strides.all(s => s > 0 && s.to_int64() % width == 0L) else {
      fail("adapter alignment/offset invalid")
    }
    if b.shape.any(n => n == 0) {
      continue
    }
    guard width <= b.buffer_bytes - b.byte_offset else {
      fail("adapter first element exceeds owner")
    }
    let mut end = b.byte_offset + width
    for axis in 0..<p.rank {
      let n = (b.shape[axis] - 1).to_int64()
      let stride = b.byte_strides[axis].to_int64()
      guard n <= (b.buffer_bytes - end) / stride else {
        fail("adapter reachable strided span exceeds owner")
      }
      end += n * stride
    }
    let writes = p.access != "input"
    if writes {
      let axes = Array::makei(p.rank, i => i)
      axes.sort_by(fn(a, baxis) {
        b.byte_strides[a].compare(b.byte_strides[baxis])
      })
      let mut covered = width
      for a in axes {
        if b.shape[a] > 1 {
          guard b.byte_strides[a].to_int64() >= covered else {
            fail("adapter writable elements overlap")
          }
          covered += (b.shape[a] - 1).to_int64() * b.byte_strides[a].to_int64()
        }
      }
    }
    for (owner, lo, hi, ow) in intervals {
      guard owner != b.allocation ||
        !(writes || ow) ||
        end <= lo ||
        b.byte_offset >= hi else {
        fail("adapter writable arguments overlap")
      }
    }
    intervals.push((b.allocation, b.byte_offset, end, writes))
  }
}
