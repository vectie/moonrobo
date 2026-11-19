///|
pub fn lower(r : Request) -> Lowered raise {
  validate(r)
  let entries = []
  let mut source = "#define WP_NO_CRT\n#include \"builtin.h\"\nconstexpr int MR_NV=\{r.nv};\nstatic_assert(sizeof(wp::array_t<float>)==56&&sizeof(wp::launch_bounds_t<1>)==24,\"actual Warp1.17 ABI\");\n" +
    common_source() +
    "\n"
  for key in r.kernels {
    let parameters = params(r, key)
    for p in parameters {
      let shape = expected_shape(r, p.name)
      let mut size = if p.dtype == "bool" { 1 } else { 4 }
      for extent in shape {
        guard extent > 0 && size <= 268435456 / extent else {
          fail("metric owner shape exceeds256MiB or has empty allocation")
        }
        size *= extent
      }
    }
    let body = if key == "effective-force" {
      force_source(r)
    } else if [
        "zero-sleeping", "copy-backbone-rhs", "block-solve", "efm0-solve",
      ].contains(key) {
      solve_source(r, key)
    } else if ["build-blocks", "factor-blocks", "factor-folded-blocks"].contains(
        key,
      ) {
      blocks_source(r, key)
    } else if key.has_prefix("fold-") ||
      key == "mul-tendon" ||
      key == "mul-actuator" ||
      key == "mul-contact" ||
      key == "add-tendon-qh-diag" ||
      key == "add-actuator-qh-diag" {
      rank1_source(r, key)
    } else {
      simple_source(r, key)
    }
    let forward = "mr_mjw_metric_" + key.replace_all(old="-", new="_")
    entries.push({ key, forward, launch_shape: [r.nworld], parameters, })
    source += "extern \"C\" __global__ void " +
      forward +
      "(wp::launch_bounds_t<1> bounds," +
      parameters.map(p => p.c_type + " " + p.name).join(",") +
      "){size_t block=size_t(blockIdx.x)+size_t(gridDim.x)*(size_t(blockIdx.y)+size_t(gridDim.y)*size_t(blockIdx.z));size_t linear=block*blockDim.x+threadIdx.x;if(linear>=\{r.nworld}||bounds.size!=\{r.nworld}||bounds.coord_mult!=1)return;int w=int(linear);if(wp::index(failure,w)!=0" +
      (if r.check_skip { "||wp::index(skip,w)" } else { "" }) +
      ")return;\n" +
      body +
      "}\n"
  }
  {
    request: r,
    source,
    source_sha256: @artifacts.sha256(@utf8.encode(source)),
    specialization_sha256: @artifacts.sha256(@utf8.encode(Json(r).stringify())),
    entries,
    launch_policy: {
      block_dim: 256,
      forward_smem: 0,
      backward_smem: 0,
      grid_stride: false,
      coord_mult: 1,
    },
  }
}
