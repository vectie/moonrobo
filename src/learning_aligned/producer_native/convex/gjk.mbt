///|
fn gjk_source() -> String {
  (
    #|struct mr_gjk_result {bool separated,exhausted,invalid;float dist;wp::vec3f x1,x2;int dim,index1,index2,iterations;};
    #|static __device__ mr_gjk_result mr_gjk(float tol,int maxiter,mr_geom g1,mr_geom g2,wp::vec3f x10,wp::vec3f x20,float cutoff,bool discrete){
    #| wp::vec3f s[4],s1[4],s2[4];for(int i=0;i<4;i++){s[i]=wp::vec3f(0.0f);s1[i]=wp::vec3f(0.0f);s2[i]=wp::vec3f(0.0f);}
    #| int n=0;wp::vec4f lambda(1.0f,0.0f,0.0f,0.0f);float epsilon=discrete?0.0f:0.5f*tol*tol,minnorm=discrete?1.0e-15f:tol;
    #| wp::vec3f x=wp::sub(x10,x20);float norm=wp::sqrt(wp::dot(x,x)),prev=0.0f;bool stopped=false,invalid=false;
    #| mr_gjk_result result;result.separated=false;result.exhausted=false;result.invalid=false;result.dim=0;result.dist=1.0e30f;result.x1=wp::vec3f(0.0f);result.x2=wp::vec3f(0.0f);result.iterations=0;result.index1=g1.index;result.index2=g2.index;
    #| for(int iteration=0;iteration<maxiter;iteration++){
    #|   result.iterations=iteration+1;
    #|   if(!mr_finite(norm)||!mr_finite3(x)){invalid=true;stopped=true;break;}
    #|   if(norm<minnorm||wp::abs(prev-norm)<1.0e-15f){stopped=true;break;}
    #|   wp::vec3f dir=wp::div(x,norm);
    #|   if(discrete&&norm<1.0e-4f){
    #|     if(n==2){wp::vec3f edge=wp::sub(s[1],s[0]);float norm2=wp::dot(edge,edge);if(norm2>1.0e-30f){float proj=wp::dot(dir,edge)/norm2;dir=wp::sub(dir,wp::mul(edge,proj));float dn=wp::length(dir);if(dn>1.0e-15f)dir=wp::div(dir,dn);}}
    #|     else if(n==3){wp::vec3f e1=wp::sub(s[1],s[0]),e2=wp::sub(s[2],s[0]),normal=wp::cross(e1,e2);float nn=wp::length(normal);if(nn>1.0e-15f)dir=wp::div(wp::mul(normal,wp::sign(wp::dot(dir,normal))),nn);}
    #|   }
    #|   if(n<0||n>=4){invalid=true;stopped=true;break;}
    #|   mr_support p1=mr_support_point(g1,wp::neg(dir)),p2=mr_support_point(g2,dir);s1[n]=p1.point;g1.index=p1.cached_index;s2[n]=p2.point;g2.index=p2.cached_index;s[n]=wp::sub(s1[n],s2[n]);
    #|   if(!mr_finite3(s[n])||(g1.type==7&&g1.index<g1.vertadr)||(g2.type==7&&g2.index<g2.vertadr)){invalid=true;stopped=true;break;}
    #|   float dual=wp::dot(x,wp::sub(x,s[n]));if(!mr_finite(dual)){invalid=true;stopped=true;break;}if(dual<epsilon){stopped=true;break;}
    #|   float lower=wp::dot(x,s[n]);
    #|   if(!mr_finite(lower)){invalid=true;stopped=true;break;}
    #|   if((cutoff==0.0f&&lower>0.0f)||(cutoff!=0.0f&&cutoff<1.0e30f&&lower>0.0f&&lower>=cutoff*norm)){
    #|     result.separated=true;result.index1=g1.index;result.index2=g2.index;return result;
    #|   }
    #|   lambda=mr_subdistance(n+1,s);for(int i=0;i<4;i++)if(!mr_finite(lambda[i]))invalid=true;
    #|   if(invalid){stopped=true;break;}
    #|   n=0;for(int i=0;i<4;i++){if(lambda[i]==0.0f)continue;s[n]=s[i];s1[n]=s1[i];s2[n]=s2[i];lambda[n]=lambda[i];n++;}
    #|   if(n<1){invalid=true;stopped=true;break;}
    #|   x=mr_combine(n,lambda,s);prev=norm;norm=wp::sqrt(wp::dot(x,x));
    #|   if(n==4){stopped=true;break;}
    #| }
    #| result.exhausted=!stopped;result.invalid=invalid;result.x1=n==0?x10:mr_combine(n,lambda,s1);result.x2=n==0?x20:mr_combine(n,lambda,s2);
    #| if(norm>0.0f&&mr_finite(norm)){wp::vec3f dir=wp::div(x,norm);mr_support p1=mr_support_point(g1,wp::neg(dir)),p2=mr_support_point(g2,dir);float lower=wp::dot(x,wp::sub(p1.point,p2.point));if(!mr_finite3(p1.point)||!mr_finite3(p2.point)||!mr_finite(lower)||(g1.type==7&&p1.cached_index<g1.vertadr)||(g2.type==7&&p2.cached_index<g2.vertadr))result.invalid=true;result.separated=lower>0.0f;}
    #| result.dist=(n==4&&!result.separated)?0.0f:norm;result.dim=n;result.index1=g1.index;result.index2=g2.index;
    #| if(!mr_finite(result.dist)||!mr_finite3(result.x1)||!mr_finite3(result.x2))result.invalid=true;return result;
    #|}
    #|struct mr_phase_result {mr_gjk_result gjk;int status;float dist;wp::vec3f x1,x2;};
    #|static __device__ mr_phase_result mr_phase(float tol,float cutoff,int maxiter,mr_geom g1,mr_geom g2){
    #| mr_phase_result out;out.status=1;float size1=0.0f,size2=0.0f,margin1=0.0f,margin2=0.0f;mr_geom original1=g1,original2=g2;float phase_cutoff=cutoff;
    #| bool discrete=(g1.type==6||g1.type==7)&&(g2.type==6||g2.type==7)&&g1.margin==0.0f&&g2.margin==0.0f;
    #| if(g1.type==2||g1.type==3){size1=g1.size[0];margin1=size1+0.5f*g1.margin;g1.margin=0.0f;g1.size[0]=0.0f;}
    #| if(g2.type==2||g2.type==3){size2=g2.size[0];margin2=size2+0.5f*g2.margin;g2.margin=0.0f;g2.size[0]=0.0f;}
    #| if(size1+size2>0.0f){
    #|   phase_cutoff+=margin1+margin2;out.gjk=mr_gjk(tol,maxiter,g1,g2,g1.pos,g2.pos,phase_cutoff,discrete);g1.index=out.gjk.index1;g2.index=out.gjk.index2;
    #|   out.dist=out.gjk.dist;out.x1=out.gjk.x1;out.x2=out.gjk.x2;
    #|   if(out.gjk.invalid){out.status=13;return out;}if(out.gjk.exhausted){out.status=11;return out;}
    #|   if(out.dist>tol){
    #|     if(out.dist==1.0e30f){out.status=2;return out;}
    #|     wp::vec3f normal=wp::normalize(wp::sub(out.x2,out.x1));if(margin1>0.0f)out.x1=wp::add(out.x1,wp::mul(normal,margin1));if(margin2>0.0f)out.x2=wp::sub(out.x2,wp::mul(normal,margin2));out.dist-=margin1+margin2;out.status=3;
    #|     if(!mr_finite(out.dist)||!mr_finite3(out.x1)||!mr_finite3(out.x2))out.status=13;return out;
    #|   }
    #|   // Deep case restores only source margin/size while retaining support caches.
    #|   g1.margin=original1.margin;g1.size=original1.size;g2.margin=original2.margin;g2.size=original2.size;phase_cutoff-=margin1+margin2;
    #| }
    #| out.gjk=mr_gjk(tol,maxiter,g1,g2,g1.pos,g2.pos,phase_cutoff,discrete);out.dist=out.gjk.dist;out.x1=out.gjk.x1;out.x2=out.gjk.x2;
    #| if(out.gjk.invalid){out.status=13;return out;}if(out.gjk.exhausted){out.status=11;return out;}
    #| if(out.dist==1.0e30f){out.status=2;return out;}
    #| if(out.dist>tol||out.gjk.separated){out.status=1;return out;}
    #| // Upstream can return a dim<2 boundary witness; without a stable normal or
    #| // EPA closure this stage rejects it conservatively, never inventing depth.
    #| out.status=out.gjk.dim<2?13:10;return out;
    #|}
  )
}
