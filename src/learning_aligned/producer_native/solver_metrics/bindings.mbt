///|
/// Model topology owners which must remain immutable throughout the program.
/// Dynamic contact/J/actuator descriptors are guarded before every device read.
pub fn immutable_parameters() -> Array[String] {
  [
    "M_rownnz", "M_rowadr", "M_colind", "K_rownnz", "K_rowadr", "K_colind", "efm_dofid",
    "efm_dofblk", "dof_treeid", "efm0_dofid", "efm0_L_rownnz", "efm0_L_rowadr", "efm0_L_colind",
    "efm0_L", "ten_rownnz", "ten_rowadr", "ten_colind", "M_mulm_rowadr", "M_mulm_col",
    "M_mulm_madr",
  ]
}

///|
pub fn validate_bindings(
  r : Request,
  key : String,
  bindings : Array[Binding],
) -> Unit raise {
  validate(r)
  guard r.kernels.contains(key) else { fail("metric entry is not compiled") }
  let ps = params(r, key)
  guard ps.length() == bindings.length() else {
    fail("metric binding cardinality differs")
  }
  let expected : Map[String, Parameter] = Map([])
  let seen : Map[String, Unit] = Map([])
  let owners : Map[String, Binding] = Map([])
  for p in ps {
    expected[p.name] = p
  }
  for b in bindings {
    guard expected.get(b.name) is Some(p) &&
      !seen.contains(b.name) &&
      !b.owner.is_empty() else {
      fail("unknown, duplicate or ownerless metric binding")
    }
    seen[b.name] = ()
    let shape = expected_shape(r, b.name)
    guard b.dtype == p.dtype &&
      b.shape == shape &&
      b.byte_strides.length() == shape.length() else {
      fail("metric typed shape differs")
    }
    let width = if b.dtype == "bool" { 1 } else { 4 }
    let mut bytes = width
    for s in 0..<shape.length() {
      let i = shape.length() - 1 - s
      guard shape[i] > 0 &&
        bytes <= 268435456 / shape[i] &&
        b.byte_strides[i] == bytes else {
        fail("metric view must be positive contiguous and <=256MiB")
      }
      bytes *= shape[i]
    }
    guard b.offset_bytes % width.to_uint64() == 0UL &&
      b.offset_bytes <= b.capacity_bytes &&
      bytes.to_uint64() <= b.capacity_bytes - b.offset_bytes else {
      fail("metric view exceeds aligned owner storage")
    }
    if owners.get(b.owner) is Some(previous) {
      let pair = (b.name == "rhs" && previous.name == "res") ||
        (b.name == "res" && previous.name == "rhs")
      guard ["copy-backbone-rhs", "block-solve", "efm0-solve"].contains(key) &&
        pair &&
        b.dtype == previous.dtype &&
        b.shape == previous.shape &&
        b.byte_strides == previous.byte_strides &&
        b.offset_bytes == previous.offset_bytes &&
        b.capacity_bytes == previous.capacity_bytes else {
        fail("metric owners alias outside exact supported rhs/res view")
      }
    } else {
      owners[b.owner] = b
    }
  }
}

///|
pub fn validate_initial_failure(nworld : Int32, bytes : Bytes) -> Unit raise {
  @sparse_solver.validate_initial_failure(nworld, bytes)
}
