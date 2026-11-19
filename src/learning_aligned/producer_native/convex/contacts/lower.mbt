///|
fn parameters() -> Array[Parameter] {
  let result = [
    parameter("geom_type", "int32", 1, "input"),
    parameter("geom_condim", "int32", 1, "input"),
    parameter("geom_priority", "int32", 1, "input"),
    parameter("geom_solmix", "float32", 2, "input"),
    parameter("geom_solref", "vec2f", 2, "input"),
    parameter("geom_solimp", "vec5f", 2, "input"),
    parameter("geom_size", "vec3f", 2, "input"),
    parameter("geom_friction", "vec3f", 2, "input"),
    parameter("geom_margin", "float32", 2, "input"),
    parameter("geom_gap", "float32", 2, "input"),
    parameter("geom_adhesion", "float32", 2, "input"),
    parameter("pair_dim", "int32", 1, "input"),
    parameter("pair_solref", "vec2f", 2, "input"),
    parameter("pair_solreffriction", "vec2f", 2, "input"),
    parameter("pair_solimp", "vec5f", 2, "input"),
    parameter("pair_margin", "float32", 2, "input"),
    parameter("pair_gap", "float32", 2, "input"),
    parameter("pair_adhesion", "float32", 2, "input"),
    parameter("pair_friction", "vec5f", 2, "input"),
    parameter("geom_xpos_in", "vec3f", 2, "input"),
    parameter("geom_xmat_in", "mat33f", 2, "input"),
    parameter("ncollision_in", "int32", 1, "input"),
    parameter("collision_pair_in", "vec2i", 1, "input"),
    parameter("collision_pairid_in", "vec2i", 1, "input"),
    parameter("collision_worldid_in", "int32", 1, "input"),
    parameter("contact_dist_out", "float32", 1, "output"),
    parameter("contact_pos_out", "vec3f", 1, "output"),
    parameter("contact_frame_out", "mat33f", 1, "output"),
    parameter("contact_includemargin_out", "float32", 1, "output"),
    parameter("contact_friction_out", "vec5f", 1, "output"),
    parameter("contact_solref_out", "vec2f", 1, "output"),
    parameter("contact_solreffriction_out", "vec2f", 1, "output"),
    parameter("contact_solimp_out", "vec5f", 1, "output"),
    parameter("contact_dim_out", "int32", 1, "output"),
    parameter("contact_geom_out", "vec2i", 1, "output"),
    parameter("contact_efc_address_out", "int32", 2, "output"),
    parameter("contact_worldid_out", "int32", 1, "output"),
    parameter("contact_type_out", "int32", 1, "output"),
    parameter("contact_geomcollisionid_out", "int32", 1, "output"),
    parameter("contact_adhesion_out", "float32", 1, "output"),
    parameter("nacon_out", "int32", 1, "inout"),
    parameter("rejected_out", "int32", 1, "inout"),
    parameter("geom_vertexadr", "int32", 1, "input"),
    parameter("geom_vertexnum", "int32", 1, "input"),
    parameter("geom_polyadr", "int32", 1, "input"),
    parameter("geom_polynum", "int32", 1, "input"),
    parameter("mesh_vertex", "vec3f", 1, "input"),
    parameter("mesh_polynormal", "vec3f", 1, "input"),
    parameter("mesh_polyvertadr", "int32", 1, "input"),
    parameter("mesh_polyvertnum", "int32", 1, "input"),
    parameter("mesh_polyvert", "int32", 1, "input"),
    parameter("mesh_polymapadr", "int32", 1, "input"),
    parameter("mesh_polymapnum", "int32", 1, "input"),
    parameter("mesh_polymap", "int32", 1, "input"),
    parameter("geom_graphadr", "int32", 1, "input"),
    parameter("mesh_graph", "int32", 1, "input"),
    parameter("geom_hfieldid", "int32", 2, "input"),
    parameter("geom_rbound", "float32", 2, "input"),
    parameter("hfield_size", "vec4f", 1, "input"),
    parameter("hfield_nrow", "int32", 1, "input"),
    parameter("hfield_ncol", "int32", 1, "input"),
    parameter("hfield_adr", "int32", 1, "input"),
    parameter("hfield_data", "float32", 1, "input"),
    parameter("epa_vert_in", "vec3f", 2, "scratch"),
    parameter("epa_vert_index_in", "int32", 2, "scratch"),
    parameter("epa_face_in", "int32", 2, "scratch"),
    parameter("epa_pr_in", "vec3f", 2, "scratch"),
    parameter("epa_norm2_in", "float32", 2, "scratch"),
    parameter("epa_horizon_in", "int32", 2, "scratch"),
  ]
  result
}

///|
fn scratch_columns(r : Request, name : String) -> Int32 {
  if name == "epa_vert_in" || name == "epa_vert_index_in" {
    2 * r.epa_vertices
  } else if name == "epa_horizon_in" {
    r.epa_horizon
  } else {
    r.epa_faces
  }
}

///|
fn mesh_capacity(r : Request, name : String) -> Int32 {
  if name == "mesh_vertex" ||
    name == "mesh_polymapadr" ||
    name == "mesh_polymapnum" {
    r.vertex_capacity
  } else if name == "mesh_polyvert" {
    r.polygon_vertex_capacity
  } else if name == "mesh_polymap" {
    r.polygon_map_capacity
  } else if name == "mesh_graph" {
    r.graph_capacity
  } else {
    r.polygon_capacity
  }
}

///|
fn shape_gate(r : Request, p : Parameter) -> String {
  let n = p.name
  let req = ["\{n}.ndim!=\{p.rank}"]
  for axis in 0..<p.rank {
    req.push(
      "\{n}.shape[\{axis}]<0||\{n}.strides[\{axis}]<0||(\{n}.strides[\{axis}]%4)!=0",
    )
  }
  req.push(
    "(" +
    Array::makei(p.rank, i => "\{n}.shape[\{i}]>0").join("&&") +
    ")&&!\{n}.data",
  )
  if n.has_prefix("geom_") {
    if p.rank == 1 {
      req.push("\{n}.shape[0]<\{r.ngeom}")
    } else {
      let worlds = if n == "geom_xpos_in" || n == "geom_xmat_in" {
        r.nworld
      } else {
        1
      }
      req.push("\{n}.shape[0]<\{worlds}||\{n}.shape[1]<\{r.ngeom}")
    }
  } else if n.has_prefix("collision_") {
    req.push("\{n}.shape[0]<\{r.candidate_capacity}")
  } else if n.has_prefix("contact_") {
    req.push("\{n}.shape[0]<\{r.contact_capacity}")
    if p.rank == 2 {
      req.push("\{n}.shape[1]!=\{r.efc_slots}")
    }
  } else if n.has_prefix("epa_") {
    req.push(
      "\{n}.shape[0]!=\{r.candidate_capacity}||\{n}.shape[1]!=\{scratch_columns(r,n)}",
    )
  } else if n.has_prefix("hfield_") {
    let count = if n == "hfield_data" {
      r.hfield_data_capacity
    } else {
      r.hfield_capacity
    }
    req.push("\{n}.shape[0]<\{count}")
  } else if n.has_prefix("mesh_") {
    req.push("\{n}.shape[0]<\{mesh_capacity(r,n)}")
  } else if n == "nacon_out" || n == "ncollision_in" {
    req.push("\{n}.shape[0]<1")
  }
  "(" + req.join("||") + ")"
}

///|
fn frame_source() -> String {
  (
    #|using mr_vec5f=wp::vec_t<5,float>;
    #|struct mr_contact{float dist;wp::vec3f pos;wp::mat33f frame;int id;};
    #|static __device__ wp::mat33f mr_frame(wp::vec3f a){
    #| a=wp::normalize(a);wp::vec3f b=(-0.5f<a[1]&&a[1]<0.5f)?wp::vec3f(0.0f,1.0f,0.0f):wp::vec3f(0.0f,0.0f,1.0f);
    #| b=wp::normalize(wp::sub(b,wp::mul(a,wp::dot(a,b))));if(wp::length(a)==0.0f)b=wp::vec3f(0.0f);wp::vec3f c=wp::cross(a,b);
    #| return wp::mat33f(a[0],a[1],a[2],b[0],b[1],b[2],c[0],c[1],c[2]);
    #|}
  )
}

///|
/// Actual GJK/EPA/manifold/material/contact CUDA program. Compilation and GPU
/// execution are separate explicit APIs, never triggered by lowering/checking.
pub fn lower(request : Request) -> Lowered raise {
  validate_request(request)
  let entry : Entry = {
    forward: "mr_mjw_native_convex_contacts",
    launch_shape: [request.candidate_capacity],
    parameters: parameters(),
  }
  let signature = entry.parameters.map(p => p.c_type + " " + p.name).join(",")
  let gates = entry.parameters
    .filter(p => p.name != "rejected_out")
    .map(p => shape_gate(request, p))
    .join("||")
  let begin = "extern \"C\" __global__ void " +
    entry.forward +
    "(wp::launch_bounds_t<1> dim," +
    signature +
    "){\n" +
    "if(rejected_out.ndim!=1||rejected_out.shape[0]!=8||rejected_out.strides[0]!=4||!rejected_out.data)return;\n" +
    "if(dim.size!=size_t(\{request.candidate_capacity})||dim.shape[0]!=\{request.candidate_capacity}||dim.coord_mult!=1){if(blockIdx.x==0&&threadIdx.x==0)wp::atomic_add(rejected_out,1,1);return;}\n" +
    "for(size_t tid=size_t(blockIdx.x)*blockDim.x+threadIdx.x;tid<dim.size;tid+=size_t(blockDim.x)*gridDim.x){\n" +
    "if(" +
    gates +
    "){if(tid==0)wp::atomic_add(rejected_out,1,1);continue;}\n" +
    "int candidate_count=wp::index(ncollision_in,0);if(candidate_count<0||candidate_count>\{request.candidate_capacity}||wp::index(nacon_out,0)<0){if(tid==0)wp::atomic_add(rejected_out,1,1);continue;}if(tid>=size_t(candidate_count))continue;\n"
  let reads =
    #|int id=int(tid);wp::vec2i geoms=wp::index(collision_pair_in,id),pairid=wp::index(collision_pairid_in,id);int world=wp::index(collision_worldid_in,id),g1=geoms[0],g2=geoms[1];
  let build_geoms =
    #|mr_geom a{},b{};a.type=wp::index(geom_type,g1);b.type=wp::index(geom_type,g2);
    #|if((a.type!=0&&!mr_supported(a.type))||b.type<2||!mr_supported(b.type)){wp::atomic_add(rejected_out,0,1);continue;}
    #|a.index=-1;b.index=-1;a.pos=wp::index(geom_xpos_in,world,g1);b.pos=wp::index(geom_xpos_in,world,g2);a.rot=wp::index(geom_xmat_in,world,g1);b.rot=wp::index(geom_xmat_in,world,g2);
    #|int sizeworld=world%geom_size.shape[0];a.size=wp::index(geom_size,sizeworld,g1);b.size=wp::index(geom_size,sizeworld,g2);a.margin=margin;b.margin=margin;
    #|a.vertadr=wp::index(geom_vertexadr,g1);b.vertadr=wp::index(geom_vertexadr,g2);a.vertnum=wp::index(geom_vertexnum,g1);b.vertnum=wp::index(geom_vertexnum,g2);
    #|a.polyadr=wp::index(geom_polyadr,g1);b.polyadr=wp::index(geom_polyadr,g2);a.polynum=wp::index(geom_polynum,g1);b.polynum=wp::index(geom_polynum,g2);
    #|a.graphadr=wp::index(geom_graphadr,g1);b.graphadr=wp::index(geom_graphadr,g2);a.graph=mesh_graph;b.graph=mesh_graph;
    #|a.vert=mesh_vertex;b.vert=mesh_vertex;a.polynormal=mesh_polynormal;b.polynormal=mesh_polynormal;
    #|a.polyvertadr=mesh_polyvertadr;b.polyvertadr=mesh_polyvertadr;a.polyvertnum=mesh_polyvertnum;b.polyvertnum=mesh_polyvertnum;a.polyvert=mesh_polyvert;b.polyvert=mesh_polyvert;
    #|a.polymapadr=mesh_polymapadr;b.polymapadr=mesh_polymapadr;a.polymapnum=mesh_polymapnum;b.polymapnum=mesh_polymapnum;a.polymap=mesh_polymap;b.polymap=mesh_polymap;
  let mesh_guard = "if((a.type==7&&(a.vertadr<0||a.vertnum<=0||a.vertadr>\{request.vertex_capacity}||a.vertnum>\{request.vertex_capacity}-a.vertadr))||(b.type==7&&(b.vertadr<0||b.vertnum<=0||b.vertadr>\{request.vertex_capacity}||b.vertnum>\{request.vertex_capacity}-b.vertadr))){wp::atomic_add(rejected_out,1,1);continue;}\n"
  let finite_material =
    #|bool validmaterial=mr_finite(margin)&&mr_finite(gap)&&mr_finite(adhesion)&&(condim==1||condim==3||condim==4||condim==6);
    #|for(int f=0;f<5;f++)validmaterial=validmaterial&&mr_finite(friction[f])&&mr_finite(solimp[f]);
    #|for(int f=0;f<2;f++)validmaterial=validmaterial&&mr_finite(solref[f])&&mr_finite(solreffriction[f]);
    #|mr_geom checkplane=a;if(a.type==0){checkplane.type=6;checkplane.size=wp::vec3f(1.0f);}
    #|if(!validmaterial||!mr_valid_geom(checkplane)||!mr_valid_geom(b)){wp::atomic_add(rejected_out,7,1);continue;}
  let topology_guard = "if((a.type==7&&a.polyadr>=0&&(a.polynum<=0||a.polyadr>\{request.polygon_capacity}||a.polynum>\{request.polygon_capacity}-a.polyadr))||(b.type==7&&b.polyadr>=0&&(b.polynum<=0||b.polyadr>\{request.polygon_capacity}||b.polynum>\{request.polygon_capacity}-b.polyadr))){wp::atomic_add(rejected_out,6,1);continue;}\n" +
    "if((a.type==7&&a.graphadr>=\{request.graph_capacity})||(b.type==7&&b.graphadr>=\{request.graph_capacity})||!mr_valid_graph(a)||!mr_valid_graph(b)){wp::atomic_add(rejected_out,1,1);continue;}\n" +
    "if(!mr_valid_mesh_topology(a,\{request.max_polygon_vertices})||!mr_valid_mesh_topology(b,\{request.max_polygon_vertices})){wp::atomic_add(rejected_out,6,1);continue;}\n"
  let scratch =
    #|mr_polytope pt;pt.vert=wp::view(epa_vert_in,id);pt.vert_index=wp::view(epa_vert_index_in,id);pt.face=wp::view(epa_face_in,id);pt.face_pr=wp::view(epa_pr_in,id);pt.face_norm2=wp::view(epa_norm2_in,id);pt.horizon=wp::view(epa_horizon_in,id);
    #|pt.nvert=0;pt.nface=0;pt.nhorizon=0;pt.status=0;pt.failure=0;pt.center=wp::vec3f(0.0f);
  let plane_begin =
    #|if(a.type==0){mr_plane_result surface=mr_plane_contacts(a,b);if(surface.failure!=0){wp::atomic_add(rejected_out,surface.failure>=1&&surface.failure<=8?surface.failure-1:7,1);continue;}
    #|if(surface.count<0||surface.count>8){wp::atomic_add(rejected_out,7,1);continue;}for(int slot=0;slot<surface.count;slot++){mr_contact c;c.id=slot;c.dist=surface.dist[slot];c.pos=surface.pos[slot];c.frame=surface.frame;
  let surface_check =
    #|bool validcontact=mr_finite(c.dist)&&mr_finite3(c.pos);for(int r=0;r<3;r++)for(int col=0;col<3;col++)validcontact=validcontact&&mr_finite(c.frame.data[r][col]);if(!validcontact){wp::atomic_add(rejected_out,7,1);continue;}
  let plane_branch = plane_begin +
    "\n" +
    surface_check +
    "\n" +
    contact_write(request.contact_capacity) +
    "\n}continue;}\n"
  let hfield_begin = "if(a.type==1){int hfid=wp::index(geom_hfieldid,world%geom_hfieldid.shape[0],g1);if(hfid<0||hfid>=\{request.hfield_capacity}){wp::atomic_add(rejected_out,1,1);continue;}\n" +
    "mr_heightfield hf;hf.size=wp::index(hfield_size,hfid);hf.nrow=wp::index(hfield_nrow,hfid);hf.ncol=wp::index(hfield_ncol,hfid);hf.adr=wp::index(hfield_adr,hfid);hf.data=hfield_data;\n" +
    "float filter_margin=wp::index(geom_margin,world%geom_margin.shape[0],g1)+wp::index(geom_margin,world%geom_margin.shape[0],g2),rbound=wp::index(geom_rbound,world%geom_rbound.shape[0],g2);\n" +
    "mr_hfield_result surface=mr_hfield(float(\{request.tolerance}),\{request.gjk_iterations},\{request.epa_iterations},a,b,hf,pt,margin,gap,filter_margin,rbound);\n" +
    "if(surface.failure!=0){wp::atomic_add(rejected_out,surface.failure>=1&&surface.failure<=8?surface.failure-1:7,1);continue;}\n" +
    "if(surface.count<0||surface.count>4){wp::atomic_add(rejected_out,7,1);continue;}for(int slot=0;slot<surface.count;slot++){mr_contact c;c.id=slot;c.dist=surface.dist[slot];c.pos=surface.pos[slot];c.frame=mr_frame(surface.normal[slot]);\n"
  let hfield_branch = hfield_begin +
    surface_check +
    "\n" +
    contact_write(request.contact_capacity) +
    "\n}continue;}\n"
  let rigid_origin = "wp::vec3f origin=a.pos;a.pos=wp::vec3f(0.0f);b.pos=wp::sub(b.pos,origin);bool sensor=pairid[1]>=0;float cutoff=sensor?1.0e32f:gap;\n"
  let run = "mr_ccd_result result=mr_ccd(float(\{request.tolerance}),cutoff,\{request.gjk_iterations},\{request.epa_iterations},a,b,pt," +
    (if request.use_multiccd { "true" } else { "false" }) +
    ");\n" +
    "if(result.failure!=0){int reason=(result.failure>=1&&result.failure<=8)?result.failure-1:7;wp::atomic_add(rejected_out,reason,1);continue;}\n"
  let publish =
    #|if(result.count<0||result.count>4||!mr_finite(result.dist)){wp::atomic_add(rejected_out,7,1);continue;}if(result.count==0)continue;
    #|if(result.dist>=gap&&!sensor)continue;float dist=result.dist+margin;
    #|wp::mat33f frame=mr_frame(dist<=margin?wp::sub(result.w1[0],result.w2[0]):wp::sub(result.w2[0],result.w1[0]));
    #|bool validexport=mr_finite(dist);for(int r=0;r<3;r++)for(int c=0;c<3;c++)validexport=validexport&&mr_finite(frame.data[r][c]);
    #|for(int slot=0;slot<result.count;slot++)validexport=validexport&&mr_finite3(result.w1[slot])&&mr_finite3(result.w2[slot])&&(result.count==1||mr_finite(result.dists[slot]));
    #|if(!validexport){wp::atomic_add(rejected_out,7,1);continue;}
    #|for(int slot=0;slot<result.count;slot++){
    #|mr_contact c;c.dist=result.count>1?result.dists[slot]:dist;c.pos=wp::add(wp::mul(wp::add(result.w1[slot],result.w2[slot]),0.5f),origin);c.frame=frame;c.id=slot;
    #|if(!mr_finite3(c.pos)){wp::atomic_add(rejected_out,7,1);continue;}
  let source = "// Copyright 2025-2026 The Newton Developers. SPDX-License-Identifier: Apache-2.0\n#define WP_NO_CRT\n#include \"builtin.h\"\nstatic_assert(sizeof(wp::array_t<float>)==56,\"Warp array ABI\");\n" +
    frame_source() +
    "\n" +
    core_source(request) +
    "\n" +
    plane_source() +
    "\n" +
    begin +
    reads +
    "\n" +
    material_guards(request) +
    material_body() +
    "\n" +
    build_geoms +
    "\n" +
    mesh_guard +
    finite_material +
    "\n" +
    topology_guard +
    scratch +
    "\n" +
    plane_branch +
    hfield_branch +
    rigid_origin +
    "\n" +
    run +
    publish +
    "\n" +
    contact_write(request.contact_capacity) +
    "\n}\n}\n}\n"
  let source_sha256 = @artifacts.sha256(@utf8.encode(source))
  let identity : Json = {
    "format": "moonrobo-native-convex-contacts-specialization-v1",
    "request": Json(request),
    "entry": Json(entry),
    "source_sha256": Json(source_sha256),
  }
  {
    source,
    source_sha256,
    specialization_sha256: @artifacts.sha256(@utf8.encode(identity.stringify())),
    request,
    entry,
  }
}
