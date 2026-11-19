///|
pub suberror FactorizationError {
  Invalid(String)
  Unsupported(String)
  NonPositivePivot(world~ : Int32, dof~ : Int32)
} derive(Debug)

///|
/// Actual diagonal-last CSR layout. Packed tree mode requires every row to be
/// exactly the root-to-self ancestor prefix and every DOF to use sparse LDL.
pub(all) struct TreeLayout {
  dof_parentid : Array[Int32]
  m_rownnz : Array[Int32]
  m_rowadr : Array[Int32]
  m_colind : Array[Int32]
  qLD_block_adr : Array[Int32]
  qLD_block_total : Int32
} derive(FromJson, ToJson)

///|
pub(all) struct Update {
  i : Int32
  k : Int32
  madr_ki : Int32
} derive(FromJson, ToJson, Eq)

///|
/// One actual independent contiguous tree block from the model layout.
pub(all) struct SmallBlock {
  start : Int32
  size : Int32
} derive(FromJson, ToJson)

///|
/// Compact sentinel -2 or an actual packed row-major upper-factor offset.
/// Sparse sentinel -1, tiled/gather blocks and mixed paths are rejected here.
pub(all) struct BlockLayout {
  m_rownnz : Array[Int32]
  m_rowadr : Array[Int32]
  m_colind : Array[Int32]
  qLD_block_adr : Array[Int32]
  qLD_block_total : Int32
  blocks : Array[SmallBlock]
} derive(FromJson, ToJson)

///|
pub(all) struct TreeRequest {
  layout : TreeLayout
  matrix : Array[Array[Double]]
  rhs : Array[Array[Double]]?
  regularization : Double?
  skip_worlds : Array[Bool]?
} derive(FromJson)

///|
pub(all) struct BlockRequest {
  layout : BlockLayout
  matrix : Array[Array[Double]]
  rhs : Array[Array[Double]]?
  factor_seed : Array[Array[Double]]?
  inverse_diagonal_seed : Array[Array[Double]]?
  regularization : Double?
  skip_worlds : Array[Bool]?
} derive(FromJson)

///|
pub(all) struct CommandRequest {
  operation : String
  parameters : Json
} derive(FromJson)

///|
struct TreePlan {
  parent : Array[Int32]
  nnz : Array[Int32]
  adr : Array[Int32]
  col : Array[Int32]
  levels : Array[Array[Update]]
}

///|
pub struct TreeFactor {
  priv plan : TreePlan
  priv factors : Array[Array[Double]]
  priv inverse_diagonal : Array[Array[Double]]
}

///|
struct BlockPlan {
  nnz : Array[Int32]
  adr : Array[Int32]
  col : Array[Int32]
  factor_adr : Array[Int32]
  total : Int32
  blocks : Array[SmallBlock]
}

///|
pub struct BlockFactor {
  priv plan : BlockPlan
  priv factors : Array[Array[Double]]
  priv inverse_diagonal : Array[Array[Double]]
}

///|
fn finite(value : Double) -> Bool {
  value.abs() <= 1.7976931348623157e308
}

///|
fn rows_copy(rows : Array[Array[Double]]) -> Array[Array[Double]] {
  rows.map(row => row.copy())
}

///|
fn check_rows(
  rows : Array[Array[Double]],
  worlds : Int32,
  width : Int32,
  name : String,
) -> Unit raise FactorizationError {
  guard worlds > 0 &&
    rows.length() == worlds &&
    rows.all(row => row.length() == width && row.all(finite)) else {
    raise Invalid(
      name + " must have the exact finite [world,dof/storage] layout",
    )
  }
}

///|
fn options(
  worlds : Int32,
  regularization : Double?,
  skip_worlds : Array[Bool]?,
) -> Unit raise FactorizationError {
  if regularization is Some(value) {
    guard value == 0.0 else {
      raise Unsupported(
        "nonzero/nonfinite regularization is not part of the pinned inertia factorization",
      )
    }
  }
  if skip_worlds is Some(values) {
    guard values.length() == worlds else {
      raise Invalid("skip_worlds length differs from actual world count")
    }
    guard values.all(value => !value) else {
      raise Unsupported(
        "skipped-world state preservation is not supported by this fragment",
      )
    }
  }
}

///|
fn pivot(
  value : Double,
  world : Int32,
  dof : Int32,
) -> Unit raise FactorizationError {
  guard finite(value) && value > 0.0 else {
    raise NonPositivePivot(world~, dof~)
  }
}

///|
pub extend FactorizationError with @debug.Debug::{to_repr}

///|
pub extend TreeLayout with @json.FromJson::{from_json}

///|
pub extend TreeLayout with ToJson::{to_json}

///|
pub extend Update with @json.FromJson::{from_json}

///|
pub extend Update with ToJson::{to_json}

///|
pub extend Update with Eq::{equal, not_equal}

///|
pub extend SmallBlock with @json.FromJson::{from_json}

///|
pub extend SmallBlock with ToJson::{to_json}

///|
pub extend BlockLayout with @json.FromJson::{from_json}

///|
pub extend BlockLayout with ToJson::{to_json}

///|
pub extend TreeRequest with @json.FromJson::{from_json}

///|
pub extend BlockRequest with @json.FromJson::{from_json}

///|
pub extend CommandRequest with @json.FromJson::{from_json}

///|
/// One actual tree block. Gather indices are per-block flattened size*size;
/// None derives the identical io.py map, Some must match it including nC zeros.
pub(all) struct MixedBlock {
  start : Int32
  size : Int32
  elemid : Array[Int32]?
} derive(FromJson, ToJson)

///|
pub(all) struct MixedLayout {
  // Actual compiled-model tree metadata, rather than an inferred partition
  // from dof_parentid (decoupled DOFs can have several -1 parents in one tree).
  tree_dofadr : Array[Int32]
  tree_dofnum : Array[Int32]
  dof_parentid : Array[Int32]
  m_rownnz : Array[Int32]
  m_rowadr : Array[Int32]
  m_colind : Array[Int32]
  qLD_block_adr : Array[Int32]
  qLD_block_total : Int32
  blocks : Array[MixedBlock]
} derive(FromJson, ToJson)

///|
pub(all) struct MixedRequest {
  layout : MixedLayout
  matrix : Array[Array[Double]]
  rhs : Array[Array[Double]]?
  factor_seed : Array[Array[Double]]?
  inverse_diagonal_seed : Array[Array[Double]]?
  regularization : Double?
  skip_worlds : Array[Bool]?
} derive(FromJson)

///|
priv enum BlockKind {
  Compact
  Scalar
  Gather
  Sparse
} derive(Eq)

///|
priv struct PlannedBlock {
  start : Int32
  size : Int32
  kind : BlockKind
  elemid : Array[Int32]
}

///|
struct MixedPlan {
  tree_adr : Array[Int32]
  tree_num : Array[Int32]
  parent : Array[Int32]
  nnz : Array[Int32]
  adr : Array[Int32]
  col : Array[Int32]
  factor_adr : Array[Int32]
  total : Int32
  has_sparse : Bool
  blocks : Array[PlannedBlock]
  levels : Array[Array[Update]]
}

///|
pub struct MixedFactor {
  priv plan : MixedPlan
  priv factors : Array[Array[Double]]
  priv inverse_diagonal : Array[Array[Double]]
}

///|
pub extend MixedBlock with @json.FromJson::{from_json}

///|
pub extend MixedBlock with ToJson::{to_json}

///|
pub extend MixedLayout with @json.FromJson::{from_json}

///|
pub extend MixedLayout with ToJson::{to_json}

///|
pub extend MixedRequest with @json.FromJson::{from_json}
