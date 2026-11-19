///|
/// Exact signed-volume/minor distance subalgorithms from collision_gjk.py.
fn simplex_source() -> String {
  (
    #|static __device__ int mr_same(float a,float b){if(a>0.0f&&b>0.0f)return 1;if(a<0.0f&&b<0.0f)return -1;return 0;}
    #|static __device__ float mr_det(wp::vec3f a,wp::vec3f b,wp::vec3f c){return wp::dot(a,wp::cross(b,c));}
    #|static __device__ wp::vec3f mr_line(wp::vec3f a,wp::vec3f b){wp::vec3f d=wp::sub(b,a);return wp::add(b,wp::mul(d,-wp::dot(b,d)/wp::dot(d,d)));}
    #|static __device__ wp::vec3f mr_plane(wp::vec3f a,wp::vec3f b,wp::vec3f c,int& ret){
    #| wp::vec3f d21=wp::sub(b,a),d31=wp::sub(c,a),d32=wp::sub(c,b),n=wp::cross(d32,d21);float nv=wp::dot(n,b),nn=wp::dot(n,n);
    #| ret=0;if(nn==0.0f){ret=1;return wp::vec3f(0.0f);}if(nv!=0.0f&&nn>1.0e-15f)return wp::mul(n,nv/nn);
    #| n=wp::cross(d21,d31);nv=wp::dot(n,a);nn=wp::dot(n,n);if(nn==0.0f){ret=1;return wp::vec3f(0.0f);}if(nv!=0.0f&&nn>1.0e-15f)return wp::mul(n,nv/nn);
    #| n=wp::cross(d31,d32);nv=wp::dot(n,c);nn=wp::dot(n,n);return wp::mul(n,nv/nn);
    #|}
    #|static __device__ wp::vec2f mr_s1(wp::vec3f a,wp::vec3f b){
    #| wp::vec3f p=mr_line(a,b);float m=a[0]-b[0];int index=0;float v=a[1]-b[1];if(wp::abs(v)>=wp::abs(m)){m=v;index=1;}v=a[2]-b[2];if(wp::abs(v)>=wp::abs(m)){m=v;index=2;}
    #| float c1=p[index]-b[index],c2=a[index]-p[index];if(mr_same(m,c1)&&mr_same(m,c2))return wp::vec2f(c1/m,c2/m);return wp::vec2f(0.0f,1.0f);
    #|}
    #|static __device__ wp::vec3f mr_s2(wp::vec3f a,wp::vec3f b,wp::vec3f c){
    #| int ret;wp::vec3f p=mr_plane(a,b,c,ret);if(ret){wp::vec2f l=mr_s1(a,b);return wp::vec3f(l[0],l[1],0.0f);}
    #| float m14=b[1]*c[2]-b[2]*c[1]-a[1]*c[2]+a[2]*c[1]+a[1]*b[2]-a[2]*b[1];
    #| float m24=b[0]*c[2]-b[2]*c[0]-a[0]*c[2]+a[2]*c[0]+a[0]*b[2]-a[2]*b[0];
    #| float m34=b[0]*c[1]-b[1]*c[0]-a[0]*c[1]+a[1]*c[0]+a[0]*b[1]-a[1]*b[0];
    #| float u1=wp::abs(m14),u2=wp::abs(m24),u3=wp::abs(m34),m;int i,j;
    #| if(u1>=u2&&u1>=u3){m=m14;i=1;j=2;}else if(u2>=u3){m=m24;i=0;j=2;}else{m=m34;i=0;j=1;}
    #| float c1=p[i]*b[j]+p[j]*c[i]+b[i]*c[j]-p[i]*c[j]-p[j]*b[i]-c[i]*b[j];
    #| float c2=p[i]*c[j]+p[j]*a[i]+c[i]*a[j]-p[i]*a[j]-p[j]*c[i]-a[i]*c[j];
    #| float c3=p[i]*a[j]+p[j]*b[i]+a[i]*b[j]-p[i]*b[j]-p[j]*a[i]-b[i]*a[j];
    #| int b1=mr_same(m,c1),b2=mr_same(m,c2),b3=mr_same(m,c3);
    #| if(b1&&b2&&b3)return wp::vec3f(c1/m,c2/m,c3/m);
    #| wp::vec3f l(0.0f);float dmin=1.0e30f;
    #| if(!b1){wp::vec2f v=mr_s1(b,c);wp::vec3f x=wp::add(wp::mul(b,v[0]),wp::mul(c,v[1]));l=wp::vec3f(0.0f,v[0],v[1]);dmin=wp::dot(x,x);}
    #| if(!b2){wp::vec2f v=mr_s1(a,c);wp::vec3f x=wp::add(wp::mul(a,v[0]),wp::mul(c,v[1]));float d=wp::dot(x,x);if(d<dmin){l=wp::vec3f(v[0],0.0f,v[1]);dmin=d;}}
    #| if(!b3){wp::vec2f v=mr_s1(a,b);wp::vec3f x=wp::add(wp::mul(a,v[0]),wp::mul(b,v[1]));float d=wp::dot(x,x);if(d<dmin)l=wp::vec3f(v[0],v[1],0.0f);}
    #| return l;
    #|}
    #|static __device__ wp::vec4f mr_s3(wp::vec3f a,wp::vec3f b,wp::vec3f c,wp::vec3f d){
    #| float c1=-mr_det(b,c,d),c2=mr_det(a,c,d),c3=-mr_det(a,b,d),c4=mr_det(a,b,c),m=c1+c2+c3+c4;
    #| int b1=mr_same(m,c1),b2=mr_same(m,c2),b3=mr_same(m,c3),b4=mr_same(m,c4);
    #| if(b1&&b2&&b3&&b4)return wp::vec4f(c1/m,c2/m,c3/m,c4/m);
    #| wp::vec4f l(0.0f);float dmin=1.0e30f;
    #| if(!b1){wp::vec3f v=mr_s2(b,c,d);wp::vec3f x=wp::add(wp::add(wp::mul(b,v[0]),wp::mul(c,v[1])),wp::mul(d,v[2]));l=wp::vec4f(0.0f,v[0],v[1],v[2]);dmin=wp::dot(x,x);}
    #| if(!b2){wp::vec3f v=mr_s2(a,c,d);wp::vec3f x=wp::add(wp::add(wp::mul(a,v[0]),wp::mul(c,v[1])),wp::mul(d,v[2]));float dist=wp::dot(x,x);if(dist<dmin){l=wp::vec4f(v[0],0.0f,v[1],v[2]);dmin=dist;}}
    #| if(!b3){wp::vec3f v=mr_s2(a,b,d);wp::vec3f x=wp::add(wp::add(wp::mul(a,v[0]),wp::mul(b,v[1])),wp::mul(d,v[2]));float dist=wp::dot(x,x);if(dist<dmin){l=wp::vec4f(v[0],v[1],0.0f,v[2]);dmin=dist;}}
    #| if(!b4){wp::vec3f v=mr_s2(a,b,c);wp::vec3f x=wp::add(wp::add(wp::mul(a,v[0]),wp::mul(b,v[1])),wp::mul(c,v[2]));float dist=wp::dot(x,x);if(dist<dmin)l=wp::vec4f(v[0],v[1],v[2],0.0f);}
    #| return l;
    #|}
    #|static __device__ wp::vec4f mr_subdistance(int n,wp::vec3f* s){if(n==4)return mr_s3(s[0],s[1],s[2],s[3]);if(n==3){wp::vec3f v=mr_s2(s[0],s[1],s[2]);return wp::vec4f(v[0],v[1],v[2],0.0f);}if(n==2){wp::vec2f v=mr_s1(s[0],s[1]);return wp::vec4f(v[0],v[1],0.0f,0.0f);}return wp::vec4f(1.0f,0.0f,0.0f,0.0f);}
    #|static __device__ wp::vec3f mr_combine(int n,wp::vec4f l,wp::vec3f* s){
    #| if(n==1)return wp::mul(s[0],l[0]);if(n==2)return wp::add(wp::mul(s[0],l[0]),wp::mul(s[1],l[1]));
    #| if(n==3)return wp::add(wp::add(wp::mul(s[0],l[0]),wp::mul(s[1],l[1])),wp::mul(s[2],l[2]));
    #| return wp::add(wp::add(wp::add(wp::mul(s[0],l[0]),wp::mul(s[1],l[1])),wp::mul(s[2],l[2])),wp::mul(s[3],l[3]));
    #|}
  )
}
