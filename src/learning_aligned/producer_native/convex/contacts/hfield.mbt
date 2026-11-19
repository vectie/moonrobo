///|
/// Actual heightfield filter, prism traversal, CCD and four-contact selection
/// from collision_convex.py. Frame/state data stays in genuine owned views.
fn hfield_source() -> String {
  (
    #|struct mr_heightfield {wp::vec4f size;int nrow,ncol,adr;wp::array_t<float> data;};
    #|struct mr_hfield_result {int count,failure;float dist[4];wp::vec3f pos[4],normal[4];};
    #|static __device__ mr_hfield_result mr_hfield(float tol,int gjkiters,int epaiters,mr_geom a,mr_geom b,mr_heightfield hf,mr_polytope& pt,float margin,float gap,float filter_margin,float rbound){
    #| mr_hfield_result out;out.count=0;out.failure=0;for(int i=0;i<4;i++){out.dist[i]=0.0f;out.pos[i]=wp::vec3f(0.0f);out.normal[i]=wp::vec3f(0.0f);}
    #| if(a.type!=1||b.type<2||b.type>7||hf.nrow<2||hf.ncol<2||hf.adr<0||hf.adr>hf.data.shape[0]||hf.nrow>(hf.data.shape[0]-hf.adr)/hf.ncol||!mr_finite(rbound)||rbound<0.0f||!mr_finite(filter_margin)){out.failure=2;return out;}
    #| for(int i=0;i<4;i++)if(!mr_finite(hf.size[i])||(i<3?hf.size[i]<=0.0f:hf.size[i]<0.0f)){out.failure=2;return out;}
    #| int samples=hf.nrow*hf.ncol;for(int i=0;i<samples;i++){float v=wp::index(hf.data,hf.adr+i);if(!mr_finite(v)||v<0.0f||v>1.0f){out.failure=2;return out;}}
    #| wp::vec3f hfpos=a.pos;wp::mat33f hfrot=a.rot,transpose=wp::transpose(hfrot);b.pos=wp::mul(transpose,wp::sub(b.pos,hfpos));b.rot=wp::mul(transpose,b.rot);b.margin=0.0f;
    #| for(int i=0;i<2;i++)if(hf.size[i]<b.pos[i]-rbound-filter_margin||-hf.size[i]>b.pos[i]+rbound+filter_margin)return out;
    #| if(hf.size[2]<b.pos[2]-rbound-filter_margin||-hf.size[3]>b.pos[2]+rbound+filter_margin)return out;
    #| wp::vec3f bounds_min,bounds_max;for(int i=0;i<3;i++){wp::vec3f axis(0.0f);axis[i]=1.0f;mr_support hi=mr_support_point(b,axis),lo=mr_support_point(b,wp::neg(axis));bounds_max[i]=hi.point[i];bounds_min[i]=lo.point[i];if(!mr_finite(bounds_min[i])||!mr_finite(bounds_max[i])||!mr_valid_cached(b,hi.cached_index)||!mr_valid_cached(b,lo.cached_index)){out.failure=8;return out;}}
    #| if(bounds_min[0]-filter_margin>hf.size[0]||bounds_max[0]+filter_margin< -hf.size[0]||bounds_min[1]-filter_margin>hf.size[1]||bounds_max[1]+filter_margin< -hf.size[1]||bounds_min[2]-filter_margin>hf.size[2]||bounds_max[2]+filter_margin< -hf.size[3])return out;
    #| float xs=0.5f*float(hf.ncol-1)/hf.size[0],ys=0.5f*float(hf.nrow-1)/hf.size[1];float c0=wp::floor((bounds_min[0]+hf.size[0])*xs),c1=wp::ceil((bounds_max[0]+hf.size[0])*xs),r0=wp::floor((bounds_min[1]+hf.size[1])*ys),r1=wp::ceil((bounds_max[1]+hf.size[1])*ys);
    #| if(!mr_finite(c0)||!mr_finite(c1)||!mr_finite(r0)||!mr_finite(r1)){out.failure=8;return out;}
    #| int cmin=wp::min(hf.ncol-1,int(wp::clamp(c0,0.0f,float(hf.ncol-1)))),cmax=wp::min(hf.ncol-1,int(wp::clamp(c1,0.0f,float(hf.ncol-1)))),rmin=wp::min(hf.nrow-1,int(wp::clamp(r0,0.0f,float(hf.nrow-1)))),rmax=wp::min(hf.nrow-1,int(wp::clamp(r1,0.0f,float(hf.nrow-1))));
    #| float dx=(2.0f*hf.size[0])/float(hf.ncol-1),dy=(2.0f*hf.size[1])/float(hf.nrow-1);if(!mr_finite(dx)||!mr_finite(dy)||dx<=0.0f||dy<=0.0f){out.failure=8;return out;}
    #| a.pos=wp::vec3f(0.0f);a.rot=wp::mat33f(1.0f,0.0f,0.0f,0.0f,1.0f,0.0f,0.0f,0.0f,1.0f);a.margin=0.0f;b.margin=margin;for(int i=0;i<6;i++)a.prism[i]=wp::vec3f(0.0f);for(int i=0;i<3;i++)a.prism[i][2]=-hf.size[3];
    #| float distances[50];wp::vec3f positions[50],normals[50];int count=0,minid=-1;float min_dist=1.0e10f;wp::vec3f min_normal(1.0e10f),min_pos(1.0e10f);
    #| for(int r=rmin;r<rmax;r++){
    #|   for(int k=0;k<2;k++){int row=r+(k==0?1:0);float x=dx*float(cmin)-hf.size[0],y=dy*float(row)-hf.size[1],z=wp::index(hf.data,hf.adr+row*hf.ncol+cmin)*hf.size[2]+margin;a.prism[0]=a.prism[1];a.prism[1]=a.prism[2];a.prism[3]=a.prism[4];a.prism[4]=a.prism[5];a.prism[2][0]=x;a.prism[5][0]=x;a.prism[2][1]=y;a.prism[5][1]=y;a.prism[5][2]=z;}
    #|   for(int c=cmin+1;c<=cmax;c++)for(int k=0;k<2;k++){
    #|     if(count>=50){out.failure=7;return out;}int row=r+(k==0?1:0);float x=dx*float(c)-hf.size[0],y=dy*float(row)-hf.size[1],z=wp::index(hf.data,hf.adr+row*hf.ncol+c)*hf.size[2]+margin;a.prism[0]=a.prism[1];a.prism[1]=a.prism[2];a.prism[3]=a.prism[4];a.prism[4]=a.prism[5];a.prism[2][0]=x;a.prism[5][0]=x;a.prism[2][1]=y;a.prism[5][1]=y;a.prism[5][2]=z;
    #|     if(a.prism[3][2]<bounds_min[2]&&a.prism[4][2]<bounds_min[2]&&a.prism[5][2]<bounds_min[2])continue;
    #|     wp::vec3f sum=wp::add(wp::add(wp::add(wp::add(wp::add(a.prism[0],a.prism[1]),a.prism[2]),a.prism[3]),a.prism[4]),a.prism[5]);wp::vec3f center=wp::add(a.pos,wp::mul(wp::mul(a.rot,sum),float(1.0/6.0)));
    #|     mr_ccd_result hit=mr_ccd_from(tol,0.0f,gjkiters,epaiters,a,b,pt,false,center,b.pos);if(hit.failure){out.failure=hit.failure;return out;}if(hit.count==0||hit.dist>=margin+gap)continue;
    #|     wp::vec3f local=wp::mul(wp::add(hit.w1[0],hit.w2[0]),0.5f),pos=wp::add(wp::mul(hfrot,local),hfpos),normal=wp::mul(hfrot,wp::normalize(wp::sub(hit.w1[0],hit.w2[0])));
    #|     if(!mr_finite(hit.dist)||!mr_finite3(pos)||!mr_finite3(normal)){out.failure=8;return out;}distances[count]=hit.dist;positions[count]=pos;normals[count]=normal;if(hit.dist<min_dist){min_dist=hit.dist;min_pos=pos;min_normal=normal;minid=count;}count++;
    #|   }
    #| }
    #| if(count==0)return out;if(minid<0){out.failure=8;return out;}out.dist[0]=min_dist;out.pos[0]=min_pos;out.normal[0]=min_normal;out.count=1;
    #| int id1=-1;float d1=-1.0e10f;for(int i=0;i<count;i++){if(i==minid)continue;float d=wp::length(wp::sub(positions[i],min_pos));if(!mr_finite(d)){out.failure=8;return out;}if(d>d1){id1=i;d1=d;}}if(id1<0||(0.0f<d1&&d1<1.0e-3f))return out;out.dist[1]=distances[id1];out.pos[1]=positions[id1];out.normal[1]=normals[id1];out.count=2;
    #| wp::vec3f axis=wp::cross(min_normal,wp::sub(min_pos,positions[id1]));int id2=-1;float d2=-1.0e10f;for(int i=0;i<count;i++){if(i==minid||i==id1)continue;float d=wp::abs(wp::dot(wp::sub(positions[i],min_pos),axis));if(!mr_finite(d)){out.failure=8;return out;}if(d>d2){id2=i;d2=d;}}if(id2<0||(0.0f<d2&&d2<1.0e-3f))return out;out.dist[2]=distances[id2];out.pos[2]=positions[id2];out.normal[2]=normals[id2];out.count=3;
    #| wp::vec3f min2=wp::cross(min_normal,wp::sub(min_pos,positions[id2])),axis12=wp::cross(min_normal,wp::sub(positions[id1],positions[id2]));int id3=-1;float d3=-1.0e10f;for(int i=0;i<count;i++){if(i==minid||i==id1||i==id2)continue;float d=wp::abs(wp::dot(wp::sub(positions[i],min_pos),min2))+wp::abs(wp::dot(wp::sub(positions[id1],positions[i]),axis12));if(!mr_finite(d)){out.failure=8;return out;}if(d>d3){id3=i;d3=d;}}if(id3<0||(0.0f<d3&&d3<1.0e-3f))return out;out.dist[3]=distances[id3];out.pos[3]=positions[id3];out.normal[3]=normals[id3];out.count=4;return out;
    #|}
  )
}
