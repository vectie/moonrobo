///|
/// MuJoCo-Warp 3.15 EPA: actual initial polytopes, packed faces, horizon
/// expansion and affine witness recovery. All scratch arrays are owned views.
fn epa_source() -> String {
  (
    #|struct mr_polytope {int status,failure,nvert,nface,nhorizon;wp::vec3f center;wp::array_t<wp::vec3f> vert,face_pr;wp::array_t<int> vert_index,face,horizon;wp::array_t<float> face_norm2;};
    #|static __device__ wp::vec3f mr_vertex(mr_polytope& p,int i){return wp::sub(wp::index(p.vert,2*i),wp::index(p.vert,2*i+1));}
    #|static __device__ wp::vec3i mr_face_vertices(int f){return wp::vec3i(f&0x3ff,(f>>10)&0x3ff,(f>>20)&0x3ff);}
    #|static __device__ bool mr_face_invalid(int f){return (unsigned(f)&0xc0000000u)!=0;}
    #|static __device__ bool mr_same_side(wp::vec3f p0,wp::vec3f p1,wp::vec3f p2,wp::vec3f p3){wp::vec3f n=wp::cross(wp::sub(p1,p0),wp::sub(p2,p0));float a=wp::dot(n,wp::sub(p3,p0)),b=wp::dot(n,wp::neg(p0));return (a>0.0f&&b>0.0f)||(a<0.0f&&b<0.0f);}
    #|static __device__ bool mr_tetra(wp::vec3f a,wp::vec3f b,wp::vec3f c,wp::vec3f d){return mr_same_side(a,b,c,d)&&mr_same_side(b,c,d,a)&&mr_same_side(c,d,a,b)&&mr_same_side(d,a,b,c);}
    #|static __device__ wp::vec3f mr_affine(wp::vec3f a,wp::vec3f b,wp::vec3f c,wp::vec3f p){
    #| float m14=b[1]*c[2]-b[2]*c[1]-a[1]*c[2]+a[2]*c[1]+a[1]*b[2]-a[2]*b[1],m24=b[0]*c[2]-b[2]*c[0]-a[0]*c[2]+a[2]*c[0]+a[0]*b[2]-a[2]*b[0],m34=b[0]*c[1]-b[1]*c[0]-a[0]*c[1]+a[1]*c[0]+a[0]*b[1]-a[1]*b[0];
    #| float u1=wp::abs(m14),u2=wp::abs(m24),u3=wp::abs(m34),m;int x,y;if(u1>=u2&&u1>=u3){m=m14;x=1;y=2;}else if(u2>=u3){m=m24;x=0;y=2;}else{m=m34;x=0;y=1;}
    #| float c1=p[x]*b[y]+p[y]*c[x]+b[x]*c[y]-p[x]*c[y]-p[y]*b[x]-c[x]*b[y],c2=p[x]*c[y]+p[y]*a[x]+c[x]*a[y]-p[x]*a[y]-p[y]*c[x]-a[x]*c[y],c3=p[x]*a[y]+p[y]*b[x]+a[x]*b[y]-p[x]*b[y]-p[y]*a[x]-b[x]*a[y];return wp::vec3f(c1/m,c2/m,c3/m);
    #|}
    #|static __device__ bool mr_tri_intersect(wp::vec3f a,wp::vec3f b,wp::vec3f c,wp::vec3f p){wp::vec3f l=mr_affine(a,b,c,p);if(l[0]<0.0f||l[1]<0.0f||l[2]<0.0f)return false;wp::vec3f q;for(int i=0;i<3;i++)q[i]=a[i]*l[0]+b[i]*l[1]+c[i]*l[2];return wp::length(wp::sub(q,p))<1.0e-15f;}
    #|static __device__ float mr_attach(mr_polytope& p,int idx,int a,int b,int c){
    #| if(idx<0||idx>=MR_EPA_FACES||idx>=p.face.shape[0]||idx>=p.face_pr.shape[0]||idx>=p.face_norm2.shape[0]){p.failure=4;return 0.0f;}
    #| wp::vec3f x=mr_vertex(p,a),y=mr_vertex(p,b),z=mr_vertex(p,c);int ret;wp::vec3f r=mr_plane(z,y,x,ret);if(ret)return 0.0f;
    #| if(wp::dot(r,wp::sub(x,p.center))<0.0f)r=wp::neg(r);float norm=wp::dot(r,r);if(!mr_finite3(r)||!mr_finite(norm)){p.failure=6;return 0.0f;}
    #| wp::index(p.face,idx)=a+(b<<10)+(c<<20);wp::index(p.face_pr,idx)=r;wp::index(p.face_norm2,idx)=norm;return norm;
    #|}
    #|static __device__ void mr_epa_support(mr_polytope& p,int i,mr_geom& a,mr_geom& b,wp::vec3f dir,bool update){
    #| if(i<0||i>=MR_EPA_VERTICES||i>=1024||2*i+1>=p.vert.shape[0]||2*i+1>=p.vert_index.shape[0]){p.failure=4;return;}
    #| mr_support x=mr_support_point(a,dir),y=mr_support_point(b,wp::neg(dir));if(!mr_finite3(x.point)||!mr_finite3(y.point)||!mr_valid_cached(a,x.cached_index)||!mr_valid_cached(b,y.cached_index)){p.failure=6;return;}
    #| wp::index(p.vert,2*i)=x.point;wp::index(p.vert,2*i+1)=y.point;wp::index(p.vert_index,2*i)=x.vertex_index;wp::index(p.vert_index,2*i+1)=y.vertex_index;if(update){a.index=x.cached_index;b.index=y.cached_index;}
    #|}
    #|static __device__ void mr_copy_simplex(mr_polytope& p,mr_gjk_result& r,int n){for(int i=0;i<n;i++){wp::index(p.vert,2*i)=r.simplex1[i];wp::index(p.vert,2*i+1)=r.simplex2[i];wp::index(p.vert_index,2*i)=r.simplex_index1[i];wp::index(p.vert_index,2*i+1)=r.simplex_index2[i];}}
    #|static __device__ void mr_replace_simplex(mr_polytope& p,mr_gjk_result& r,int a,int b,int c){int ids[3]={a,b,c};for(int i=0;i<3;i++){r.simplex1[i]=wp::index(p.vert,2*ids[i]);r.simplex2[i]=wp::index(p.vert,2*ids[i]+1);r.simplex[i]=wp::sub(r.simplex1[i],r.simplex2[i]);r.simplex_index1[i]=wp::index(p.vert_index,2*ids[i]);r.simplex_index2[i]=wp::index(p.vert_index,2*ids[i]+1);}r.dim=3;}
    #|static __device__ wp::mat33f mr_rot120(wp::vec3f axis){float n=wp::length(axis),x=axis[0]/n,y=axis[1]/n,z=axis[2]/n,s=0.86602540378f,c=-0.5f;return wp::mat33f(c+x*x*(1.0f-c),x*y*(1.0f-c)-z*s,x*z*(1.0f-c)+y*s,y*x*(1.0f-c)+z*s,c+y*y*(1.0f-c),y*z*(1.0f-c)-x*s,z*x*(1.0f-c)-y*s,z*y*(1.0f-c)+x*s,c+z*z*(1.0f-c));}
    #|static __device__ int mr_ray_triangle(wp::vec3f a,wp::vec3f b,wp::vec3f c,wp::vec3f d,wp::vec3f e){float x=mr_det(wp::sub(c,a),wp::sub(d,a),wp::sub(b,a)),y=mr_det(wp::sub(d,a),wp::sub(e,a),wp::sub(b,a)),z=mr_det(wp::sub(e,a),wp::sub(c,a),wp::sub(b,a));if(x>=0.0f&&y>=0.0f&&z>=0.0f)return 1;if(x<=0.0f&&y<=0.0f&&z<=0.0f)return -1;return 0;}
    #|static __device__ void mr_polytope2(mr_polytope& p,mr_gjk_result& r,mr_geom a,mr_geom b){
    #| wp::vec3f diff=wp::sub(r.simplex[1],r.simplex[0]);p.center=wp::mul(wp::add(r.simplex[0],r.simplex[1]),0.5f);float value=1.0e30f;int index=0;for(int i=0;i<3;i++)if(wp::abs(diff[i])<value){value=wp::abs(diff[i]);index=i;}
    #| wp::vec3f e(0.0f);e[index]=1.0f;wp::vec3f d1=wp::cross(e,diff);wp::mat33f R=mr_rot120(diff);wp::vec3f d2=wp::mul(R,d1),d3=wp::mul(R,d2);mr_copy_simplex(p,r,2);
    #| mr_epa_support(p,2,a,b,wp::div(d1,wp::length(d1)),false);mr_epa_support(p,3,a,b,wp::div(d2,wp::length(d2)),false);mr_epa_support(p,4,a,b,wp::div(d3,wp::length(d3)),false);if(p.failure)return;
    #| int faces[6][3]={{0,2,3},{0,4,2},{0,3,4},{1,3,2},{1,2,4},{1,4,3}};for(int i=0;i<6;i++)if(mr_attach(p,i,faces[i][0],faces[i][1],faces[i][2])<1.0e-10f){p.status=-1;mr_replace_simplex(p,r,faces[i][0],faces[i][1],faces[i][2]);return;}
    #| if(!mr_ray_triangle(r.simplex[0],r.simplex[1],mr_vertex(p,2),mr_vertex(p,3),mr_vertex(p,4))){p.status=1;return;}p.nvert=5;p.nface=6;p.status=0;
    #|}
    #|static __device__ void mr_polytope3(mr_polytope& p,mr_gjk_result& r,mr_geom a,mr_geom b){
    #| p.center=wp::mul(wp::add(wp::add(r.simplex[0],r.simplex[1]),r.simplex[2]),float(1.0/3.0));wp::vec3f n=wp::cross(wp::sub(r.simplex[1],r.simplex[0]),wp::sub(r.simplex[2],r.simplex[0]));float norm=wp::length(n);if(norm<1.0e-15f){p.status=2;return;}n=wp::div(n,norm);mr_copy_simplex(p,r,3);
    #| mr_epa_support(p,3,a,b,wp::neg(n),false);mr_epa_support(p,4,a,b,n,false);if(p.failure)return;wp::vec3f v1=r.simplex[0],v2=r.simplex[1],v3=r.simplex[2],v4=mr_vertex(p,3),v5=mr_vertex(p,4);
    #| if(mr_tri_intersect(v1,v2,v3,v4)){p.status=3;return;}if(mr_tri_intersect(v1,v2,v3,v5)){p.status=4;return;}if(r.dist>1.0e-5f&&!mr_tetra(v1,v2,v3,v4)&&!mr_tetra(v1,v2,v3,v5)){p.status=5;return;}
    #| int faces[6][3]={{4,0,1},{4,2,0},{4,1,2},{3,1,0},{3,0,2},{3,2,1}};for(int i=0;i<6;i++)if(mr_attach(p,i,faces[i][0],faces[i][1],faces[i][2])<1.0e-10f){p.status=6+i;return;}p.nvert=5;p.nface=6;p.status=0;
    #|}
    #|static __device__ void mr_polytope4(mr_polytope& p,mr_gjk_result& r){
    #| p.center=wp::mul(wp::add(wp::add(wp::add(r.simplex[0],r.simplex[1]),r.simplex[2]),r.simplex[3]),0.25f);mr_copy_simplex(p,r,4);int faces[4][3]={{0,1,2},{0,3,1},{0,2,3},{3,2,1}};float d[4];int idx=0;
    #| for(int i=0;i<4;i++){d[i]=mr_attach(p,i,faces[i][0],faces[i][1],faces[i][2]);if(d[i]<1.0e-17f){p.status=-1;mr_replace_simplex(p,r,faces[i][0],faces[i][1],faces[i][2]);return;}if(i==1)idx=d[0]<d[1]?0:1;else if(i>1&&d[i]<d[idx])idx=i;}
    #| if(!mr_tetra(r.simplex[0],r.simplex[1],r.simplex[2],r.simplex[3])){if(d[idx]>1.0e-15f){p.status=12;return;}p.status=-1;mr_replace_simplex(p,r,faces[idx][0],faces[idx][1],faces[idx][2]);return;}p.nvert=4;p.nface=4;p.status=0;
    #|}
    #|static __device__ int mr_add_edge(mr_polytope& p,int a,int b){int n=p.nhorizon;if(n<0)return -1;int edge=(wp::min(a,b)<<10)|wp::max(a,b);for(int i=0;i<n;i++)if(wp::index(p.horizon,i)==edge){wp::index(p.horizon,i)=wp::index(p.horizon,n-1);return n-1;}if(n>=p.horizon.shape[0]){p.failure=5;return -1;}wp::index(p.horizon,n)=edge;return n+1;}
    #|static __device__ void mr_face_edges(mr_polytope& p,int idx){wp::vec3i f=mr_face_vertices(wp::index(p.face,idx));p.nhorizon=mr_add_edge(p,f[0],f[1]);p.nhorizon=mr_add_edge(p,f[1],f[2]);p.nhorizon=mr_add_edge(p,f[2],f[0]);}
    #|struct mr_epa_result {float dist;wp::vec3f x1,x2;int idx,iterations;};
    #|static __device__ mr_epa_result mr_epa(float tol,int maxiter,mr_polytope& p,mr_geom a,mr_geom b){
    #| mr_epa_result out;out.dist=0.0f;out.x1=wp::vec3f(0.0f);out.x2=wp::vec3f(0.0f);out.idx=-1;out.iterations=0;float upper=1.0e30f,upper2=1.0e30f;int idx=-1,pidx=-1,nvalid=p.nface;bool discrete=(a.type==1||a.type==6||a.type==7)&&(b.type==1||b.type==6||b.type==7)&&a.margin==0.0f&&b.margin==0.0f;float eps=discrete?1.0e-7f:tol;bool stopped=false;
    #| for(int iteration=0;iteration<wp::min(maxiter,1000);iteration++){
    #|   out.iterations=iteration+1;pidx=idx;idx=-1;float lower2=1.0e30f;for(int i=0;i<p.nface;i++)if(!mr_face_invalid(wp::index(p.face,i))&&wp::index(p.face_norm2,i)<lower2){idx=i;lower2=wp::index(p.face_norm2,i);}
    #|   if(lower2>upper2||idx<0){idx=pidx;stopped=true;break;}if(lower2<=0.0f){stopped=true;break;}float lower=wp::sqrt(lower2);int wi=p.nvert;wp::vec3f pr=wp::index(p.face_pr,idx);mr_epa_support(p,wi,a,b,wp::div(pr,lower),true);if(p.failure)return out;wp::vec3f w=mr_vertex(p,wi);p.nvert++;
    #|   float uk=wp::dot(pr,w)/lower;if(!mr_finite(uk)){p.failure=6;return out;}if(uk<upper){upper=uk;upper2=upper*upper;}if(upper-lower<eps){stopped=true;break;}
    #|   if(discrete){bool repeated=false;for(int i=0;i<p.nvert-1;i++)if(wp::index(p.vert_index,2*i)==wp::index(p.vert_index,2*wi)&&wp::index(p.vert_index,2*i+1)==wp::index(p.vert_index,2*wi+1)){repeated=true;break;}if(repeated){stopped=true;break;}}
    #|   nvalid--;wp::index(p.face,idx)=int(unsigned(wp::index(p.face,idx))|0x80000000u);mr_face_edges(p,idx);if(p.failure)return out;
    #|   for(int i=0;i<p.nface;i++){int f=wp::index(p.face,i);if((unsigned(f)&0x80000000u)!=0)continue;if(wp::dot(wp::index(p.face_pr,i),w)-wp::index(p.face_norm2,i)>1.0e-10f){if(!mr_face_invalid(f))nvalid--;wp::index(p.face,i)=int(unsigned(f)|0x80000000u);mr_face_edges(p,i);if(p.failure)return out;}}
    #|   for(int i=0;i<p.nhorizon;i++){int edge=wp::index(p.horizon,i);float d2=mr_attach(p,p.nface,wi,edge&0x3ff,(edge>>10)&0x3ff);if(p.failure)return out;if(d2==0.0f){idx=-1;break;}p.nface++;if(d2>=lower2&&d2<=upper2)nvalid++;else wp::index(p.face,p.nface-1)=int(unsigned(wp::index(p.face,p.nface-1))|0x40000000u);}
    #|   if(nvalid==0||idx==-1){stopped=true;break;}p.nhorizon=0;
    #| }
    #| if(!stopped){p.failure=6;return out;}if(idx<0){p.failure=6;return out;}wp::vec3i f=mr_face_vertices(wp::index(p.face,idx));wp::vec3f l=mr_affine(mr_vertex(p,f[0]),mr_vertex(p,f[1]),mr_vertex(p,f[2]),wp::index(p.face_pr,idx));
    #| for(int axis=0;axis<3;axis++){out.x1[axis]=wp::index(p.vert,2*f[0])[axis]*l[0]+wp::index(p.vert,2*f[1])[axis]*l[1]+wp::index(p.vert,2*f[2])[axis]*l[2];out.x2[axis]=wp::index(p.vert,2*f[0]+1)[axis]*l[0]+wp::index(p.vert,2*f[1]+1)[axis]*l[1]+wp::index(p.vert,2*f[2]+1)[axis]*l[2];}
    #| out.dist=-wp::sqrt(wp::index(p.face_norm2,idx));out.idx=idx;
    #| int i1=wp::index(p.vert_index,2*f[0]),i2=wp::index(p.vert_index,2*f[1]),i3=wp::index(p.vert_index,2*f[2]);
    #| if(a.type==1&&(i1!=i2||i1!=i3)){wp::vec3f n(0.0f,0.0f,1.0f);if(b.type==2||b.type==3){float radius=b.size[0],margin=b.margin;b.margin=0.0f;b.size[0]=0.0f;mr_support sp=mr_support_point(b,out.x2);out.x2=wp::sub(sp.point,wp::mul(n,0.5f*margin+radius));b.size[0]=radius;b.margin=margin;}else{out.x2=wp::normalize(out.x2);mr_support sp=mr_support_point(b,out.x2);out.x2=sp.point;}wp::vec3f v1=a.prism[3],v2=a.prism[4],v3=a.prism[5],l2=mr_affine(v1,v2,v3,out.x2);if(l2[0]>0.0f&&l2[1]>0.0f&&l2[2]>0.0f)out.x1=wp::add(wp::add(wp::mul(v1,l2[0]),wp::mul(v2,l2[1])),wp::mul(v3,l2[2]));else{wp::vec3f v=v3;if(l2[1]>0.0f)v=v2;if(l2[0]>0.0f)v=v1;out.x1=wp::sub(out.x2,wp::mul(n,wp::dot(wp::sub(out.x2,v),n)));}out.dist=-wp::length(wp::sub(out.x1,out.x2));}
    #| if(!mr_finite3(out.x1)||!mr_finite3(out.x2)||!mr_finite(out.dist))p.failure=6;return out;
    #|}
  )
}
