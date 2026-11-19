///|
/// Pure validated model metadata shared by CPU factors and GPU lowering.
/// These records contain copies; constructing a plan never factors a matrix.
pub(all) struct LayoutBlock {
  start : Int32
  size : Int32
  kind : String
  factor_adr : Int32
  elemid : Array[Int32]
} derive(ToJson)

///|
pub(all) struct LayoutPlan {
  nv : Int32
  nC : Int32
  factor_width : Int32
  dense_prefix : Int32
  has_sparse : Bool
  blocks : Array[LayoutBlock]
  levels : Array[Array[Update]]
  row_nnz : Array[Int32]
  row_adr : Array[Int32]
  factor_adr : Array[Int32]
} derive(ToJson)

///|
pub fn describe_mixed_layout(
  layout : MixedLayout,
) -> LayoutPlan raise FactorizationError {
  let plan = mixed_plan(layout)
  {
    nv: plan.nnz.length(),
    nC: plan.col.length(),
    factor_width: plan.total +
    (if plan.has_sparse { plan.col.length() } else { 0 }),
    dense_prefix: plan.total,
    has_sparse: plan.has_sparse,
    blocks: plan.blocks.map(block => {
      start: block.start,
      size: block.size,
      kind: match block.kind {
        Compact => "compact"
        Scalar => "scalar"
        Gather => "gather"
        Sparse => "sparse"
      },
      factor_adr: plan.factor_adr[block.start],
      elemid: block.elemid.copy(),
    }),
    levels: plan.levels.map(level => level.copy()),
    row_nnz: plan.nnz.copy(),
    row_adr: plan.adr.copy(),
    factor_adr: plan.factor_adr.copy(),
  }
}

///|
pub extend LayoutBlock with ToJson::{to_json}

///|
pub extend LayoutPlan with ToJson::{to_json}
