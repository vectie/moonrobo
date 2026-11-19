///|
fn constraint_source() -> String {
  (
    #|static __device__ MREllipse mr_load_ellipse(const MRState& s,int w,int con){
    #| MREllipse e{};int row=wp::index(s.contact_efc_address,con,0),dim=wp::index(s.contact_dim,con);auto f=wp::index(s.contact_friction,con);
    #| e.mu=f[0]*wp::index(s.opt_impratio_invsqrt,w%s.opt_impratio_invsqrt.shape[0]);float x=wp::index(s.ctx_Jaref,w,row),v=wp::index(s.ctx_jv,w,row),D=wp::index(s.efc_D,w,row);
    #| e.q0=0.5f*x*x*D;e.q1=(v*D)*x;e.q2=0.5f*v*(v*D);e.u0=x*e.mu;e.v0=v*e.mu;e.dm=D/(e.mu*e.mu*(1.0f+e.mu*e.mu));
    #| for(int a=1;a<dim;a++){int r=wp::index(s.contact_efc_address,con,a);float xj=wp::index(s.ctx_Jaref,w,r),vj=wp::index(s.ctx_jv,w,r),Dj=wp::index(s.efc_D,w,r),DJ=Dj*xj;
    #| e.q0+=0.5f*xj*DJ;e.q1+=vj*DJ;e.q2+=0.5f*vj*Dj*vj;float u=xj*f[a-1],vv=vj*f[a-1];e.uu+=u*u;e.uv+=u*vv;e.vv+=vv*vv;}
    #| return mr_ellipse_reference(e);
    #|}
    #|static __device__ MRPoint mr_constraint_row(const MRState& s,int w,int row){
    #| int ne=wp::index(s.ne,w),nf=wp::index(s.nf,w);float D=wp::index(s.efc_D,w,row),x=wp::index(s.ctx_Jaref,w,row);
    #| if(row<ne)return {-D*x,1.0f,0.5f*D*x*x};
    #| if(row<ne+nf){float f=wp::index(s.efc_frictionloss,w,row),rf=mr_div(f,D);if(x<=-rf)return {f,2.0f,-f*(0.5f*rf+x)};if(x>=rf)return {-f,3.0f,-f*(0.5f*rf-x)};return {-D*x,1.0f,0.5f*D*x*x};}
    #| if(wp::index(s.efc_type,w,row)==7){int con=wp::index(s.efc_id,w,row),normal=wp::index(s.contact_efc_address,con,0),dim=wp::index(s.contact_dim,con);auto f=wp::index(s.contact_friction,con);
    #| float mu=f[0]*wp::index(s.opt_impratio_invsqrt,w%s.opt_impratio_invsqrt.shape[0]),N=wp::index(s.ctx_Jaref,w,normal)*mu,tt=0.0f,uf=0.0f;
    #| for(int a=1;a<dim;a++){int r=wp::index(s.contact_efc_address,con,a);float u=wp::index(s.ctx_Jaref,w,r)*f[a-1];tt+=u*u;if(r==row)uf=u*f[a-1];}
    #| float T=tt<=0.0f?0.0f:wp::sqrt(tt);if(N>=mu*T||(T<=0.0f&&N>=0.0f))return {0.0f,0.0f,0.0f};
    #| if(mu*N+T<=0.0f||(T<=0.0f&&N<0.0f))return {-D*x,1.0f,0.5f*D*x*x};
    #| float dm=mr_div(wp::index(s.efc_D,w,normal),mu*mu*(1.0f+mu*mu)),r=N-mu*T,fn=-dm*r*mu;
    #| if(row==normal)return {fn,4.0f,0.5f*dm*r*r};return {-mr_div(fn,T)*uf,4.0f,0.0f};}
    #| if(x>=0.0f)return {0.0f,0.0f,0.0f};return {-D*x,1.0f,0.5f*D*x*x};
    #|}
    #|static __device__ float mr_cone_hessian(const MRState& s,int w,int con,int i,int j){
    #| int row=wp::index(s.contact_efc_address,con,0);if(wp::index(s.efc_state,w,row)!=4||wp::index(s.contact_dist,con)-wp::index(s.contact_includemargin,con)>=0.0f)return 0.0f;
    #| auto f=wp::index(s.contact_friction,con);float mu=f[0]*wp::index(s.opt_impratio_invsqrt,w%s.opt_impratio_invsqrt.shape[0]),mu2=mu*mu,dm=mr_div(wp::index(s.efc_D,w,row),mu2*(1.0f+mu2));if(dm==0.0f)return 0.0f;
    #| float n=wp::index(s.ctx_Jaref,w,row)*mu,z1=mu*mr_J(s,w,row,i),z2=mu*mr_J(s,w,row,j),tt=0.0f,p1=0.0f,p2=0.0f,dot=0.0f;int dim=wp::index(s.contact_dim,con);
    #| for(int a=1;a<dim;a++){int r=wp::index(s.contact_efc_address,con,a);float scale=f[a-1],u=wp::index(s.ctx_Jaref,w,r)*scale,a1=scale*mr_J(s,w,r,i),a2=scale*mr_J(s,w,r,j);tt+=u*u;p1+=u*a1;p2+=u*a2;dot+=a1*a2;}
    #| float t=wp::max(wp::sqrt(tt),1.0e-15f),it=mr_div(1.0f,t),mnt=mu*n*it;p1*=it;p2*=it;
    #| return dm*(z1*z2-mu*(z1*p2+z2*p1)+mnt*p1*p2+(mu2-mnt)*dot);
    #|}
  )
}

///|
fn initialize_body(r : Request) -> String {
  let select = if r.warmstart {
    "wp::index(s.nefc,w)>0?wp::index(s.qacc_warmstart,w,i):wp::index(s.qacc_smooth,w,i)"
  } else {
    "wp::index(s.qacc_smooth,w,i)"
  }
  "for(int i=0;i<MR_NV;i++){wp::index(s.qacc,w,i)=" +
  select +
  ";for(int j=0;j<MR_NV;j++){float v=mr_mass(s,w,i,j)+wp::index(s.added_metric,w,i,j);if(!mr_finite(v)){mr_fail(s,w,2);break;}wp::index(s.mass_dense,w,i,j)=v;}wp::index(s.qfrc_constraint,w,i)=0.0f;}\n" +
  "if(wp::index(s.status,w))continue;for(int i=0;i<MR_NV;i++){float a=0.0f;for(int j=0;j<MR_NV;j++)a+=wp::index(s.mass_dense,w,i,j)*wp::index(s.qacc,w,j);wp::index(s.ctx_Ma,w,i)=a;}\n" +
  "for(int row=0;row<wp::index(s.nefc,w);row++){float x=0.0f;for(int i=0;i<MR_NV;i++)x+=mr_J(s,w,row,i)*wp::index(s.qacc,w,i);wp::index(s.ctx_Jaref,w,row)=x-wp::index(s.efc_aref,w,row);}\n" +
  "wp::index(s.ctx_grad_dot,w)=0.0f;wp::index(s.ctx_newton_decrement,w)=0.0f;wp::index(s.ctx_search_dot,w)=0.0f;wp::index(s.ctx_alpha,w)=0.0f;wp::index(s.ctx_improvement,w)=0.0f;wp::index(s.ls_overflow,w)=0;\n"
}

///|
fn gradient_body(r : Request) -> String {
  let cone = if r.cone == "elliptic" {
    "for(int row=wp::index(s.ne,w)+wp::index(s.nf,w);row<count;row++)if(wp::index(s.efc_type,w,row)==7){int con=wp::index(s.efc_id,w,row);if(row==wp::index(s.contact_efc_address,con,0))h+=mr_cone_hessian(s,w,con,i,j);}\n"
  } else {
    ""
  }
  let common = "int count=wp::index(s.nefc,w);float cost=0.0f;for(int row=0;row<count;row++){MRPoint f=mr_constraint_row(s,w,row);if(!mr_finite(f.c)||!mr_finite(f.h)){mr_fail(s,w,2);break;}wp::index(s.efc_force,w,row)=f.c;wp::index(s.efc_state,w,row)=int(f.g);cost+=f.h;}\nif(wp::index(s.status,w))continue;\n" +
    "float norm=0.0f;for(int i=0;i<MR_NV;i++){float force=0.0f;for(int row=0;row<count;row++)force+=mr_J(s,w,row,i)*wp::index(s.efc_force,w,row);wp::index(s.qfrc_constraint,w,i)=force;float g=wp::index(s.ctx_Ma,w,i)-wp::index(s.qfrc_smooth,w,i)-force;wp::index(s.ctx_grad,w,i)=g;norm+=g*g;cost+=0.5f*wp::index(s.qacc,w,i)*wp::index(s.ctx_Ma,w,i)-wp::index(s.qacc,w,i)*wp::index(s.qfrc_smooth,w,i);}\n" +
    "wp::index(s.ctx_grad_dot,w)=norm;wp::index(s.objective_cost,w)=cost;if(!mr_finite(norm)||!mr_finite(cost)){mr_fail(s,w,2);continue;}\n"
  common +
  (if r.solver == "cg" {
    ""
  } else {
    "for(int i=0;i<MR_NV;i++)for(int j=i;j<MR_NV;j++){float h=wp::index(s.mass_dense,w,i,j);for(int row=0;row<count;row++)if(wp::index(s.efc_state,w,row)==1)h+=mr_J(s,w,row,i)*wp::index(s.efc_D,w,row)*mr_J(s,w,row,j);\n" +
    cone +
    "if(!mr_finite(h)){mr_fail(s,w,2);break;}wp::index(s.hessian,w,i,j)=h;wp::index(s.hessian,w,j,i)=h;}\n"
  })
}

///|
fn factor_body(r : Request) -> String {
  let matrix = if r.solver == "newton" {
    "s.hessian"
  } else {
    "s.preconditioner_dense"
  }
  let newton = if r.solver == "newton" {
    "float norm=0.0f,dec=0.0f;for(int i=0;i<MR_NV;i++){float x=wp::index(s.ctx_Mgrad,w,i);wp::index(s.ctx_search,w,i)=-x;norm+=x*x;dec+=wp::index(s.ctx_grad,w,i)*x;}wp::index(s.ctx_search_dot,w)=norm;wp::index(s.ctx_newton_decrement,w)=dec;if(!mr_finite(norm)||!mr_finite(dec))mr_fail(s,w,2);\n"
  } else {
    ""
  }
  "for(int i=0;i<MR_NV;i++){for(int j=0;j<=i;j++){float a=wp::index(" +
  matrix +
  ",w,i,j);for(int k=0;k<j;k++)a-=wp::index(s.factor,w,i,k)*wp::index(s.factor,w,j,k);if(i==j){if(!mr_finite(a)||a<=0.0f){mr_fail(s,w,4);break;}wp::index(s.factor,w,i,j)=wp::sqrt(a);}else{float v=a/wp::index(s.factor,w,j,j);if(!mr_finite(v)){mr_fail(s,w,4);break;}wp::index(s.factor,w,i,j)=v;}}if(wp::index(s.status,w))break;}\nif(wp::index(s.status,w))continue;\n" +
  "for(int i=0;i<MR_NV;i++){float x=wp::index(s.ctx_grad,w,i);for(int j=0;j<i;j++)x-=wp::index(s.factor,w,i,j)*wp::index(s.ctx_Mgrad,w,j);wp::index(s.ctx_Mgrad,w,i)=x/wp::index(s.factor,w,i,i);}\n" +
  "for(int i=MR_NV-1;i>=0;i--){float x=wp::index(s.ctx_Mgrad,w,i);for(int j=i+1;j<MR_NV;j++)x-=wp::index(s.factor,w,j,i)*wp::index(s.ctx_Mgrad,w,j);x/=wp::index(s.factor,w,i,i);if(!mr_finite(x)){mr_fail(s,w,4);break;}wp::index(s.ctx_Mgrad,w,i)=x;}\nif(wp::index(s.status,w))continue;\n" +
  newton
}

///|
fn cg_init_body() -> String {
  (
    #|float norm=0.0f,dot=0.0f;for(int i=0;i<MR_NV;i++){float g=wp::index(s.ctx_grad,w,i),m=wp::index(s.ctx_Mgrad,w,i),v=-m;wp::index(s.ctx_search,w,i)=v;norm+=v*v;dot+=g*m;wp::index(s.ctx_prev_grad,w,i)=g;wp::index(s.ctx_prev_Mgrad,w,i)=m;}
    #|wp::index(s.ctx_search_dot,w)=norm;float inertia=wp::index(s.stat_meaninertia,w%s.stat_meaninertia.shape[0]),tol=wp::index(s.opt_tolerance,w%s.opt_tolerance.shape[0]);
    #|if(!mr_finite(norm)||!mr_finite(dot)){mr_fail(s,w,2);continue;}
    #|float scale=1.0f/(inertia*float(wp::max(1,MR_NV)));if(!wp::index(s.ctx_done,w)&&wp::max(0.0f,0.5f*scale*dot)<tol){wp::index(s.ctx_done,w)=true;wp::atomic_add(s.nsolving,0,-1);}
  )
}

///|
/// Actual typed source generation; no compiler, CUDA or algorithms execute.
pub fn lower(r : Request) -> Lowered raise {
  validate(r)
  let entries : Array[Entry] = []
  let seen : Map[String, Unit] = {}
  let policy : LaunchPolicy = {
    block_dim: 256,
    forward_smem: 0,
    backward_smem: 0,
    grid_stride: true,
    coord_mult: 1,
  }
  let general = r.njmax > 0 && r.nv > 0
  let blocks = [
    "// Copyright 2026 The Newton Developers\n// SPDX-License-Identifier: Apache-2.0\n// Full-rebuild scalar-reference GPU port of MuJoCo-Warp 3.15 Newton/CG equations.\n#define WP_NO_CRT\n#include \"builtin.h\"\nusing mr_vec5f=wp::vec_t<5,float>;\nstatic_assert(sizeof(wp::array_t<float>)==56 && sizeof(bool)==1,\"Warp 1.17 ABI\");\nconstexpr int MR_NV=\{r.nv};\nconstexpr int MR_LS_ITERATIONS=\{r.ls_iterations};\n",
  ]
  if general {
    let all = parameters(r, "initialize-state")
    blocks.push(
      "struct MRState{" +
      all.map(p => p.c_type + " " + p.name + ";").join("\n") +
      "};\n",
    )
    blocks.append([equation_source(), model_source(r), constraint_source()])
    blocks.push(
      "static __device__ void mr_fail(const MRState& s,int w,int bit){wp::index(s.status,w)=wp::index(s.status,w)|bit;wp::index(s.ctx_alpha,w)=0.0f;}\n",
    )
    blocks.push(line_helper_source(r))
  }
  for key in r.kernels {
    guard !seen.contains(key) else { fail("duplicate Newton solver kernel") }
    seen[key] = ()
    let ps = parameters(r, key)
    let name = "mr_mjw_newton_" + key.replace_all(old="-", new="_")
    let selected : Entry = {
      key,
      forward: name,
      launch_shape: [r.nworld],
      parameters: ps,
    }
    entries.push(selected)
    let signature = ps.map(p => p.c_type + " " + p.name).join(",")
    let body = if key == "unconstrained" {
      "if(wp::index(status,w))continue;for(int i=0;i<MR_NV;i++){float x=wp::index(qacc_smooth,w,i);if(!wp::isfinite(x)){wp::index(status,w)|=2;break;}wp::index(qacc,w,i)=x;wp::index(qfrc_constraint,w,i)=0.0f;}wp::index(solver_niter,w)=0;"
    } else if key == "initialize-controls" {
      "wp::index(ctx_done,w)=false;wp::index(solver_niter,w)=0;wp::index(ctx_search_dot,w)=0.0f;if(w==0)wp::index(nsolving,0)=\{r.nworld};"
    } else {
      "MRState s{" +
      ps.map(p => p.name).join(",") +
      "};if(wp::index(s.status,w)||wp::index(s.ctx_done,w))continue;if(!mr_validate(s,w)){mr_fail(s,w,1);continue;}\n" +
      (match key {
        "initialize-state" => initialize_body(r)
        "constraint-gradient-hessian" => gradient_body(r)
        "factor-direction" => factor_body(r)
        "line-search" => line_body(r)
        "line-search-incremental" => line_body(r, incremental=true)
        "cg-search-init" => cg_init_body()
        _ => fail("unsupported Newton body")
      })
    }
    blocks.push(
      "extern \"C\" __global__ void " +
      name +
      "(wp::launch_bounds_t<1> dim," +
      signature +
      "){for(size_t linear=size_t(blockIdx.x)*blockDim.x+threadIdx.x;linear<dim.size;linear+=size_t(blockDim.x)*gridDim.x){int w=int(linear);" +
      body +
      "}}\n",
    )
  }
  let source = blocks.join("\n")
  let sha = @artifacts.sha256(@utf8.encode(source))
  let identity : Json = {
    "format": "moonrobo-newton-solver-specialization-v1",
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
