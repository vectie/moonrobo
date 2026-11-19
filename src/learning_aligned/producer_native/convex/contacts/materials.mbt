///|
/// Pinned collision_core.py::contact_margin_gap/contact_material_params. The
/// caller validates IDs/batches before this code touches any material array.
fn material_body() -> String {
  (
    #|float margin,gap,adhesion;int condim;mr_vec5f friction,solimp;wp::vec2f solref,solreffriction;
    #|int pair=pairid[0];
    #|if(pair>=0){
    #| margin=wp::index(pair_margin,world%pair_margin.shape[0],pair);gap=wp::index(pair_gap,world%pair_gap.shape[0],pair);
    #| condim=wp::index(pair_dim,pair);friction=wp::index(pair_friction,world%pair_friction.shape[0],pair);
    #| solref=wp::index(pair_solref,world%pair_solref.shape[0],pair);solreffriction=wp::index(pair_solreffriction,world%pair_solreffriction.shape[0],pair);
    #| solimp=wp::index(pair_solimp,world%pair_solimp.shape[0],pair);adhesion=wp::index(pair_adhesion,world%pair_adhesion.shape[0],pair);
    #|}else{
    #| margin=wp::index(geom_margin,world%geom_margin.shape[0],g1)+wp::index(geom_margin,world%geom_margin.shape[0],g2);
    #| gap=wp::index(geom_gap,world%geom_gap.shape[0],g1)+wp::index(geom_gap,world%geom_gap.shape[0],g2);
    #| int sid=world%geom_solmix.shape[0],fid=world%geom_friction.shape[0],rid=world%geom_solref.shape[0],iid=world%geom_solimp.shape[0],aid=world%geom_adhesion.shape[0];
    #| float sm1=wp::index(geom_solmix,sid,g1),sm2=wp::index(geom_solmix,sid,g2),mix;
    #| int d1=wp::index(geom_condim,g1),d2=wp::index(geom_condim,g2),pr1=wp::index(geom_priority,g1),pr2=wp::index(geom_priority,g2);
    #| float a1=wp::index(geom_adhesion,aid,g1),a2=wp::index(geom_adhesion,aid,g2);wp::vec3f maxfriction;
    #| if(pr1>pr2){mix=1.0f;condim=d1;maxfriction=wp::index(geom_friction,fid,g1);adhesion=a1;}
    #| else if(pr2>pr1){mix=0.0f;condim=d2;maxfriction=wp::index(geom_friction,fid,g2);adhesion=a2;}
    #| else{
    #|  float denominator=sm1+sm2;mix=sm1/(denominator!=0.0f?denominator:1.0e-15f);
    #|  if(sm1<1.0e-15f&&sm2<1.0e-15f)mix=0.5f;
    #|  if(sm1<1.0e-15f&&sm2>=1.0e-15f)mix=0.0f;
    #|  if(sm1>=1.0e-15f&&sm2<1.0e-15f)mix=1.0f;
    #|  condim=wp::max(d1,d2);maxfriction=wp::max(wp::index(geom_friction,fid,g1),wp::index(geom_friction,fid,g2));adhesion=a1+a2;
    #| }
    #| friction=mr_vec5f();friction[0]=maxfriction[0];friction[1]=maxfriction[0];friction[2]=maxfriction[1];friction[3]=maxfriction[2];friction[4]=maxfriction[2];
    #| wp::vec2f ref1=wp::index(geom_solref,rid,g1),ref2=wp::index(geom_solref,rid,g2);
    #| if(ref1[0]>0.0f&&ref2[0]>0.0f)solref=wp::add(wp::mul(ref1,mix),wp::mul(ref2,1.0f-mix));else solref=wp::min(ref1,ref2);
    #| solreffriction=wp::vec2f(0.0f);solimp=wp::add(wp::mul(wp::index(geom_solimp,iid,g1),mix),wp::mul(wp::index(geom_solimp,iid,g2),1.0f-mix));
    #|}
    #|for(int f=0;f<5;f++)friction[f]=wp::max(1.0e-5f,friction[f]);
  )
}

///|
fn material_guards(request : Request) -> String {
  let names = [
    "pair_solref", "pair_solreffriction", "pair_solimp", "pair_margin", "pair_gap",
    "pair_adhesion", "pair_friction",
  ]
  let pair_gate = names
    .map(n => n + ".shape[0]<=0||pairid[0]>=" + n + ".shape[1]")
    .join("||")
  "if(world<0||world>=\{request.nworld}||g1<0||g1>=\{request.ngeom}||g2<0||g2>=\{request.ngeom}||g1==g2||pairid[0]<-2||pairid[1]<-1){wp::atomic_add(rejected_out,1,1);continue;}\n" +
  "if(pairid[0]>=0&&(pairid[0]>=pair_dim.shape[0]||" +
  pair_gate +
  ")){wp::atomic_add(rejected_out,1,1);continue;}\n"
}
