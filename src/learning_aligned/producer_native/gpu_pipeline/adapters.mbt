///|
/// Reuses the finalizer's actual owned raw arrays, preserving little-endian
/// scalar bits. Empty owners need no allocation. Aliases remain views onto
/// those owners and are not duplicated. This does not upload or execute CUDA.
pub fn host_buffers(
  layout : @finalize.HostLayout,
  prefix~ : String = "",
) -> Array[HostBuffer] raise {
  guard prefix.is_empty() || identifier(prefix) else {
    fail("invalid host buffer namespace")
  }
  let result = []
  let owners : Map[String, HostBuffer] = Map([])
  let total = Ref(0)
  for name in layout.array_names() {
    let array = layout.array(name)
    // Public metadata validates shape/components and actual byte length.
    // It performs no numerical calculation or device operation.
    ignore(array.metadata())
    let scalar_type = host_scalar_type(array.scalar_type)
    if !array.bytes.is_empty() {
      let buffer : HostBuffer = {
        name: if prefix.is_empty() {
          name
        } else {
          prefix + "." + name
        },
        scalar_type,
        bytes: array.bytes,
      }
      add_buffer(owners, buffer, total)
      result.push(buffer)
    }
  }
  result
}

///|
fn packed_double_buffer(
  name : String,
  rows : Array[Array[Double]],
) -> HostBuffer raise {
  let width = if rows.is_empty() { 0 } else { rows[0].length() }
  guard width <= 268435456 / 8 &&
    (width == 0 || rows.length() <= 268435456 / 8 / width) else {
    fail("CPU Double seed exceeds GPU owner capacity")
  }
  let bytes = []
  for row in rows {
    guard row.length() == width else { fail("nonrectangular CPU Double seed") }
    for value in row {
      guard !value.is_nan() && !value.is_inf() else {
        fail("nonfinite CPU Double seed")
      }
      let bits = value.reinterpret_as_int64().reinterpret_as_uint64()
      for byte in 0..<8 {
        bytes.push(((bits >> (8 * byte)) & 255UL).to_byte())
      }
    }
  }
  { name, scalar_type: "float64", bytes: Bytes::from_array(bytes), }
}

///|
/// Packs an already-computed CPU/Double MixedFactor into row-major,
/// little-endian float64 qLD and qLDiagInv owners. No factorization, conversion
/// to float32, upload, or GPU factor kernel is performed. qLD's empty compact
/// storage is omitted; names/shapes for explicit kernel views remain caller
/// metadata. Returned Bytes own their packed data independently of the factor.
pub fn mixed_factor_buffers(
  factor : @factorization.MixedFactor,
  qld_name~ : String = "qLD",
  inverse_name~ : String = "qLDiagInv",
) -> Array[HostBuffer] raise {
  guard identifier(qld_name) &&
    identifier(inverse_name) &&
    qld_name != inverse_name else {
    fail("invalid or duplicate CPU factor buffer names")
  }
  let result = []
  let owners : Map[String, HostBuffer] = Map([])
  let total = Ref(0)
  for
    buffer in [
      packed_double_buffer(qld_name, factor.qld()),
      packed_double_buffer(inverse_name, factor.inverse_diagonal()),
    ] {
    if !buffer.bytes.is_empty() {
      add_buffer(owners, buffer, total)
      result.push(buffer)
    }
  }
  result
}
