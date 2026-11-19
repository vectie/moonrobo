///|
/// Concrete dense/CSR accessors retain actual coefficients; they do not
/// substitute identity M, zero Jacobians or fabricated constraint rows.
fn model_source(r : Request) -> String {
  let jacobian = if r.jacobian_layout == "dense" {
    "return wp::index(s.efc_J,w,row,col);"
  } else {
    "float value=0.0f;int start=wp::index(s.efc_J_rowadr,w,row),count=wp::index(s.efc_J_rownnz,w,row);\nfor(int k=start;k<start+count;k++)if(wp::index(s.efc_J_colind,w,0,k)==col)value+=wp::index(s.efc_J,w,0,k);return value;"
  }
  let mass = if r.mass_layout == "dense" {
    "return wp::index(s.M_dense_in,w,i,j);"
  } else {
    "int row=wp::max(i,j),col=wp::min(i,j);int adr=wp::index(s.M_rowadr,row),nnz=wp::index(s.M_rownnz,row);for(int k=adr;k<adr+nnz;k++)if(wp::index(s.M_colind,k)==col)return wp::index(s.M_csr,w,k);return 0.0f;"
  }
  let sparsej = if r.jacobian_layout == "csr" {
    "int adr=wp::index(s.efc_J_rowadr,w,e),nnz=wp::index(s.efc_J_rownnz,w,e);if(adr<0||nnz<0||adr>\{r.jacobian_capacity}||nnz>\{r.jacobian_capacity}-adr)return false;for(int k=adr;k<adr+nnz;k++){int c=wp::index(s.efc_J_colind,w,0,k);if(c<0||c>=\{r.nv}||!mr_finite(wp::index(s.efc_J,w,0,k)))return false;}\n"
  } else {
    "for(int c=0;c<\{r.nv};c++)if(!mr_finite(wp::index(s.efc_J,w,e,c)))return false;\n"
  }
  let sparsem = if r.mass_layout == "csr" {
    "int prefix=0;for(int i=0;i<\{r.nv};i++){int adr=wp::index(s.M_rowadr,i),nnz=wp::index(s.M_rownnz,i);if(adr!=prefix||nnz<1||nnz>\{r.mass_nnz}-prefix)return false;int prev=-1;for(int k=adr;k<adr+nnz;k++){int c=wp::index(s.M_colind,k);if(c<=prev||c>i||!mr_finite(wp::index(s.M_csr,w,k)))return false;prev=c;}if(prev!=i)return false;prefix+=nnz;}if(prefix!=\{r.mass_nnz})return false;\n"
  } else {
    "for(int i=0;i<\{r.nv};i++)for(int j=0;j<\{r.nv};j++)if(!mr_finite(wp::index(s.M_dense_in,w,i,j))||wp::index(s.M_dense_in,w,i,j)!=wp::index(s.M_dense_in,w,j,i))return false;\n"
  }
  let ellipse = if r.cone == "elliptic" {
    "if(type==7){int con=wp::index(s.efc_id,w,e);if(con<0||con>=nacon||wp::index(s.contact_worldid,con)!=w)return false;int dim=wp::index(s.contact_dim,con);if(dim!=3&&dim!=4&&dim!=6)return false;int found=0;auto f=wp::index(s.contact_friction,con);for(int axis=0;axis<5;axis++)if(!mr_finite(f[axis])||f[axis]<0.0f)return false;float mu=f[0]*wp::index(s.opt_impratio_invsqrt,w%s.opt_impratio_invsqrt.shape[0]),den=mu*mu*(1.0f+mu*mu);if(!mr_finite(mu)||mu<=0.0f||!mr_finite(den)||den<=0.0f||!mr_finite(wp::index(s.contact_dist,con))||!mr_finite(wp::index(s.contact_includemargin,con)))return false;for(int axis=0;axis<dim;axis++){int row=wp::index(s.contact_efc_address,con,axis);if(row<ne+nf||row>=count||wp::index(s.efc_type,w,row)!=7||wp::index(s.efc_id,w,row)!=con)return false;for(int p=0;p<axis;p++)if(wp::index(s.contact_efc_address,con,p)==row)return false;if(row==e)found++;}if(found!=1)return false;}\n"
  } else {
    "if(type==7)return false;\n"
  }
  let preconditioner = if r.solver == "cg" {
    "for(int i=0;i<MR_NV;i++)for(int j=0;j<MR_NV;j++)if(!mr_finite(wp::index(s.preconditioner_dense,w,i,j))||wp::index(s.preconditioner_dense,w,i,j)!=wp::index(s.preconditioner_dense,w,j,i))return false;\n"
  } else {
    ""
  }
  "static __device__ float mr_J(const MRState& s,int w,int row,int col){" +
  jacobian +
  "}\n" +
  "static __device__ float mr_mass(const MRState& s,int w,int i,int j){" +
  mass +
  "}\n" +
  "static __device__ bool mr_validate(const MRState& s,int w){\nint ne=wp::index(s.ne,w),nf=wp::index(s.nf,w),count=wp::index(s.nefc,w),nacon=wp::index(s.nacon,0);if(ne<0||nf<0||count<0||count>\{r.njmax}||ne>count||nf>count-ne||nacon<0||nacon>\{r.ncon})return false;\n" +
  sparsem +
  preconditioner +
  "for(int i=0;i<\{r.nv};i++){if(!mr_finite(wp::index(s.qfrc_smooth,w,i))||!mr_finite(wp::index(s.qacc_smooth,w,i))||!mr_finite(wp::index(s.qacc_warmstart,w,i)))return false;for(int j=0;j<\{r.nv};j++)if(!mr_finite(wp::index(s.added_metric,w,i,j))||wp::index(s.added_metric,w,i,j)!=wp::index(s.added_metric,w,j,i))return false;}\n" +
  "float tol=wp::index(s.opt_tolerance,w%s.opt_tolerance.shape[0]),lst=wp::index(s.opt_ls_tolerance,w%s.opt_ls_tolerance.shape[0]),mi=wp::index(s.stat_meaninertia,w%s.stat_meaninertia.shape[0]),imp=wp::index(s.opt_impratio_invsqrt,w%s.opt_impratio_invsqrt.shape[0]);if(!mr_finite(tol)||tol<0.0f||!mr_finite(lst)||lst<0.0f||!mr_finite(mi)||mi<=0.0f||!mr_finite(imp)||imp<=0.0f)return false;\n" +
  "for(int e=0;e<count;e++){int type=wp::index(s.efc_type,w,e);float D=wp::index(s.efc_D,w,e),fl=wp::index(s.efc_frictionloss,w,e);if(type<0||type>7||!mr_finite(D)||D<0.0f||!mr_finite(fl)||fl<0.0f||!mr_finite(wp::index(s.efc_aref,w,e)))return false;\n" +
  sparsej +
  ellipse +
  "}\nreturn true;}\n"
}
