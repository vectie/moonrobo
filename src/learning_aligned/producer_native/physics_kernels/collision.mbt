///|
// Pinned collision_driver.py helpers. Eight corners and comparison ordering are
// retained instead of replacing the original with an absolute-matrix shortcut.
fn collision_helpers() -> String {
  (
    #|static __device__ bool mr_mjw_plane(float s1,float s2,float m1,float m2,wp::vec3f x1,wp::vec3f x2,wp::mat33f r1,wp::mat33f r2){
    #| if(s1==0.0f){
    #|   float dist=wp::dot(wp::sub(x2,x1),wp::vec3f(r1.data[0][2],r1.data[1][2],r1.data[2][2]));
    #|   return dist<=s2+m1+m2;
    #| }else if(s2==0.0f){
    #|   float dist=wp::dot(wp::sub(x1,x2),wp::vec3f(r2.data[0][2],r2.data[1][2],r2.data[2][2]));
    #|   return dist<=s1+m1+m2;
    #| }
    #| return true;
    #|}
    #|static __device__ bool mr_mjw_sphere(float s1,float s2,float m1,float m2,wp::vec3f x1,wp::vec3f x2){
    #| float bound=s1+s2+m1+m2;
    #| wp::vec3f dif=wp::sub(x2,x1);
    #| return wp::dot(dif,dif)<=bound*bound;
    #|}
    #|static __device__ bool mr_mjw_aabb(wp::vec3f c1,wp::vec3f c2,wp::vec3f s1,wp::vec3f s2,float m1,float m2,wp::vec3f x1,wp::vec3f x2,wp::mat33f r1,wp::mat33f r2){
    #| c1=wp::add(wp::mul(r1,c1),x1);c2=wp::add(wp::mul(r2,c2),x2);
    #| float margin=m1+m2;
    #| float hi1[3]={-1.0e10f,-1.0e10f,-1.0e10f},lo1[3]={1.0e10f,1.0e10f,1.0e10f};
    #| float hi2[3]={-1.0e10f,-1.0e10f,-1.0e10f},lo2[3]={1.0e10f,1.0e10f,1.0e10f};
    #| const float sign[2]={-1.0f,1.0f};
    #| for(int a=0;a<2;a++)for(int b=0;b<2;b++)for(int c=0;c<2;c++){
    #|   wp::vec3f p1=wp::mul(r1,wp::vec3f(sign[a]*s1[0],sign[b]*s1[1],sign[c]*s1[2]));
    #|   wp::vec3f p2=wp::mul(r2,wp::vec3f(sign[a]*s2[0],sign[b]*s2[1],sign[c]*s2[2]));
    #|   for(int axis=0;axis<3;axis++)if(p1[axis]>hi1[axis])hi1[axis]=p1[axis];
    #|   for(int axis=0;axis<3;axis++)if(p1[axis]<lo1[axis])lo1[axis]=p1[axis];
    #|   for(int axis=0;axis<3;axis++)if(p2[axis]>hi2[axis])hi2[axis]=p2[axis];
    #|   for(int axis=0;axis<3;axis++)if(p2[axis]<lo2[axis])lo2[axis]=p2[axis];
    #| }
    #| for(int axis=0;axis<3;axis++)if(c1[axis]+hi1[axis]+margin<c2[axis]+lo2[axis])return false;
    #| for(int axis=0;axis<3;axis++)if(c2[axis]+hi2[axis]+margin<c1[axis]+lo1[axis])return false;
    #| return true;
    #|}
  )
}

///|
fn nxn_body(r : Request) -> String {
  let mesh_gate = if r.ngeom_dataid > 1 {
    "int did=i%\{r.ngeom_dataid};\nif((t1==7 && wp::index(geom_dataid,did,g1)<0)||(t2==7 && wp::index(geom_dataid,did,g2)<0))continue;\n"
  } else {
    ""
  }
  let start =
    #|wp::vec2i geom=wp::index(nxn_geom_pair,j);
    #|int g1=geom[0],g2=geom[1];
    #|int t1=wp::index(geom_type,g1),t2=wp::index(geom_type,g2);
  let reads =
    #|wp::vec3f c1=wp::index(geom_aabb,aid,g1,0),c2=wp::index(geom_aabb,aid,g2,0);
    #|wp::vec3f s1=wp::index(geom_aabb,aid,g1,1),s2=wp::index(geom_aabb,aid,g2,1);
    #|float rb1=wp::index(geom_rbound,rid,g1),rb2=wp::index(geom_rbound,rid,g2);
    #|float m1=wp::index(geom_margin,mid,g1)+wp::index(geom_gap,gid,g1);
    #|float m2=wp::index(geom_margin,mid,g2)+wp::index(geom_gap,gid,g2);
    #|wp::vec3f x1=wp::index(geom_xpos_in,i,g1),x2=wp::index(geom_xpos_in,i,g2);
    #|wp::mat33f r1=wp::index(geom_xmat_in,i,g1),r2=wp::index(geom_xmat_in,i,g2);
    #|bool keep=true;
    #|if(rb1==0.0f||rb2==0.0f){
  let plane = if (r.filter_bits & 1) != 0 {
    "keep=mr_mjw_plane(rb1,rb2,m1,m2,x1,x2,r1,r2);\n"
  } else {
    ""
  }
  let sphere = if (r.filter_bits & 2) != 0 {
    "if(!mr_mjw_sphere(rb1,rb2,m1,m2,x1,x2))keep=false;\n"
  } else {
    ""
  }
  let aabb = if (r.filter_bits & 4) != 0 {
    "if(keep&&!mr_mjw_aabb(c1,c2,s1,s2,m1,m2,x1,x2,r1,r2))keep=false;\n"
  } else {
    ""
  }
  let finish =
    #|}
    #|wp::vec2i pairid=wp::index(nxn_pairid,j);
    #|if(keep||pairid[1]>=0){
    #| int cid=wp::atomic_add(ncollision_out,0,1);
    #| if(cid>=naconmax_in)continue;
    #| wp::vec2i pair=t1>t2?wp::vec2i(g2,g1):wp::vec2i(g1,g2);
    #| wp::index(collision_pair_out,cid)=pair;
    #| wp::index(collision_pairid_out,cid)=pairid;
    #| wp::index(collision_worldid_out,cid)=i;
    #|}
  start +
  "\n" +
  mesh_gate +
  "int aid=i%\{r.ngeom_aabb},rid=i%\{r.ngeom_rbound},mid=i%\{r.ngeom_margin},gid=i%\{r.ngeom_gap};\n" +
  reads +
  "\n" +
  plane +
  "}else{\n" +
  sphere +
  aabb +
  finish
}
