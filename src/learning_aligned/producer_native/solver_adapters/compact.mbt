///|
fn compact_body(key : String) -> String raise {
  match key {
    "compact-inertia-init" =>
      "int n=wp::index(s.ncdof,w);if(n<0||n>AC){afail(s,w,1);continue;}for(int i=0;i<AC;i++)for(int j=0;j<AC;j++)wp::index(s.M_c,w,i,j)=(i==j&&i>=n)?1.0f:0.0f;"
    "compact-mass-gather" =>
      "if(!amaps(s,w)||!amass(s,w)){afail(s,w,1);continue;}for(int i=0;i<AN;i++){int ci=wp::index(s.dof_cdof,w,i);if(ci<0)continue;int start=wp::index(s.M_rowadr,i),count=wp::index(s.M_rownnz,i);for(int k=start;k<start+count;k++){int cj=wp::index(s.dof_cdof,w,wp::index(s.M_colind,k));if(cj>=0){float value=wp::index(s.M,w,k);if(!wp::isfinite(value)){afail(s,w,2);break;}wp::index(s.M_c,w,ci,cj)=value;wp::index(s.M_c,w,cj,ci)=value;}}}"
    "compact-rhs-gather" =>
      "if(!amaps(s,w)){afail(s,w,1);continue;}for(int c=0;c<AC;c++){int d=wp::index(s.cdof_dof,w,c);wp::index(s.rhs_c,w,c,0)=d>=0?wp::index(s.vec_full,w,d):0.0f;}"
    "compact-solution-scatter" =>
      "if(!amaps(s,w)){afail(s,w,1);continue;}for(int d=0;d<AN;d++){int c=wp::index(s.dof_cdof,w,d);wp::index(s.vec_out,w,d)=c>=0?wp::index(s.solution_c,w,c,0):0.0f;}"
    "compact-vectors-gather" =>
      "if(!amaps(s,w)){afail(s,w,1);continue;}for(int c=0;c<AC;c++){int d=wp::index(s.cdof_dof,w,c);wp::index(s.qacc_warmstart_c,w,c)=d>=0?wp::index(s.qacc_warmstart_full,w,d):0.0f;wp::index(s.qfrc_smooth_c,w,c)=d>=0?wp::index(s.qfrc_smooth_full,w,d):0.0f;wp::index(s.qacc_smooth_c,w,c)=d>=0?wp::index(s.qacc_smooth_full,w,d):0.0f;}"
    "compact-vectors-scatter" =>
      "if(!amaps(s,w)){afail(s,w,1);continue;}for(int d=0;d<AN;d++){int c=wp::index(s.dof_cdof,w,d);wp::index(s.qacc_full,w,d)=c>=0?wp::index(s.qacc_c,w,c):0.0f;wp::index(s.qfrc_constraint_full,w,d)=c>=0?wp::index(s.qfrc_constraint_c,w,c):0.0f;}"
    "compact-jacobian-gather" =>
      "if(!amaps(s,w)||!ajvalid(s,w)){afail(s,w,1);continue;}for(int e=0;e<AR;e++)for(int c=0;c<AC;c++)wp::index(s.J_c,w,e,c)=0.0f;for(int e=0;e<wp::index(s.nefc,w);e++)for(int d=0;d<AN;d++){int c=wp::index(s.dof_cdof,w,d);if(c>=0)wp::index(s.J_c,w,e,c)=ajfull(s,w,e,d);}"
    "compact-mass-multiply" =>
      "if(wp::index(s.skip,w))continue;if(!amaps(s,w)||!agather(s)){afail(s,w,1);continue;}for(int ci=0;ci<AC;ci++){int d=wp::index(s.cdof_dof,w,ci);float sum=0.0f;if(d>=0){int begin=wp::index(s.M_mulm_rowadr,d),end=wp::index(s.M_mulm_rowadr,d+1);for(int k=begin;k<end;k++){int cj=wp::index(s.dof_cdof,w,wp::index(s.M_mulm_col,k));if(cj>=0)sum+=wp::index(s.M,w,wp::index(s.M_mulm_madr,k))*wp::index(s.vec_c,w,cj);}}if(!wp::isfinite(sum)){afail(s,w,2);break;}wp::index(s.res_c,w,ci)=sum;}"
    "full-mass-multiply" =>
      "if(!agather(s)){afail(s,w,1);continue;}for(int d=0;d<AN;d++){float sum=0.0f;for(int k=wp::index(s.M_mulm_rowadr,d);k<wp::index(s.M_mulm_rowadr,d+1);k++)sum+=wp::index(s.M,w,wp::index(s.M_mulm_madr,k))*wp::index(s.vec_full,w,wp::index(s.M_mulm_col,k));if(!wp::isfinite(sum)){afail(s,w,2);break;}wp::index(s.res_full,w,d)=sum;}"
    _ => fail("unknown compact adapter body")
  }
}
