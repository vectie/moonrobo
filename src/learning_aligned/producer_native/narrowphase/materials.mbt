///|
// Actual collision_core material branch; safe_div uses mjMINVAL only for a
// zero denominator. Explicit pair material and sensor-only pair IDs stay distinct.
fn material_body() -> String {
  (
    #|float margin,gap,adhesion;int condim;mr_vec5f friction,solimp;wp::vec2f solref,solreffriction;
    #|int pair=pairid[0];
    #|if(pair>=0){
    #| margin=wp::index(pair_margin,world%pair_margin.shape[0],pair);
    #| gap=wp::index(pair_gap,world%pair_gap.shape[0],pair);
    #| condim=wp::index(pair_dim,pair);
    #| friction=wp::index(pair_friction,world%pair_friction.shape[0],pair);
    #| solref=wp::index(pair_solref,world%pair_solref.shape[0],pair);
    #| solreffriction=wp::index(pair_solreffriction,world%pair_solreffriction.shape[0],pair);
    #| solimp=wp::index(pair_solimp,world%pair_solimp.shape[0],pair);
    #| adhesion=wp::index(pair_adhesion,world%pair_adhesion.shape[0],pair);
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
    #|   float denominator=sm1+sm2;mix=sm1/(denominator!=0.0f?denominator:1.0e-15f);
    #|   if(sm1<1.0e-15f&&sm2<1.0e-15f)mix=0.5f;
    #|   if(sm1<1.0e-15f&&sm2>=1.0e-15f)mix=0.0f;
    #|   if(sm1>=1.0e-15f&&sm2<1.0e-15f)mix=1.0f;
    #|   condim=wp::max(d1,d2);maxfriction=wp::max(wp::index(geom_friction,fid,g1),wp::index(geom_friction,fid,g2));adhesion=a1+a2;
    #| }
    #| friction=mr_vec5f();friction[0]=maxfriction[0];friction[1]=maxfriction[0];friction[2]=maxfriction[1];friction[3]=maxfriction[2];friction[4]=maxfriction[2];
    #| wp::vec2f ref1=wp::index(geom_solref,rid,g1),ref2=wp::index(geom_solref,rid,g2);
    #| if(ref1[0]>0.0f&&ref2[0]>0.0f)solref=wp::add(wp::mul(ref1,mix),wp::mul(ref2,1.0f-mix));else solref=wp::min(ref1,ref2);
    #| solreffriction=wp::vec2f(0.0f);
    #| solimp=wp::add(wp::mul(wp::index(geom_solimp,iid,g1),mix),wp::mul(wp::index(geom_solimp,iid,g2),1.0f-mix));
    #|}
    #|for(int f=0;f<5;f++)friction[f]=wp::max(1.0e-5f,friction[f]);
  )
}

///|
fn contact_write(capacity : Int32) -> String {
  let head =
    #|bool active=(c.dist<margin)||((adhesion!=0.0f)&&(c.dist<margin+gap));
    #|bool detected=c.dist<margin+gap;
    #|int dimension=(adhesion!=0.0f&&c.dist>=margin)?1:condim;
    #|if((pairid[0]==-2||!detected)&&pairid[1]==-1)continue;
    #|int flags=0;if(pairid[0]>=-1&&detected)flags|=1;if(pairid[1]>=0)flags|=2;
    #|int cid=wp::atomic_add(nacon_out,0,1);
  let writes =
    #| wp::index(contact_dist_out,cid)=c.dist;wp::index(contact_pos_out,cid)=c.pos;wp::index(contact_frame_out,cid)=c.frame;
    #| wp::index(contact_geom_out,cid)=geoms;wp::index(contact_worldid_out,cid)=world;
    #| wp::index(contact_includemargin_out,cid)=margin;wp::index(contact_dim_out,cid)=dimension;
    #| wp::index(contact_friction_out,cid)=friction;wp::index(contact_solref_out,cid)=solref;
    #| wp::index(contact_solreffriction_out,cid)=solreffriction;wp::index(contact_solimp_out,cid)=solimp;
    #| wp::index(contact_adhesion_out,cid)=adhesion;wp::index(contact_type_out,cid)=flags;wp::index(contact_geomcollisionid_out,cid)=c.id;
    #| for(int slot=0;slot<contact_efc_address_out.shape[1];slot++)wp::index(contact_efc_address_out,cid,slot)=-1;
    #|}
    #|(void)active;
  head +
  "\nif(cid<0||cid>=\{capacity}){wp::atomic_add(rejected_out,1,1);continue;}\n{\n" +
  writes
}
