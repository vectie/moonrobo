///|
fn support_source() -> String {
  (
    #|struct mr_geom {int type,index,vertadr,vertnum;wp::vec3f pos,size;wp::mat33f rot;float margin;wp::array_t<wp::vec3f> vert;};
    #|struct mr_support {wp::vec3f point;int cached_index,vertex_index;};
    #|static __device__ bool mr_finite(float x){return x==x&&wp::abs(x)<=3.4028234663852886e38f;}
    #|static __device__ bool mr_finite3(wp::vec3f v){return mr_finite(v[0])&&mr_finite(v[1])&&mr_finite(v[2]);}
    #|static __device__ bool mr_supported(int t){return t>=2&&t<=7;}
    #|static __device__ mr_support mr_support_point(mr_geom g,wp::vec3f dir){
    #| mr_support s;s.point=wp::vec3f(0.0f);s.cached_index=-1;s.vertex_index=-1;
    #| if(g.type==2){s.point=wp::add(g.pos,wp::mul(dir,g.size[0]+0.5f*g.margin));return s;}
    #| wp::vec3f local=wp::mul(wp::transpose(g.rot),dir),res(0.0f);
    #| if(g.type==6){wp::vec3f tmp(wp::sign(local[0]),wp::sign(local[1]),wp::sign(local[2]));res=wp::cw_mul(tmp,g.size);s.point=wp::add(wp::mul(g.rot,res),g.pos);s.vertex_index=(tmp[0]>0.0f?1:0)+(tmp[1]>0.0f?2:0)+(tmp[2]>0.0f?4:0);}
    #| else if(g.type==3){res=wp::mul(local,g.size[0]);res[2]+=wp::sign(local[2])*g.size[1];s.point=wp::add(wp::mul(g.rot,res),g.pos);}
    #| else if(g.type==4){res=wp::cw_mul(local,g.size);res=wp::normalize(res);res=wp::cw_mul(res,g.size);s.point=wp::add(wp::mul(g.rot,res),g.pos);}
    #| else if(g.type==5){float d=wp::sqrt(local[0]*local[0]+local[1]*local[1]);if(d>1.0e-15f){float scale=g.size[0]/d;res[0]=local[0]*scale;res[1]=local[1]*scale;}res[2]=local[2]>=0.0f?g.size[1]:-g.size[1];s.vertex_index=local[2]>=0.0f?0:1;s.point=wp::add(wp::mul(g.rot,res),g.pos);}
    #| else if(g.type==7){
    #|   float max_dist=-1.0e30f;
    #|   if(g.index> -1){s.cached_index=g.index;wp::vec3f v=wp::index(g.vert,g.index);max_dist=wp::dot(v,local);s.point=v;}
    #|   // Exact graphadr==-1 exhaustive branch, retaining cached tie selection.
    #|   for(int i=0;i<g.vertnum;i++){wp::vec3f v=wp::index(g.vert,g.vertadr+i);float d=wp::dot(v,local);if(d>max_dist){max_dist=d;s.point=v;s.cached_index=g.vertadr+i;}}
    #|   s.vertex_index=s.cached_index-g.vertadr;s.point=wp::add(wp::mul(g.rot,s.point),g.pos);
    #| }
    #| if(g.margin>0.0f)s.point=wp::add(s.point,wp::mul(dir,0.5f*g.margin));return s;
    #|}
    #|static __device__ bool mr_valid_geom(mr_geom g){
    #| if(!mr_finite3(g.pos)||!mr_finite3(g.size)||!mr_finite(g.margin)||g.margin<0.0f)return false;
    #| for(int i=0;i<3;i++)for(int j=0;j<3;j++)if(!mr_finite(g.rot.data[i][j]))return false;
    #| // Actual pose rotations are orthonormal; a scaled/sheared import is not a Geom.rot.
    #| wp::vec3f a(g.rot.data[0][0],g.rot.data[1][0],g.rot.data[2][0]),b(g.rot.data[0][1],g.rot.data[1][1],g.rot.data[2][1]),c(g.rot.data[0][2],g.rot.data[1][2],g.rot.data[2][2]);
    #| if(wp::abs(wp::dot(a,a)-1.0f)>1.0e-4f||wp::abs(wp::dot(b,b)-1.0f)>1.0e-4f||wp::abs(wp::dot(c,c)-1.0f)>1.0e-4f||wp::abs(wp::dot(a,b))>1.0e-4f||wp::abs(wp::dot(a,c))>1.0e-4f||wp::abs(wp::dot(b,c))>1.0e-4f||wp::dot(wp::cross(a,b),c)<0.9998f)return false;
    #| if(g.type==2)return g.size[0]>0.0f;
    #| if(g.type==3)return g.size[0]>0.0f&&g.size[1]>=0.0f;
    #| if(g.type==4||g.type==6)return g.size[0]>0.0f&&g.size[1]>0.0f&&g.size[2]>0.0f;
    #| if(g.type==5)return g.size[0]>0.0f&&g.size[1]>0.0f;
    #| if(g.type==7){for(int i=0;i<g.vertnum;i++)if(!mr_finite3(wp::index(g.vert,g.vertadr+i)))return false;return true;}
    #| return false;
    #|}
  )
}
