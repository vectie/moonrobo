///|
/// Gather CSR for a symmetric lower-triangular inertia storage. `madr` always
/// addresses original packed M values; off-diagonal values are never duplicated.
pub(all) struct MassGatherLayout {
  rowadr : Array[Int32]
  col : Array[Int32]
  madr : Array[Int32]
  source_nnz : Int32
} derive(Debug, ToJson)

///|
/// Port of `io.py`'s M_mulm_rowadr/M_mulm_col/M_mulm_madr construction.
/// Validation rejects missing diagonals, duplicates, upper entries and holes.
pub fn mass_gather_layout(
  nv : Int32,
  rowadr : Array[Int32],
  rownnz : Array[Int32],
  colind : Array[Int32],
) -> MassGatherLayout raise {
  guard nv > 0 &&
    rowadr.length() == nv &&
    rownnz.length() == nv &&
    colind.length() <= 1073741823 else {
    raise Unsupported::Invalid(
      "mass CSR row dimensions differ or symmetric gather overflows",
    )
  }
  let rows : Array[Array[(Int32, Int32)]] = Array::makei(nv, _ => [])
  let mut cursor = 0
  for row in 0..<nv {
    guard rowadr[row] == cursor &&
      rownnz[row] > 0 &&
      cursor <= colind.length() &&
      rownnz[row] <= colind.length() - cursor else {
      raise Unsupported::Invalid(
        "mass CSR rows must cover contiguous packed values",
      )
    }
    let columns : Map[Int32, Unit] = {}
    for k in 0..<rownnz[row] {
      let address = cursor + k
      let col = colind[address]
      guard col >= 0 && col <= row && !columns.contains(col) else {
        raise Unsupported::Invalid(
          "mass CSR requires unique lower-triangular columns",
        )
      }
      columns[col] = ()
      rows[row].push((col, address))
      if row != col {
        rows[col].push((row, address))
      }
    }
    guard columns.contains(row) else {
      raise Unsupported::Invalid("mass CSR diagonal is missing")
    }
    cursor += rownnz[row]
  }
  guard cursor == colind.length() else {
    raise Unsupported::Invalid("unconsumed mass CSR values")
  }
  let gather_rowadr : Array[Int32] = [0]
  let gather_col : Array[Int32] = []
  let gather_madr : Array[Int32] = []
  for row in rows {
    for (col, address) in row {
      gather_col.push(col)
      gather_madr.push(address)
    }
    gather_rowadr.push(gather_col.length())
  }
  {
    rowadr: gather_rowadr,
    col: gather_col,
    madr: gather_madr,
    source_nnz: cursor,
  }
}
