///|
/// Exact contact field/flag semantics, with additional fail-closed overflow
/// reporting. c.id is the local manifold slot, not the input candidate index.
fn contact_write(capacity : Int32) -> String {
  let head =
    #|bool active=(c.dist<margin)||((adhesion!=0.0f)&&(c.dist<margin+gap));
    #|bool detected=c.dist<margin+gap;int dimension=(adhesion!=0.0f&&c.dist>=margin)?1:condim;
    #|if((pairid[0]==-2||!detected)&&pairid[1]==-1)continue;
    #|int flags=0;if(pairid[0]>=-1&&detected)flags|=1;if(pairid[1]>=0)flags|=2;
    #|int cid=wp::atomic_add(nacon_out,0,1);
  let body =
    #|wp::index(contact_dist_out,cid)=c.dist;wp::index(contact_pos_out,cid)=c.pos;wp::index(contact_frame_out,cid)=c.frame;
    #|wp::index(contact_geom_out,cid)=geoms;wp::index(contact_worldid_out,cid)=world;wp::index(contact_includemargin_out,cid)=margin;
    #|wp::index(contact_dim_out,cid)=dimension;wp::index(contact_friction_out,cid)=friction;wp::index(contact_solref_out,cid)=solref;
    #|wp::index(contact_solreffriction_out,cid)=solreffriction;wp::index(contact_solimp_out,cid)=solimp;wp::index(contact_adhesion_out,cid)=adhesion;
    #|wp::index(contact_type_out,cid)=flags;wp::index(contact_geomcollisionid_out,cid)=c.id;
    #|for(int slot=0;slot<contact_efc_address_out.shape[1];slot++)wp::index(contact_efc_address_out,cid,slot)=-1;
    #|(void)active;
  head +
  "\nif(cid<0||cid>=\{capacity}){wp::atomic_add(rejected_out,1,1);continue;}\n" +
  body
}
