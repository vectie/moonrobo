///|
fn entry_source(
  request : Request,
  plan : @factorization.LayoutPlan,
  key : String,
  params : Array[Parameter],
  sizes : Array[Int32],
) -> String {
  let factor = key != "mixed-solve"
  let solve = key != "mixed-factor"
  let flags = (if factor { "true" } else { "false" }) +
    "," +
    (if solve { "true" } else { "false" })
  let scalar = "wp::" + request.dtype
  let args = params.map(p => p.c_type + " " + p.name).join(", ")
  let mut source = "extern \"C\" __global__ void mr_" +
    key.replace(old="-", new="_") +
    "(wp::launch_bounds_t<1> bounds," +
    args +
    "){\n" +
    "const size_t wid=size_t(blockIdx.x)+size_t(gridDim.x)*(size_t(blockIdx.y)+size_t(gridDim.y)*size_t(blockIdx.z));\n" +
    "if(wid>=MR_WORLDS || bounds.size!=size_t(MR_WORLDS)*MR_THREADS || bounds.coord_mult!=1 || blockDim.x!=MR_THREADS)return;\nint w=int(wid);int lane=int(threadIdx.x);\n" +
    "__shared__ int entry_skip;\nif(lane==0)entry_skip=(wp::index(failure,w)!=0" +
    (if request.check_done { " || wp::index(done,w)" } else { "" }) +
    ");\n__syncthreads();\nif(entry_skip)return;\n"
  if !factor {
    source += "wp::array_t<" + scalar + "> matrix;\n"
  }
  if plan.factor_width == 0 {
    source += "wp::array_t<" + scalar + "> factor;\n"
  }
  if !solve {
    source += "wp::array_t<" + scalar + "> rhs,solution;\n"
  }
  let max_size = if sizes.is_empty() { 1 } else { sizes[sizes.length() - 1] }
  source += "__shared__ __align__(16) " +
    scalar +
    " a[\{max_size*max_size}];\n__shared__ __align__(16) " +
    scalar +
    " b[\{max_size}];\n"
  source += "for(int blk=0;blk<MR_BLOCKS;++blk){int start=wp::index(blocks,blk,0),n=wp::index(blocks,blk,1),kind=wp::index(blocks,blk,2),fa=wp::index(blocks,blk,3),go=wp::index(blocks,blk,4);\n" +
    "if(kind<2)mr_small<" +
    scalar +
    "," +
    flags +
    ">(n,start,fa,wp::index(row_adr,start),w,matrix,factor,diagonal,rhs,solution,failure);\n" +
    "else if(kind==2){switch(n){\n"
  for size in sizes {
    source += "case \{size}:mr_gather<" +
      scalar +
      ",\{size}," +
      flags +
      ">(start,fa,go,w,a,b,gather_indices,matrix,factor,rhs,solution,failure);break;\n"
  }
  source += "default:if(lane==0)mr_fail(failure,w);break;}}\n__syncthreads();}\n"
  if plan.has_sparse {
    source += "mr_sparse<" +
      scalar +
      "," +
      flags +
      ">(w,row_nnz,row_adr,factor_adr,updates,level_offsets,matrix,factor,diagonal,rhs,solution,failure);\n"
  }
  source + "}\n"
}

///|
/// Complete supported mass/inertia mixed factor/solve GPU bodies. Metadata
/// planning does not factor a matrix; no compiler or device is opened here.
pub fn lower(request : Request) -> Lowered raise {
  let plan = @factorization.describe_mixed_layout(request.layout)
  dimensions(
    request.dtype,
    request.nworld,
    request.block_dim,
    request.architecture,
    plan.nv,
    plan.nC,
  )
  dimensions(
    request.dtype,
    request.nworld,
    request.block_dim,
    request.architecture,
    plan.nv,
    plan.factor_width,
  )
  let sizes = []
  for block in plan.blocks {
    if block.kind == "gather" && !sizes.contains(block.size) {
      sizes.push(block.size)
    }
  }
  sizes.sort()
  let max_size = if sizes.is_empty() { 1 } else { sizes[sizes.length() - 1] }
  let header = "#define WP_TILE_BLOCK_DIM \{request.block_dim}\n#define WP_ENABLE_MATHDX 0\n#include \"builtin.h\"\n#include \"tile_cholesky.h\"\n#include \"tile_solve.h\"\n" +
    "static_assert(sizeof(wp::array_t<float>)==56,\"actual Warp array ABI\");\nstatic_assert(sizeof(wp::launch_bounds_t<1>)==24,\"actual Warp bounds ABI\");\n" +
    "#define MR_NV \{plan.nv}\n#define MR_NC \{plan.nC}\n#define MR_PREFIX \{plan.dense_prefix}\n#define MR_LEVELS \{plan.levels.length()}\n#define MR_BLOCKS \{plan.blocks.length()}\n#define MR_THREADS \{request.block_dim}\n#define MR_WORLDS \{request.nworld}\n"
  let entries = []
  let mut source = header + helpers() + "\n"
  for key in ["mixed-factor", "mixed-solve", "mixed-factor-solve"] {
    let params = parameters(request, plan, key)
    entries.push({
      key,
      forward: "mr_" + key.replace(old="-", new="_"),
      launch_shape: [request.nworld * request.block_dim],
      parameters: params,
    })
    source += entry_source(request, plan, key, params, sizes)
  }
  guard @utf8.encode(source).length() <= 16777216 else {
    raise Invalid("generated solver source exceeds 16 MiB")
  }
  {
    request,
    source,
    source_sha256: @artifacts.sha256(@utf8.encode(source)),
    specialization_sha256: @artifacts.sha256(
      @utf8.encode(Json(request).stringify()),
    ),
    entries,
    launch_policy: {
      block_dim: request.block_dim,
      forward_smem: 0,
      backward_smem: 0,
      grid_stride: false,
      coord_mult: 1,
    },
    metadata: metadata(plan),
    factor_width: plan.factor_width,
    nC: plan.nC,
    nv: plan.nv,
    sparse_levels: plan.levels.length(),
    body_static_shared_bytes: (
      max_size * max_size * scalar_width(request.dtype) + 15
    ) /
    16 *
    16 +
    (max_size * scalar_width(request.dtype) + 15) / 16 * 16 +
    16,
  }
}
