///|
fn helpers(r : Request) -> String {
  let j = if r.jacobian_layout == "dense" {
    "return wp::index(s.J,w,e,d);"
  } else {
    "float x=0.0f;int a=wp::index(s.J_rowadr,w,e),n=wp::index(s.J_rownnz,w,e);for(int k=a;k<a+n;k++)if(wp::index(s.J_colind,w,0,k)==d)x=wp::index(s.J,w,0,k);return x;"
  }
  let jvalid = if r.jacobian_layout == "dense" {
    "for(int e=0;e<n;e++)for(int d=0;d<AN;d++)if(!wp::isfinite(wp::index(s.J,w,e,d)))return false;"
  } else {
    "for(int e=0;e<n;e++){int a=wp::index(s.J_rowadr,w,e),nnz=wp::index(s.J_rownnz,w,e);if(a<0||nnz<0||a>AJCAP||nnz>AJCAP-a)return false;for(int k=a;k<a+nnz;k++){int d=wp::index(s.J_colind,w,0,k);if(d<0||d>=AN||!wp::isfinite(wp::index(s.J,w,0,k)))return false;for(int p=a;p<k;p++)if(wp::index(s.J_colind,w,0,p)==d)return false;}}"
  }
  let compact = if r.compact {
    "int d=wp::index(s.cdof_dof,w,c);return d>=0?ajfull(s,w,e,d):0.0f;"
  } else {
    "return c<AN?ajfull(s,w,e,c):0.0f;"
  }
  "static __device__ void afail(const AS&s,int w,int bit){wp::index(s.status,w)|=bit;}\nstatic __device__ float adiv(float x,float y){return x/(y!=0.0f?y:1.0e-15f);}\n" +
  "static __device__ bool amaps(const AS&s,int w){int n=wp::index(s.ncdof,w);if(n<0||n>AC||n>AN)return false;int actual=0;for(int d=0;d<AN;d++){int c=wp::index(s.dof_cdof,w,d);if(c>=0){if(c>=n||wp::index(s.cdof_dof,w,c)!=d)return false;actual++;}}if(actual!=n)return false;for(int c=0;c<AC;c++){int d=wp::index(s.cdof_dof,w,c);if(c<n){if(d<0||d>=AN||wp::index(s.dof_cdof,w,d)!=c)return false;}else if(d>=0)return false;}return true;}\n" +
  "static __device__ bool amass(const AS&s,int w){int prefix=0;for(int i=0;i<AN;i++){int a=wp::index(s.M_rowadr,i),n=wp::index(s.M_rownnz,i);if(a!=prefix||n<1||n>AMNNZ-prefix)return false;int prev=-1;for(int k=a;k<a+n;k++){int c=wp::index(s.M_colind,k);if(c<=prev||c>i||!wp::isfinite(wp::index(s.M,w,k)))return false;prev=c;}if(prev!=i)return false;prefix+=n;}return prefix==AMNNZ;}\n" +
  "static __device__ bool agather(const AS&s){int prev=wp::index(s.M_mulm_rowadr,0);if(prev!=0)return false;for(int i=1;i<=AN;i++){int next=wp::index(s.M_mulm_rowadr,i);if(next<prev||next>AGNNZ)return false;prev=next;}if(prev!=AGNNZ)return false;for(int k=0;k<AGNNZ;k++){int c=wp::index(s.M_mulm_col,k),a=wp::index(s.M_mulm_madr,k);if(c<0||c>=AN||a<0||a>=AMNNZ)return false;}return true;}\n" +
  "static __device__ bool ajvalid(const AS&s,int w){int n=wp::index(s.nefc,w);if(n<0||n>AR)return false;" +
  jvalid +
  "return true;}\n" +
  "static __device__ float ajfull(const AS&s,int w,int e,int d){" +
  j +
  "}\nstatic __device__ float aj(const AS&s,int w,int e,int c){" +
  compact +
  "}\n"
}

///|
/// Generates all real compact/gather/scatter and incremental equations;
/// source-only lowering never calls any compiler, SDK or numeric algorithm.
pub fn lower(r : Request) -> Lowered raise {
  validate(r)
  let universe : Map[String, Parameter] = {}
  for key in supported_kernels() {
    for p in parameters(r, key) {
      universe[p.name] = p
    }
  }
  let names = universe.keys().collect()
  names.sort()
  let blocks = [
    "// Copyright 2026 The Newton Developers\n// SPDX-License-Identifier: Apache-2.0\n// MuJoCo-Warp 3.15 compact/incremental reference kernels; no Python fallback.\n#define WP_NO_CRT\n#include \"builtin.h\"\nstatic_assert(sizeof(wp::array_t<float>)==56 && sizeof(bool)==1,\"Warp 1.17 ABI\");\nconstexpr int AN=\{r.nv},AC=\{r.nv_compact},AR=\{r.njmax},AMNNZ=\{r.mass_nnz},AJCAP=\{r.jacobian_capacity},AGNNZ=\{r.gather_nnz};\nstruct AS{\n" +
    names.map(n => universe[n].c_type + " " + n + ";").join("\n") +
    "};\n",
  ]
  blocks.push(helpers(r))
  let entries : Array[Entry] = []
  let seen : Map[String, Unit] = {}
  for key in r.kernels {
    guard !seen.contains(key) else { fail("duplicate solver adapter kernel") }
    seen[key] = ()
    let ps = parameters(r, key)
    let name = "mr_mjw_adapter_" + key.replace_all(old="-", new="_")
    let body = if key.has_prefix("compact-") || key == "full-mass-multiply" {
      compact_body(key)
    } else {
      incremental_body(r, key)
    }
    blocks.push(
      "extern \"C\" __global__ void " +
      name +
      "(wp::launch_bounds_t<1> dim," +
      ps.map(p => p.c_type + " " + p.name).join(",") +
      "){for(size_t linear=size_t(blockIdx.x)*blockDim.x+threadIdx.x;linear<dim.size;linear+=size_t(blockDim.x)*gridDim.x){int w=int(linear);AS s{};" +
      ps.map(p => "s." + p.name + "=" + p.name + ";").join("") +
      "if(wp::index(s.status,w))continue;" +
      body +
      "}}\n",
    )
    entries.push({
      key,
      forward: name,
      launch_shape: [r.nworld],
      parameters: ps,
    })
  }
  let source = blocks.join("\n")
  let sha = @artifacts.sha256(@utf8.encode(source))
  let policy : @newton_solver.LaunchPolicy = {
    block_dim: 256,
    forward_smem: 0,
    backward_smem: 0,
    grid_stride: true,
    coord_mult: 1,
  }
  let identity : Json = {
    "format": "moonrobo-native-solver-adapters-specialization-v1",
    "request": r.to_json(),
    "entries": entries.to_json(),
    "source_sha256": Json(sha),
    "launch_policy": policy.to_json(),
    "mujoco_warp_version": "3.15.0",
    "warp_version": "1.17.0",
  }
  {
    request: r,
    source,
    source_sha256: sha,
    specialization_sha256: @artifacts.sha256(@utf8.encode(identity.stringify())),
    entries,
    launch_policy: policy,
  }
}
