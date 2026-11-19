///|
/// Objective ray evaluation is shared by initial, Newton and bracket points.
/// Elliptic cones retain rationalized shifted cost from the pinned source.
fn line_helper_source(_r : Request) -> String {
  (
    #|static __device__ MRPoint mr_ray_row(const MRState& s,int w,int row,float alpha,bool zero){
    #| int ne=wp::index(s.ne,w),nf=wp::index(s.nf,w);float x=wp::index(s.ctx_Jaref,w,row),v=wp::index(s.ctx_jv,w,row),D=wp::index(s.efc_D,w,row);
    #| if(row<ne){if(zero)return {0.5f*D*x*x,(v*D)*x,v*(v*D)};return mr_direct(x,v,D,alpha,0.0f);}
    #| if(row<ne+nf){float f=wp::index(s.efc_frictionloss,w,row),rf=mr_div(f,D);MRPoint p=mr_friction(x+alpha*v,f,rf,v,D);if(!zero)p.c-=mr_friction(x,f,rf,v,D).c;return p;}
    #| if(wp::index(s.efc_type,w,row)==7){int con=wp::index(s.efc_id,w,row);if(row!=wp::index(s.contact_efc_address,con,0))return {0.0f,0.0f,0.0f};MREllipse e=mr_load_ellipse(s,w,con);return zero?mr_ellipse_zero(e):mr_ellipse_shift(e,alpha);}
    #| float q0=0.5f*D*x*x,c0=x<0.0f?q0:0.0f;
    #| if(zero){if(x<0.0f)return {q0,(v*D)*x,v*(v*D)};return {0.0f,0.0f,0.0f};}
    #| if(x+alpha*v<0.0f)return mr_direct(x,v,D,alpha,q0-c0);return {-c0,0.0f,0.0f};
    #|}
    #|static __device__ MRPoint mr_ray(const MRState& s,int w,float q1,float q2,float alpha){
    #| MRPoint p=mr_quad(0.0f,q1,q2,alpha);for(int row=wp::index(s.ne,w);row<wp::index(s.nefc,w);row++)p=mr_add(p,mr_ray_row(s,w,row,alpha,false));return p;
    #|}
    #|static __device__ bool mr_valid_point(MRPoint p){return mr_finite(p.c)&&mr_finite(p.g)&&mr_finite(p.h);}
  )
}

///|
fn line_body(r : Request, incremental~ : Bool = false) -> String {
  let text =
    #|int count=wp::index(s.nefc,w),ne=wp::index(s.ne,w);
    #|for(int i=0;i<MR_NV;i++){float mv=0.0f;for(int j=0;j<MR_NV;j++)mv+=wp::index(s.mass_dense,w,i,j)*wp::index(s.ctx_search,w,j);wp::index(s.ctx_mv,w,i)=mv;}
    #|for(int row=0;row<count;row++){float jv=0.0f;for(int i=0;i<MR_NV;i++)jv+=mr_J(s,w,row,i)*wp::index(s.ctx_search,w,i);wp::index(s.ctx_jv,w,row)=jv;}
    #|float q1=0.0f,q2=0.0f;for(int i=0;i<MR_NV;i++){float v=wp::index(s.ctx_search,w,i);q1+=v*(wp::index(s.ctx_Ma,w,i)-wp::index(s.qfrc_smooth,w,i));q2+=0.5f*v*wp::index(s.ctx_mv,w,i);}
    #|for(int row=0;row<ne;row++){float v=wp::index(s.ctx_jv,w,row),vd=v*wp::index(s.efc_D,w,row);q1+=vd*wp::index(s.ctx_Jaref,w,row);q2+=0.5f*v*vd;}
    #|MRPoint rows{0.0f,0.0f,0.0f};for(int row=ne;row<count;row++)rows=mr_add(rows,mr_ray_row(s,w,row,0.0f,true));
    #|MRPoint p0{0.0f,q1+rows.g,2.0f*q2+rows.h};float gross=wp::sqrt(2.0f*wp::max(rows.c,0.0f)*wp::max(rows.h,0.0f))+wp::abs(q1);
    #|float tolerance=wp::index(s.opt_tolerance,w%s.opt_tolerance.shape[0]),lst=wp::index(s.opt_ls_tolerance,w%s.opt_ls_tolerance.shape[0]),inertia=wp::index(s.stat_meaninertia,w%s.stat_meaninertia.shape[0]);
    #|float gtol=wp::max(tolerance*lst*wp::sqrt(wp::index(s.ctx_search_dot,w))*(inertia*float(MR_NV)),1.0e-6f),accept=wp::max(gtol,(8.0f*1.1920929e-07f)*gross);
    #|float initial_alpha=-mr_div(p0.g,p0.h);MRPoint initial=mr_ray(s,w,q1,q2,initial_alpha);if(!mr_valid_point(p0)||!mr_valid_point(initial)||!mr_finite(accept)){mr_fail(s,w,2);continue;}
    #|bool converged=wp::abs(initial.g)<accept&&initial.c<0.0f;float alpha=converged?initial_alpha:0.0f,improvement=converged?-initial.c:0.0f;
    #|if(!converged){bool less=initial.g<p0.g;MRPoint anchor{0.0f,p0.g,p0.h},lo=less?initial:anchor,hi=less?anchor:initial;float la=less?initial_alpha:0.0f,ha=less?0.0f:initial_alpha;
    #|for(int iteration=0;iteration<MR_LS_ITERATIONS;iteration++){
    #| float lna=la-mr_div(lo.g,lo.h),hna=ha-mr_div(hi.g,hi.h),ma=0.5f*(la+ha);MRPoint ln=mr_ray(s,w,q1,q2,lna),hn=mr_ray(s,w,q1,q2,hna),mid=mr_ray(s,w,q1,q2,ma);
    #| if(!mr_valid_point(ln)||!mr_valid_point(hn)||!mr_valid_point(mid)){mr_fail(s,w,2);break;}
    #| bool cl=wp::abs(ln.g)<accept&&ln.c<0.0f,ch=wp::abs(hn.g)<accept&&hn.c<0.0f,cm=wp::abs(mid.g)<accept&&mid.c<0.0f,found=cl||ch||cm,sl=false,sh=false;
    #| if(found){MRPoint best{1.0e10f,0.0f,0.0f};float ba=0.0f;if(cl&&ln.c<best.c){best=ln;ba=lna;}if(ch&&hn.c<best.c){best=hn;ba=hna;}if(cm&&mid.c<best.c){best=mid;ba=ma;}lo=best;hi=best;la=ba;ha=ba;}
    #| else {
    #| if(mr_bracket(lo,ln)){lo=ln;la=lna;sl=true;}if(mr_bracket(lo,mid)){lo=mid;la=ma;sl=true;}if(mr_bracket(lo,hn)){lo=hn;la=hna;sl=true;}
    #| if(mr_bracket(hi,hn)||(hi.g<0.0f&&hn.g>0.0f)){hi=hn;ha=hna;sh=true;}if(mr_bracket(hi,mid)){hi=mid;ha=ma;sh=true;}if(mr_bracket(hi,ln)){hi=ln;ha=lna;sh=true;}}
    #| bool done=found||(!sl&&!sh)||(lo.c<0.0f&&lo.g<0.0f&&lo.g>-gtol)||(hi.c<0.0f&&hi.g>0.0f&&hi.g<gtol);
    #| if(lo.c<0.0f||hi.c<0.0f){bool better=lo.c<hi.c;alpha=better?la:ha;improvement=-(better?lo.c:hi.c);}
    #| if(done){converged=true;break;}
    #|}}
    #|if(wp::index(s.status,w))continue;
    #|if(!mr_finite(alpha)||!mr_finite(improvement)){mr_fail(s,w,2);continue;}
    #|for(int i=0;i<MR_NV;i++){float a=wp::index(s.qacc,w,i)+alpha*wp::index(s.ctx_search,w,i),m=wp::index(s.ctx_Ma,w,i)+alpha*wp::index(s.ctx_mv,w,i);if(!mr_finite(a)||!mr_finite(m)){mr_fail(s,w,2);break;}wp::index(s.qacc,w,i)=a;wp::index(s.ctx_Ma,w,i)=m;}
    #|if(wp::index(s.status,w))continue;for(int row=0;row<count;row++){float x=wp::index(s.ctx_Jaref,w,row)+alpha*wp::index(s.ctx_jv,w,row);if(!mr_finite(x)){mr_fail(s,w,2);break;}wp::index(s.ctx_Jaref,w,row)=x;}
    #|if(wp::index(s.status,w))continue;wp::index(s.ctx_alpha,w)=alpha;wp::index(s.ctx_improvement,w)=improvement;if(!converged)wp::index(s.ls_overflow,w)|=1024;
  text +
  (if incremental {
    "float noise_floor=(8.0f*1.1920929e-07f)*wp::max(1.0f,mr_div(gross,p0.h));wp::index(s.ctx_ls_exhausted,w)=wp::abs(alpha)<noise_floor;\n"
  } else {
    ""
  })
}
