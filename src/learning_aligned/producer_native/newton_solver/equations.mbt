///|
/// Exact scalar equations from pinned solver.py; serial reductions replace
/// tile/atomic association, not the objective or its analytic derivatives.
fn equation_source() -> String {
  (
    #|struct MRPoint {float c,g,h;};
    #|static __device__ bool mr_finite(float x){return wp::isfinite(x);}
    #|static __device__ float mr_div(float x,float y){return x/(y!=0.0f?y:1.0e-15f);}
    #|static __device__ MRPoint mr_add(MRPoint a,MRPoint b){return {a.c+b.c,a.g+b.g,a.h+b.h};}
    #|static __device__ MRPoint mr_quad(float q0,float q1,float q2,float a){float aq=a*q2;return {a*aq+a*q1+q0,2.0f*aq+q1,2.0f*q2};}
    #|static __device__ MRPoint mr_direct(float x,float v,float D,float a,float offset){float g=v*D*x,h=v*(v*D),ah=a*h;return {a*(g+0.5f*ah)+offset,g+ah,h};}
    #|static __device__ MRPoint mr_friction(float x,float f,float rf,float v,float D){if(-rf<x&&x<rf){float vd=v*D;return {0.5f*D*x*x,vd*x,v*vd};}if(x<=-rf)return {f*(-0.5f*rf-x),-f*v,0.0f};return {f*(-0.5f*rf+x),f*v,0.0f};}
    #|struct MREllipse {float mu,q0,q1,q2,u0,v0,uu,uv,vv,dm,c0,T0,r0;int state;};
    #|static __device__ MREllipse mr_ellipse_reference(MREllipse e){
    #| e.c0=0.0f;e.T0=0.0f;e.r0=0.0f;e.state=0;
    #| if(e.uu<=0.0f){if(e.u0<0.0f){e.c0=e.q0;e.state=1;}return e;}
    #| e.T0=wp::sqrt(e.uu);if(e.u0>=e.mu*e.T0)return e;
    #| if(e.mu*e.u0+e.T0<=0.0f){e.c0=e.q0;e.state=1;return e;}
    #| e.r0=e.u0-e.mu*e.T0;e.c0=0.5f*e.dm*e.r0*e.r0;e.state=4;return e;
    #|}
    #|static __device__ MRPoint mr_ellipse_zero(MREllipse e){
    #| if(e.state==1)return mr_quad(e.q0,e.q1,e.q2,0.0f);
    #| if(e.state==4){float ti=1.0f/e.T0,t1=e.uv*ti,t2=(e.vv-t1*t1)*ti,r1=e.v0-e.mu*t1;return {e.c0,e.dm*e.r0*r1,e.dm*(r1*r1-e.mu*e.r0*t2)};}
    #| return {0.0f,0.0f,0.0f};
    #|}
    #|static __device__ MRPoint mr_ellipse_quad(MREllipse e,float a,float N,float Tsqr){
    #| float aq=a*e.q2,cost=a*(aq+e.q1);
    #| if(e.state==4){float boundary=e.mu*e.u0+e.T0;cost+=0.5f*e.dm*boundary*boundary;}
    #| else if(e.state==0)cost=0.5f*e.dm*(1.0f+e.mu*e.mu)*(N*N+wp::max(Tsqr,0.0f));
    #| return {cost,2.0f*aq+e.q1,2.0f*e.q2};
    #|}
    #|static __device__ MRPoint mr_ellipse_shift(MREllipse e,float a){
    #| float N=e.u0+a*e.v0,delta=a*(2.0f*e.uv+a*e.vv),ts=e.uu+delta;
    #| if(ts<=0.0f){if(N<0.0f)return mr_ellipse_quad(e,a,N,ts);}
    #| else {float T=wp::sqrt(ts);if(N>=e.mu*T){}
    #| else if(e.mu*N+T<=0.0f)return mr_ellipse_quad(e,a,N,ts);
    #| else {float ti=1.0f/T,t1=(e.uv+a*e.vv)*ti,t2=(e.vv-t1*t1)*ti,r=N-e.mu*T,r1=e.v0-e.mu*t1,cost;
    #| if(e.state==4){float td=delta/(T+e.T0),rd=a*e.v0-e.mu*td;cost=0.5f*e.dm*rd*(2.0f*e.r0+rd);}
    #| else if(e.state==1){float aq=a*e.q2,boundary=e.mu*N+T;cost=a*(aq+e.q1)-0.5f*e.dm*boundary*boundary;}
    #| else cost=0.5f*e.dm*r*r;
    #| return {cost,e.dm*r*r1,e.dm*(r1*r1+r*(-e.mu*t2))};}}
    #| return {-e.c0,0.0f,0.0f};
    #|}
    #|static __device__ bool mr_bracket(MRPoint x,MRPoint y){return (x.g<y.g&&y.g<0.0f)||(x.g>y.g&&y.g>0.0f);}
  )
}
