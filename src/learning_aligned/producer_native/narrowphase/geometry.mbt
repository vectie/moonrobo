///|
fn geometry() -> String {
  (
    #|using mr_vec5f=wp::vec_t<5,float>;
    #|struct mr_contact { float dist;wp::vec3f pos;wp::mat33f frame;int id; };
    #|static __device__ wp::vec3f mr_axis(wp::mat33f r){return wp::vec3f(r.data[0][2],r.data[1][2],r.data[2][2]);}
    #|static __device__ wp::mat33f mr_frame(wp::vec3f a){
    #| a=wp::normalize(a);
    #| wp::vec3f b=(-0.5f<a[1]&&a[1]<0.5f)?wp::vec3f(0.0f,1.0f,0.0f):wp::vec3f(0.0f,0.0f,1.0f);
    #| b=wp::sub(b,wp::mul(a,wp::dot(a,b)));b=wp::normalize(b);
    #| if(wp::length(a)==0.0f)b=wp::vec3f(0.0f);
    #| wp::vec3f c=wp::cross(a,b);
    #| return wp::mat33f(a[0],a[1],a[2],b[0],b[1],b[2],c[0],c[1],c[2]);
    #|}
    #|static __device__ mr_contact mr_plane_sphere(wp::vec3f n,wp::vec3f plane,wp::vec3f sphere,float radius){
    #| mr_contact c;c.dist=wp::dot(wp::sub(sphere,plane),n)-radius;
    #| c.pos=wp::sub(sphere,wp::mul(n,radius+0.5f*c.dist));c.frame=mr_frame(n);c.id=0;return c;
    #|}
    #|static __device__ mr_contact mr_spheres(wp::vec3f p1,float r1,wp::vec3f p2,float r2){
    #| wp::vec3f dir=wp::sub(p2,p1);float len=wp::length(dir);
    #| wp::vec3f n=len==0.0f?wp::vec3f(1.0f,0.0f,0.0f):wp::div(dir,len);
    #| mr_contact c;c.dist=len-(r1+r2);c.pos=wp::add(p1,wp::mul(n,r1+0.5f*c.dist));c.frame=mr_frame(n);c.id=0;return c;
    #|}
    #|static __device__ mr_contact mr_sphere_capsule(wp::vec3f p1,float r1,wp::vec3f p2,wp::vec3f axis,float r2,float half){
    #| wp::vec3f segment=wp::mul(axis,half),a=wp::sub(p2,segment),b=wp::add(p2,segment),ab=wp::sub(b,a);
    #| float t=wp::dot(wp::sub(p1,a),ab)/(wp::dot(ab,ab)+1.0e-6f);
    #| wp::vec3f closest=wp::add(a,wp::mul(ab,wp::clamp(t,0.0f,1.0f)));
    #| return mr_spheres(p1,r1,closest,r2);
    #|}
    #|static __device__ wp::mat33f mr_plane_capsule_frame(wp::vec3f n,wp::vec3f axis){
    #| wp::vec3f b=wp::sub(axis,wp::mul(n,wp::dot(n,axis)));float norm=wp::length(b);
    #| if(norm!=0.0f)b=wp::div(b,norm);
    #| if(norm<0.5f)b=(-0.5f<n[1]&&n[1]<0.5f)?wp::vec3f(0.0f,1.0f,0.0f):wp::vec3f(0.0f,0.0f,1.0f);
    #| wp::vec3f c=wp::cross(n,b);
    #| return wp::mat33f(n[0],n[1],n[2],b[0],b[1],b[2],c[0],c[1],c[2]);
    #|}
    #|static __device__ mr_contact mr_sphere_box(wp::vec3f sphere,float radius,wp::vec3f box,wp::mat33f rot,wp::vec3f size){
    #| wp::vec3f center=wp::mul(wp::transpose(rot),wp::sub(sphere,box));
    #| wp::vec3f clamped=wp::max(wp::neg(size),wp::min(size,center));
    #| wp::vec3f dir=wp::sub(clamped,center);float dist=wp::length(dir);if(dist!=0.0f)dir=wp::div(dir,dist);
    #| wp::vec3f pos,normal;mr_contact c;c.id=0;
    #| if(dist<=1.0e-15f){
    #|   float closest=2.0f*(size[0]+size[1]+size[2]);int k=0;
    #|   for(int face=0;face<6;face++){float fd=wp::abs((face%2?1.0f:-1.0f)*size[face/2]-center[face/2]);if(closest>fd){closest=fd;k=face;}}
    #|   wp::vec3f nearest(0.0f);nearest[k/2]=k%2?-1.0f:1.0f;
    #|   pos=wp::add(center,wp::div(wp::mul(nearest,radius-closest),2.0f));normal=wp::mul(rot,nearest);c.dist=-closest-radius;
    #| }else{
    #|   wp::vec3f deepest=wp::add(center,wp::mul(dir,radius));pos=wp::mul(wp::add(clamped,deepest),0.5f);normal=wp::mul(rot,dir);c.dist=dist-radius;
    #| }
    #| c.pos=wp::add(box,wp::mul(rot,pos));c.frame=mr_frame(normal);return c;
    #|}
  )
}
