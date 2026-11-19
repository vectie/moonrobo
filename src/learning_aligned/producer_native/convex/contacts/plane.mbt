///|
/// Actual plane primitive formulas and collision_primitive::plane_convex,
/// including exhaustive and graph hillclimb contact selection/tie order.
fn plane_source() -> String {
  (
    #|struct mr_plane_result {int count,failure;float dist[8];wp::vec3f pos[8];wp::mat33f frame;};
    #|static __device__ wp::vec3f mr_axis_z(wp::mat33f r){return wp::vec3f(r.data[0][2],r.data[1][2],r.data[2][2]);}
    #|static __device__ float mr_plane_score(int mode,wp::vec3f v,wp::vec3f plane,wp::vec3f n,float threshold,wp::vec3f a,wp::vec3f b,wp::vec3f c){
    #| float support=wp::dot(wp::sub(plane,v),n),mask=support>threshold?0.0f:-1.0e6f;
    #| if(mode==0)return support;if(mode==1)return support>threshold?support:-1.0e6f;
    #| if(mode==2){wp::vec3f d=wp::sub(a,v);return wp::dot(d,d)+mask;}
    #| if(mode==3)return wp::abs(wp::dot(wp::sub(a,v),wp::cross(n,wp::sub(a,b))))+mask;
    #| float x=wp::abs(wp::dot(wp::sub(a,v),wp::cross(n,wp::sub(a,c))))+mask;
    #| float y=wp::abs(wp::dot(wp::sub(b,v),wp::cross(n,wp::sub(b,c))))+mask;return x+y;
    #|}
    #|static __device__ void mr_plane_convex(mr_geom plane,mr_geom convex,mr_plane_result& out){
    #| wp::vec3f normal=mr_axis_z(plane.rot),p=wp::mul(wp::transpose(convex.rot),wp::sub(plane.pos,convex.pos)),n=wp::mul(wp::transpose(convex.rot),normal),a(0.0f),b(0.0f),c(0.0f);int ids[4]={-1,-1,-1,-1};
    #| if(convex.graphadr==-1||convex.vertnum<10){
    #|  float best=-1.0e6f;for(int i=0;i<convex.vertnum;i++){wp::vec3f v=wp::index(convex.vert,convex.vertadr+i);float score=wp::dot(wp::sub(p,v),n);if(score>best){best=score;ids[0]=i;a=v;}}
    #|  if(best<0.0f)return;float threshold=best-1.0e-3f;
    #|  for(int mode=2;mode<=4;mode++){float value=-1.0e6f;int index=-1;for(int i=0;i<convex.vertnum;i++){float score=mr_plane_score(mode,wp::index(convex.vert,convex.vertadr+i),p,n,threshold,a,b,c);if(score>value){value=score;index=i;}}ids[mode-1]=index;if(index<0){out.failure=8;return;}if(mode==2)b=wp::index(convex.vert,convex.vertadr+index);if(mode==3)c=wp::index(convex.vert,convex.vertadr+index);}
    #| }else{
    #|  int nv=wp::index(convex.graph,convex.graphadr),ea=convex.graphadr+2,va=ea+nv,base=va+nv,imax=0;float best=-1.0e6f;
    #|  while(true){int previous=imax;int i=wp::index(convex.graph,ea+imax);while(wp::index(convex.graph,base+i)>=0){int node=wp::index(convex.graph,base+i),v=wp::index(convex.graph,va+node);float score=wp::dot(wp::sub(p,wp::index(convex.vert,convex.vertadr+v)),n);if(score>best){best=score;imax=node;}i++;}if(imax==previous)break;}
    #|  float threshold=wp::max(0.0f,best-1.0e-3f);
    #|  for(int mode=1;mode<=4;mode++){float value=-1.0e6f;while(true){int previous=imax;int i=wp::index(convex.graph,ea+imax);while(wp::index(convex.graph,base+i)>=0){int node=wp::index(convex.graph,base+i),v=wp::index(convex.graph,va+node);float score=mr_plane_score(mode,wp::index(convex.vert,convex.vertadr+v),p,n,threshold,a,b,c);if(score>value){value=score;imax=node;}i++;}if(imax==previous)break;}int index=wp::index(convex.graph,va+imax);ids[mode-1]=index;if(mode==1)a=wp::index(convex.vert,convex.vertadr+index);if(mode==2)b=wp::index(convex.vert,convex.vertadr+index);if(mode==3)c=wp::index(convex.vert,convex.vertadr+index);}
    #| }
    #| int contacts=0;for(int i=3;i>=0;i--){int index=ids[i],count=0;for(int j=0;j<=i;j++)if(ids[j]==index)count++;if(count==1){if(index<0||index>=convex.vertnum){out.failure=8;return;}wp::vec3f local=wp::index(convex.vert,convex.vertadr+index),pos=wp::add(convex.pos,wp::mul(convex.rot,local));float distance=-wp::dot(wp::sub(p,local),n);out.dist[contacts]=distance;out.pos[contacts]=wp::sub(pos,wp::mul(normal,0.5f*distance));contacts++;}}
    #|}
    #|static __device__ mr_plane_result mr_plane_contacts(mr_geom plane,mr_geom shape){
    #| mr_plane_result out;out.count=4;out.failure=0;for(int i=0;i<8;i++){out.dist[i]=1.0e10f;out.pos[i]=wp::vec3f(0.0f);}wp::vec3f n=mr_axis_z(plane.rot);out.frame=mr_frame(n);
    #| if(shape.type==2||shape.type==3){out.count=shape.type==2?1:2;wp::vec3f axis=mr_axis_z(shape.rot);if(shape.type==3){wp::vec3f tangent=wp::sub(axis,wp::mul(n,wp::dot(n,axis)));float length=wp::length(tangent);if(length!=0.0f)tangent=wp::div(tangent,length);if(length<0.5f)tangent=(-0.5f<n[1]&&n[1]<0.5f)?wp::vec3f(0.0f,1.0f,0.0f):wp::vec3f(0.0f,0.0f,1.0f);wp::vec3f c=wp::cross(n,tangent);out.frame=wp::mat33f(n[0],n[1],n[2],tangent[0],tangent[1],tangent[2],c[0],c[1],c[2]);}
    #|  for(int i=0;i<out.count;i++){wp::vec3f center=shape.pos;if(shape.type==3)center=wp::add(center,wp::mul(axis,i==0?shape.size[1]:-shape.size[1]));float dist=wp::dot(wp::sub(center,plane.pos),n)-shape.size[0];out.dist[i]=dist;out.pos[i]=wp::sub(center,wp::mul(n,shape.size[0]+0.5f*dist));}return out;}
    #| if(shape.type==4){out.count=1;wp::vec3f local=wp::neg(wp::normalize(wp::cw_mul(wp::mul(wp::transpose(shape.rot),n),shape.size))),pos=wp::add(shape.pos,wp::mul(shape.rot,wp::cw_mul(local,shape.size)));out.dist[0]=wp::dot(n,wp::sub(pos,plane.pos));out.pos[0]=wp::sub(pos,wp::mul(n,0.5f*out.dist[0]));return out;}
    #| if(shape.type==6){out.count=8;float center=wp::dot(wp::sub(shape.pos,plane.pos),n);for(int i=0;i<8;i++){wp::vec3f corner=wp::mul(shape.rot,wp::vec3f((i&1)?shape.size[0]:-shape.size[0],(i&2)?shape.size[1]:-shape.size[1],(i&4)?shape.size[2]:-shape.size[2]));out.dist[i]=center+wp::dot(n,corner);out.pos[i]=wp::sub(wp::add(corner,shape.pos),wp::mul(n,0.5f*out.dist[i]));}return out;}
    #| if(shape.type==5){wp::vec3f axis=mr_axis_z(shape.rot);float projected=wp::dot(n,axis);if(projected>0.0f){axis=wp::neg(axis);projected=-projected;}float dist0=wp::dot(wp::sub(shape.pos,plane.pos),n);wp::vec3f v=wp::sub(wp::mul(axis,projected),n);float norm2=wp::dot(v,v);v=norm2>=1.0e-12f?wp::mul(v,shape.size[0]/wp::sqrt(norm2)):wp::vec3f(shape.size[0],0.0f,0.0f);float pv=wp::dot(v,n);axis=wp::mul(axis,shape.size[1]);projected*=shape.size[1];out.dist[0]=dist0+projected+pv;out.dist[1]=dist0-projected+pv;out.pos[0]=wp::sub(wp::add(wp::add(shape.pos,v),axis),wp::mul(n,0.5f*out.dist[0]));out.pos[1]=wp::sub(wp::sub(wp::add(shape.pos,v),axis),wp::mul(n,0.5f*out.dist[1]));float dist=dist0+projected-pv*0.5f;wp::vec3f side=wp::mul(wp::normalize(wp::cross(v,axis)),shape.size[0]*wp::sqrt(3.0f)*0.5f);out.dist[2]=dist;out.dist[3]=dist;out.pos[2]=wp::sub(wp::sub(wp::add(wp::add(shape.pos,side),axis),wp::mul(v,0.5f)),wp::mul(n,0.5f*dist));out.pos[3]=wp::sub(wp::sub(wp::add(wp::sub(shape.pos,side),axis),wp::mul(v,0.5f)),wp::mul(n,0.5f*dist));return out;}
    #| if(shape.type==7){mr_plane_convex(plane,shape,out);return out;}out.failure=1;return out;
    #|}
  )
}
