///|
fn support_source() -> String {
  (
    #|struct mr_geom {int type,index,vertadr,vertnum,polyadr,polynum,graphadr;wp::vec3f pos,size,prism[6];wp::mat33f rot;float margin;wp::array_t<wp::vec3f> vert,polynormal;wp::array_t<int> polyvertadr,polyvertnum,polyvert,polymapadr,polymapnum,polymap,graph;};
    #|struct mr_support {wp::vec3f point;int cached_index,vertex_index;};
    #|static __device__ bool mr_finite(float x){return x==x&&wp::abs(x)<=3.4028234663852886e38f;}
    #|static __device__ bool mr_finite3(wp::vec3f v){return mr_finite(v[0])&&mr_finite(v[1])&&mr_finite(v[2]);}
    #|static __device__ bool mr_supported(int t){return t>=1&&t<=7;}
    #|static __device__ bool mr_valid_cached(mr_geom g,int index){if(g.type!=7)return true;if(g.graphadr==-1||g.vertnum<10)return index>=g.vertadr&&index-g.vertadr<g.vertnum;return index>=0&&index<wp::index(g.graph,g.graphadr);}
    #|static __device__ bool mr_valid_graph(mr_geom g){
    #| if(g.type!=7||g.graphadr==-1||g.vertnum<10)return true;int a=g.graphadr,n=g.graph.shape[0];if(a<0||a>n-2)return false;int nv=wp::index(g.graph,a);if(nv<=0||nv>g.vertnum||nv>(n-a-2)/2)return false;int ea=a+2,va=ea+nv,base=va+nv;
    #| for(int i=0;i<nv;i++){int v=wp::index(g.graph,va+i);if(v<0||v>=g.vertnum)return false;for(int j=0;j<i;j++)if(v==wp::index(g.graph,va+j))return false;int start=wp::index(g.graph,ea+i);if(start<0||start>=n-base)return false;bool end=false;for(int k=base+start;k<n;k++){int next=wp::index(g.graph,k);if(next<0){end=true;break;}if(next>=nv)return false;}if(!end)return false;}
    #| return true;
    #|}
    #|static __device__ mr_support mr_support_point(mr_geom g,wp::vec3f dir){
    #| mr_support s;s.point=wp::vec3f(0.0f);s.cached_index=-1;s.vertex_index=-1;
    #| if(g.type==2){s.point=wp::add(g.pos,wp::mul(dir,g.size[0]+0.5f*g.margin));return s;}
    #| if(g.type==1){float max_dist=-1.0e30f;s.vertex_index=dir[2]<0.0f?-2:-3;for(int i=0;i<6;i++){float d=wp::dot(g.prism[i],dir);if(d>max_dist){max_dist=d;s.point=g.prism[i];}}if(g.margin>0.0f)s.point=wp::add(s.point,wp::mul(dir,0.5f*g.margin));return s;}
    #| // Warp's internal TRIANGLE pseudo-geom uses rows of rot as vertices.
    #| // Flex/triangle entry construction belongs to the separate flex driver.
    #| if(g.type==999){wp::vec3f a(g.rot.data[0][0],g.rot.data[0][1],g.rot.data[0][2]),b(g.rot.data[1][0],g.rot.data[1][1],g.rot.data[1][2]),c(g.rot.data[2][0],g.rot.data[2][1],g.rot.data[2][2]);float x=wp::dot(a,dir),y=wp::dot(b,dir),z=wp::dot(c,dir);s.point=(x>y&&x>z)?a:(y>z?b:c);if(g.margin>0.0f)s.point=wp::add(s.point,wp::mul(dir,0.5f*g.margin));return s;}
    #| if(g.type==105){float a=wp::dot(g.prism[0],dir),b=wp::dot(g.prism[1],dir),c=wp::dot(g.prism[2],dir),d=wp::dot(g.prism[3],dir);s.point=(a>b&&a>c&&a>d)?g.prism[0]:(b>c&&b>d?g.prism[1]:(c>d?g.prism[2]:g.prism[3]));if(g.margin>0.0f)s.point=wp::add(s.point,wp::mul(dir,0.5f*g.margin));return s;}
    #| wp::vec3f local=wp::mul(wp::transpose(g.rot),dir),res(0.0f);
    #| if(g.type==6){wp::vec3f tmp(wp::sign(local[0]),wp::sign(local[1]),wp::sign(local[2]));res=wp::cw_mul(tmp,g.size);s.point=wp::add(wp::mul(g.rot,res),g.pos);s.vertex_index=(tmp[0]>0.0f?1:0)+(tmp[1]>0.0f?2:0)+(tmp[2]>0.0f?4:0);}
    #| else if(g.type==3){res=wp::mul(local,g.size[0]);res[2]+=wp::sign(local[2])*g.size[1];s.point=wp::add(wp::mul(g.rot,res),g.pos);}
    #| else if(g.type==4){res=wp::cw_mul(local,g.size);res=wp::normalize(res);res=wp::cw_mul(res,g.size);s.point=wp::add(wp::mul(g.rot,res),g.pos);}
    #| else if(g.type==5){float d=wp::sqrt(local[0]*local[0]+local[1]*local[1]);if(d>1.0e-15f){float scale=g.size[0]/d;res[0]=local[0]*scale;res[1]=local[1]*scale;}res[2]=local[2]>=0.0f?g.size[1]:-g.size[1];s.vertex_index=local[2]>=0.0f?0:1;s.point=wp::add(wp::mul(g.rot,res),g.pos);}
    #| else if(g.type==7){
    #|   float max_dist=-1.0e30f;
    #|   if(g.graphadr==-1||g.vertnum<10){
    #|     if(g.index> -1){s.cached_index=g.index;wp::vec3f v=wp::index(g.vert,g.index);max_dist=wp::dot(v,local);s.point=v;}
    #|     for(int i=0;i<g.vertnum;i++){wp::vec3f v=wp::index(g.vert,g.vertadr+i);float d=wp::dot(v,local);if(d>max_dist){max_dist=d;s.point=v;s.cached_index=g.vertadr+i;}}
    #|     s.vertex_index=s.cached_index-g.vertadr;
    #|   }else{
    #|     int nv=wp::index(g.graph,g.graphadr),ea=g.graphadr+2,va=ea+nv,base=va+nv,prev=-1,imax=g.index> -1?g.index:0;max_dist=wp::dot(local,wp::index(g.vert,g.vertadr+wp::index(g.graph,va+imax)));
    #|     while(imax!=prev){prev=imax;int i=wp::index(g.graph,ea+imax),sub=wp::index(g.graph,base+i);while(sub>=0){int idx=wp::index(g.graph,va+sub);float d=wp::dot(local,wp::index(g.vert,g.vertadr+idx));if(d>max_dist){imax=sub;max_dist=d;}i++;sub=wp::index(g.graph,base+i);}}
    #|     s.cached_index=imax;s.vertex_index=wp::index(g.graph,va+imax);s.point=wp::index(g.vert,g.vertadr+s.vertex_index);
    #|   }s.point=wp::add(wp::mul(g.rot,s.point),g.pos);
    #| }
    #| if(g.margin>0.0f)s.point=wp::add(s.point,wp::mul(dir,0.5f*g.margin));return s;
    #|}
    #|static __device__ bool mr_valid_geom(mr_geom g){
    #| if(!mr_finite3(g.pos)||!mr_finite3(g.size)||!mr_finite(g.margin)||g.margin<0.0f)return false;
    #| for(int i=0;i<3;i++)for(int j=0;j<3;j++)if(!mr_finite(g.rot.data[i][j]))return false;
    #| // Actual pose rotations are orthonormal; a scaled/sheared import is not a Geom.rot.
    #| wp::vec3f a(g.rot.data[0][0],g.rot.data[1][0],g.rot.data[2][0]),b(g.rot.data[0][1],g.rot.data[1][1],g.rot.data[2][1]),c(g.rot.data[0][2],g.rot.data[1][2],g.rot.data[2][2]);
    #| if(wp::abs(wp::dot(a,a)-1.0f)>1.0e-4f||wp::abs(wp::dot(b,b)-1.0f)>1.0e-4f||wp::abs(wp::dot(c,c)-1.0f)>1.0e-4f||wp::abs(wp::dot(a,b))>1.0e-4f||wp::abs(wp::dot(a,c))>1.0e-4f||wp::abs(wp::dot(b,c))>1.0e-4f||wp::dot(wp::cross(a,b),c)<0.9998f)return false;
    #| if(g.type==1)return true;
    #| if(g.type==2)return g.size[0]>0.0f;
    #| if(g.type==3)return g.size[0]>0.0f&&g.size[1]>=0.0f;
    #| if(g.type==4||g.type==6)return g.size[0]>0.0f&&g.size[1]>0.0f&&g.size[2]>0.0f;
    #| if(g.type==5)return g.size[0]>0.0f&&g.size[1]>0.0f;
    #| if(g.type==7){for(int i=0;i<g.vertnum;i++)if(!mr_finite3(wp::index(g.vert,g.vertadr+i)))return false;return true;}
    #| return false;
    #|}
  )
}
