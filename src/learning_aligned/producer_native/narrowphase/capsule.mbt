///|
/// Direct lowering of MuJoCo-Warp 3.15 capsule_capsule and its two-slot wrapper.
fn capsule_geometry() -> String {
  (
    #|static __device__ void mr_capsule_store(mr_contact* out,int slot,mr_contact c){c.id=slot;out[slot]=c;}
    #|static __device__ void mr_capsules(wp::vec3f p1,wp::vec3f n1,float r1,float h1,wp::vec3f p2,wp::vec3f n2,float r2,float h2,float margin,mr_contact* out){
    #| for(int i=0;i<2;i++){out[i].dist=INFINITY;out[i].pos=wp::vec3f(0.0f);out[i].frame=wp::mat33f();out[i].id=i;}
    #| wp::vec3f a=wp::mul(n1,h1),b=wp::mul(n2,h2),dif=wp::sub(p1,p2);
    #| float ma=wp::dot(a,a),mb=-wp::dot(a,b),mc=wp::dot(b,b),u=-wp::dot(a,dif),v=wp::dot(b,dif),det=ma*mc-mb*mb;
    #| if(wp::abs(det)>=1.0e-15f){
    #|   float inv=1.0f/det,x1=(mc*u-mb*v)*inv,x2=(ma*v-mb*u)*inv;
    #|   if(x1>1.0f){x1=1.0f;x2=(v-mb)/mc;}else if(x1< -1.0f){x1=-1.0f;x2=(v+mb)/mc;}
    #|   if(x2>1.0f){x2=1.0f;x1=wp::clamp((u-mb)/ma,-1.0f,1.0f);}else if(x2< -1.0f){x2=-1.0f;x1=wp::clamp((u+mb)/ma,-1.0f,1.0f);}
    #|   mr_contact c=mr_spheres(wp::add(p1,wp::mul(a,x1)),r1,wp::add(p2,wp::mul(b,x2)),r2);
    #|   if(c.dist<=margin)mr_capsule_store(out,0,c);
    #| }else{
    #|   int count=0;float x2=wp::clamp((v-mb)/mc,-1.0f,1.0f);
    #|   mr_contact c=mr_spheres(wp::add(p1,a),r1,wp::add(p2,wp::mul(b,x2)),r2);
    #|   if(c.dist<=margin){mr_capsule_store(out,count,c);count++;}
    #|   x2=wp::clamp((v+mb)/mc,-1.0f,1.0f);c=mr_spheres(wp::sub(p1,a),r1,wp::add(p2,wp::mul(b,x2)),r2);
    #|   if(c.dist<=margin){mr_capsule_store(out,count,c);count++;}
    #|   if(count<2){float x1=wp::clamp((u-mb)/ma,-1.0f,1.0f);c=mr_spheres(wp::add(p1,wp::mul(a,x1)),r1,wp::add(p2,b),r2);if(c.dist<=margin){mr_capsule_store(out,count,c);count++;}}
    #|   if(count<2){float x1=wp::clamp((u+mb)/ma,-1.0f,1.0f);c=mr_spheres(wp::add(p1,wp::mul(a,x1)),r1,wp::sub(p2,b),r2);if(c.dist<=margin)mr_capsule_store(out,count,c);}
    #| }
    #|}
  )
}
