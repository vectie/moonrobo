///|
/// Full real-buffer footprint/shape proof; no numeric execution or upload.
/// All outputs are separate owners/views. Upstream's identical done in/out
/// aliases are represented by one explicit inout descriptor instead.
pub fn validate_bindings(
  request : Request,
  key : String,
  bindings : Array[Binding],
) -> Unit raise {
  let lowered = lower(request)
  let selected = lowered.entries.filter(item => item.key == key)
  guard selected.length() == 1 &&
    bindings.length() == selected[0].parameters.length() else {
    fail("device convergence entry/binding cardinality differs")
  }
  let indexed : Map[String, Binding] = {}
  for binding in bindings {
    guard !indexed.contains(binding.name) else {
      fail("duplicate device convergence binding")
    }
    indexed[binding.name] = binding
  }
  let intervals : Array[(String, Int64, Int64, Bool)] = []
  for param in selected[0].parameters {
    guard indexed.get(param.name) is Some(view) &&
      !view.allocation.is_empty() &&
      view.dtype == param.dtype &&
      view.shape.length() == param.rank &&
      view.byte_strides.length() == param.rank else {
      fail("device convergence typed descriptor differs")
    }
    let width = if param.dtype == "bool" { 1L } else { 4L }
    guard view.byte_offset >= 0L &&
      view.byte_offset % width == 0L &&
      view.shape.all(n => n > 0) &&
      view.byte_strides.all(n => n > 0 && n.to_int64() % width == 0L) &&
      view.buffer_bytes >= view.byte_offset &&
      width <= view.buffer_bytes - view.byte_offset else {
      fail("invalid convergence offset/alignment/rank/extent")
    }
    let shape = if param.name == "nsolving" {
      [1]
    } else if param.rank == 2 {
      [request.nworld, request.nv]
    } else {
      [request.nworld]
    }
    if param.name == "opt_tolerance" || param.name == "stat_meaninertia" {
      guard view.shape[0] == 1 || view.shape[0] == request.nworld else {
        fail("convergence model batch must be one or nworld")
      }
    } else {
      guard view.shape == shape else {
        fail("convergence world/vector shape differs")
      }
    }
    let mut end = view.byte_offset + width
    for axis in 0..<param.rank {
      let count = (view.shape[axis] - 1).to_int64()
      let stride = view.byte_strides[axis].to_int64()
      guard count <= (view.buffer_bytes - end) / stride else {
        fail("convergence full strided span exceeds owner")
      }
      end += count * stride
    }
    let writes = param.access != "input"
    if writes {
      let order = Array::makei(param.rank, i => i)
      order.sort_by(fn(a, b) {
        view.byte_strides[a].compare(view.byte_strides[b])
      })
      let mut covered = width
      for axis in order {
        if view.shape[axis] > 1 {
          guard view.byte_strides[axis].to_int64() >= covered else {
            fail("convergence writable elements alias")
          }
          covered += (view.shape[axis] - 1).to_int64() *
            view.byte_strides[axis].to_int64()
        }
      }
    }
    for (owner, lo, hi, other_writes) in intervals {
      guard owner != view.allocation ||
        !(writes || other_writes) ||
        end <= lo ||
        view.byte_offset >= hi else {
        fail("convergence writable argument aliases another parameter")
      }
    }
    intervals.push((view.allocation, view.byte_offset, end, writes))
  }
}
