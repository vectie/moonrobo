///|
/// Real scalar full/compact incremental transitions. Reduction association
/// differs from upstream's atomics/tiles; the state/curvature equations remain.
fn incremental_body(r : Request, key : String) -> String raise {
  let maps = if r.compact {
    "if(!amaps(s,w)){afail(s,w,1);continue;}"
  } else {
    ""
  }
  match key {
    "incremental-initialize" =>
      "wp::index(s.ctx_grad_scale,w)=1.0f;wp::index(s.ctx_search_unchanged,w)=false;wp::index(s.ctx_ls_exhausted,w)=false;wp::index(s.quad_changed_count,w)=0;wp::index(s.state_changed_count,w)=0;"
    "incremental-zero-changes" =>
      "wp::index(s.quad_changed_count,w)=0;wp::index(s.state_changed_count,w)=0;"
    "incremental-constraint-update" =>
      "if(wp::index(s.ctx_done,w))continue;int count=wp::index(s.nefc,w),ne=wp::index(s.ne,w),nf=wp::index(s.nf,w),qc=wp::index(s.quad_changed_count,w),sc=wp::index(s.state_changed_count,w);if(count<0||count>AR||ne<0||ne>count||nf<0||nf>count-ne||qc<0||qc>AR||sc<0||sc>AR+1){afail(s,w,1);continue;}if(AR>0&&wp::index(s.ctx_ls_exhausted,w))sc++;\n" +
      "for(int e=0;e<count;e++){int type=wp::index(s.efc_type,w,e);float x=wp::index(s.ctx_Jaref,w,e),D=wp::index(s.D,w,e),f=wp::index(s.frictionloss,w,e);if(type<0||type>6||!wp::isfinite(x)||!wp::isfinite(D)||D<0.0f||!wp::isfinite(f)||f<0.0f){afail(s,w,1);break;}int old=wp::index(s.state,w,e),state=0;float force=0.0f;if(e<ne){force=-D*x;state=1;}else if(e<ne+nf){float rf=adiv(f,D);if(x<=-rf){force=f;state=2;}else if(x>=rf){force=-f;state=3;}else{force=-D*x;state=1;}}else if(x<0.0f){force=-D*x;state=1;}if(!wp::isfinite(force)){afail(s,w,2);break;}wp::index(s.force,w,e)=force;wp::index(s.state,w,e)=state;if((old==1)!=(state==1)){if(qc>=AR){afail(s,w,1);break;}wp::index(s.quad_changed_ids,w,qc++)=e;}if(old!=state)sc++;}\nif(sc>AR+1){afail(s,w,1);continue;}wp::index(s.quad_changed_count,w)=qc;wp::index(s.state_changed_count,w)=sc;"
    "incremental-qfrc-rebuild" =>
      "if(wp::index(s.ctx_done,w))continue;" +
      (if r.stable_fast {
        "if(wp::index(s.state_changed_count,w)==0)continue;"
      } else {
        ""
      }) +
      maps +
      "if(!ajvalid(s,w)){afail(s,w,1);continue;}for(int i=0;i<AC;i++){float sum=0.0f;for(int e=0;e<wp::index(s.nefc,w);e++)sum+=aj(s,w,e,i)*wp::index(s.force,w,e);if(!wp::isfinite(sum)){afail(s,w,2);break;}wp::index(s.qfrc_constraint,w,i)=sum;}"
    "incremental-gradient-update" => {
      let stable = if r.stable_fast {
        "wp::index(s.ctx_search_unchanged,w)=wp::index(s.ctx_done,w)||wp::index(s.state_changed_count,w)==0;if(wp::index(s.ctx_done,w))continue;if(wp::index(s.state_changed_count,w)==0){float sigma=wp::index(s.ctx_grad_scale,w),next=sigma-wp::index(s.ctx_alpha,w),ratio=sigma!=0.0f?next/sigma:0.0f,r2=ratio*ratio;wp::index(s.ctx_grad_dot,w)*=r2;wp::index(s.ctx_newton_decrement,w)*=r2;wp::index(s.ctx_grad_scale,w)=next;continue;}"
      } else {
        "wp::index(s.ctx_search_unchanged,w)=false;if(wp::index(s.ctx_done,w))continue;"
      }
      stable +
      "wp::index(s.ctx_grad_dot,w)=0.0f;wp::index(s.ctx_newton_decrement,w)=0.0f;wp::index(s.ctx_grad_scale,w)=1.0f;float sum=0.0f;for(int i=0;i<AC;i++){float g=wp::index(s.ctx_Ma,w,i)-wp::index(s.qfrc_smooth,w,i)-wp::index(s.qfrc_constraint,w,i);if(!wp::isfinite(g)){afail(s,w,2);break;}wp::index(s.ctx_grad,w,i)=g;sum+=g*g;}if(!wp::isfinite(sum)){afail(s,w,2);continue;}wp::index(s.ctx_grad_dot,w)=sum;"
    }
    "incremental-hessian-update" =>
      "if(wp::index(s.ctx_done,w))continue;" +
      maps +
      "if(!ajvalid(s,w)){afail(s,w,1);continue;}int changes=wp::index(s.quad_changed_count,w),count=wp::index(s.nefc,w);if(changes<0||changes>AR){afail(s,w,1);continue;}for(int k=0;k<changes;k++){int row=wp::index(s.quad_changed_ids,w,k);if(row<0||row>=count){afail(s,w,1);break;}}if(wp::index(s.status,w))continue;\n" +
      "for(int i=0;i<AC;i++)for(int j=i;j<AC;j++){float delta=0.0f;for(int k=0;k<changes;k++){int e=wp::index(s.quad_changed_ids,w,k);float Ji=aj(s,w,e,i),Jj=aj(s,w,e,j);if(Ji==0.0f||Jj==0.0f)continue;float d=wp::index(s.D,w,e);if(wp::index(s.state,w,e)==1)delta+=d*Ji*Jj;else delta-=d*Ji*Jj;}float h=wp::index(s.hessian,w,i,j);if(delta!=0.0f)h+=delta;if(!wp::isfinite(h)){afail(s,w,2);break;}wp::index(s.hessian,w,i,j)=h;wp::index(s.hessian,w,j,i)=h;}"
    "incremental-factor-direction" => {
      let fast = if r.stable_fast {
        "if(wp::index(s.state_changed_count,w)==0)continue;"
      } else {
        ""
      }
      "if(wp::index(s.ctx_done,w))continue;" +
      fast +
      "int changes=wp::index(s.quad_changed_count,w);if(changes<0||changes>AR){afail(s,w,1);continue;}if(changes>0){for(int i=0;i<AC;i++){for(int j=0;j<=i;j++){float a=wp::index(s.hessian,w,j,i);for(int k=0;k<j;k++)a-=wp::index(s.factor,w,i,k)*wp::index(s.factor,w,j,k);if(i==j){if(!wp::isfinite(a)||a<=0.0f){afail(s,w,4);break;}wp::index(s.factor,w,i,j)=wp::sqrt(a);}else wp::index(s.factor,w,i,j)=a/wp::index(s.factor,w,j,j);}if(wp::index(s.status,w))break;}}\nif(wp::index(s.status,w))continue;for(int i=0;i<AC;i++){float diag=wp::index(s.factor,w,i,i);if(!wp::isfinite(diag)||diag<=0.0f){afail(s,w,4);break;}float x=wp::index(s.ctx_grad,w,i);for(int j=0;j<i;j++)x-=wp::index(s.factor,w,i,j)*wp::index(s.ctx_Mgrad,w,j);wp::index(s.ctx_Mgrad,w,i)=x/diag;}if(wp::index(s.status,w))continue;\n" +
      "for(int i=AC-1;i>=0;i--){float x=wp::index(s.ctx_Mgrad,w,i);for(int j=i+1;j<AC;j++)x-=wp::index(s.factor,w,j,i)*wp::index(s.ctx_Mgrad,w,j);x/=wp::index(s.factor,w,i,i);if(!wp::isfinite(x)){afail(s,w,4);break;}wp::index(s.ctx_Mgrad,w,i)=x;}if(wp::index(s.status,w))continue;float norm=0.0f,dec=0.0f;for(int i=0;i<AC;i++){float x=wp::index(s.ctx_Mgrad,w,i);wp::index(s.ctx_search,w,i)=-x;norm+=x*x;dec+=wp::index(s.ctx_grad,w,i)*x;}if(!wp::isfinite(norm)||!wp::isfinite(dec)){afail(s,w,2);continue;}wp::index(s.ctx_search_dot,w)=norm;wp::index(s.ctx_newton_decrement,w)=dec;"
    }
    "recover-qfrc" =>
      "float scale=wp::index(s.ctx_grad_scale,w);for(int i=0;i<AC;i++){float g=scale*wp::index(s.ctx_grad,w,i),f=wp::index(s.ctx_Ma,w,i)-wp::index(s.qfrc_smooth,w,i)-g;if(!wp::isfinite(f)){afail(s,w,2);break;}wp::index(s.qfrc_constraint,w,i)=f;}"
    "pad-hessian" =>
      "if(wp::index(s.ctx_done,w))continue;for(int i=AN;i<AC;i++)wp::index(s.hessian,w,i,i)=1.0f;"
    _ => fail("unknown incremental adapter body")
  }
}
