///|
/// The contact module owns a new complete CCD helper chain. The original
/// distance-only package and its generated source/interface remain unchanged.
fn core_source(request : Request) -> String {
  "#define MR_POLY_MAX \{request.max_polygon_vertices}\n#define MR_EPA_VERTICES \{request.epa_vertices}\n#define MR_EPA_FACES \{request.epa_faces}\n#define MR_EPA_HORIZON \{request.epa_horizon}\n" +
  simplex_source() +
  "\n" +
  support_source() +
  "\n" +
  gjk_source() +
  "\n" +
  epa_source() +
  "\n" +
  manifold_source() +
  "\n" +
  ccd_source() +
  "\n" +
  hfield_source()
}

///|
fn ccd_source() -> String {
  (
    #|struct mr_ccd_result {float dist;wp::vec3f w1[4],w2[4];float dists[4];int count,failure,gjk_iterations,epa_iterations;};
    #|static __device__ mr_ccd_result mr_ccd_from(float tol,float cutoff,int gjkiters,int epaiters,mr_geom g1,mr_geom g2,mr_polytope& pt,bool use_multiccd,wp::vec3f start1,wp::vec3f start2){
    #| mr_ccd_result out;out.dist=1.0e30f;out.count=1;out.failure=0;out.gjk_iterations=0;out.epa_iterations=0;for(int i=0;i<4;i++){out.w1[i]=wp::vec3f(0.0f);out.w2[i]=wp::vec3f(0.0f);out.dists[i]=0.0f;}
    #| pt.status=0;pt.failure=0;pt.nface=0;pt.nvert=0;pt.nhorizon=0;pt.center=wp::vec3f(0.0f);
    #| mr_phase_result phase=mr_phase_from(tol,cutoff,gjkiters,g1,g2,start1,start2);out.gjk_iterations=phase.gjk.iterations;if(phase.status==11||phase.status==13){out.failure=3;return out;}
    #| out.dist=phase.dist;out.w1[0]=phase.x1;out.w2[0]=phase.x2;if(!phase.needs_epa)return out;
    #| g1=phase.geom1;g2=phase.geom2;mr_gjk_result result=phase.gjk;
    #| if(result.dim==2)mr_polytope2(pt,result,g1,g2);else if(result.dim==4)mr_polytope4(pt,result);if(pt.failure){out.failure=pt.failure;return out;}if(result.dim==3)mr_polytope3(pt,result,g1,g2);if(pt.failure){out.failure=pt.failure;return out;}
    #| // The original epa_phase boundary statuses return the GJK witness, not
    #| // an invented penetration. Keep that source branch and no manifold idx.
    #| if(pt.status!=0)return out;
    #| mr_epa_result epa=mr_epa(tol,epaiters,pt,g1,g2);out.epa_iterations=epa.iterations;if(pt.failure){out.failure=pt.failure;return out;}if(epa.idx<0){out.failure=6;return out;}
    #| out.dist=epa.dist;out.w1[0]=epa.x1;out.w2[0]=epa.x2;int idx=epa.idx;
    #| if(g1.margin!=0.0f||g2.margin!=0.0f)idx=-1;
    #| bool types=(g1.type==6||g1.type==7||g1.type==5)&&(g2.type==6||g2.type==7||g2.type==5);
    #| if(!types)idx=-1;if(g1.type==7&&g1.polyadr<0)idx=-1;if(g2.type==7&&g2.polyadr<0)idx=-1;
    #| if((use_multiccd||(g1.type==6&&g2.type==6))&&idx>=0){mr_manifold_result m=mr_multicontact(pt,idx,epa.x1,epa.x2,g1,g2);if(m.failure){out.failure=m.failure;return out;}if(m.count>0){out.count=m.count;for(int i=0;i<m.count;i++){out.w1[i]=m.w1[i];out.w2[i]=m.w2[i];out.dists[i]=m.dists[i];}}}
    #| if(!mr_finite(out.dist)){out.failure=8;return out;}for(int i=0;i<out.count;i++)if(!mr_finite3(out.w1[i])||!mr_finite3(out.w2[i])||!mr_finite(out.dists[i]))out.failure=8;return out;
    #|}
    #|static __device__ mr_ccd_result mr_ccd(float tol,float cutoff,int gjkiters,int epaiters,mr_geom a,mr_geom b,mr_polytope& pt,bool multi){return mr_ccd_from(tol,cutoff,gjkiters,epaiters,a,b,pt,multi,a.pos,b.pos);}
  )
}
