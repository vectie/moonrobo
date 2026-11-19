///|
fn parameters() -> Array[Parameter] {
  [
    parameter("geom_type", "int32", 1, "input"),
    parameter("geom_size", "vec3f", 2, "input"),
    parameter("geom_xpos_in", "vec3f", 2, "input"),
    parameter("geom_xmat_in", "mat33f", 2, "input"),
    parameter("geom_vertexadr", "int32", 1, "input"),
    parameter("geom_vertexnum", "int32", 1, "input"),
    parameter("mesh_vertex", "vec3f", 1, "input"),
    parameter("ncollision_in", "int32", 1, "input"),
    parameter("collision_pair_in", "vec2i", 1, "input"),
    parameter("collision_worldid_in", "int32", 1, "input"),
    parameter("collision_margin_in", "float32", 1, "input"),
    parameter("distance_out", "float32", 1, "output"),
    parameter("witness1_out", "vec3f", 1, "output"),
    parameter("witness2_out", "vec3f", 1, "output"),
    parameter("simplex_dim_out", "int32", 1, "output"),
    parameter("separated_out", "int32", 1, "output"),
    parameter("iterations_out", "int32", 1, "output"),
    parameter("status_out", "int32", 1, "output"),
    parameter("rejected_out", "int32", 1, "inout"),
  ]
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
  let nonempty = Array::makei(p.rank, i => "\{n}.shape[\{i}]>0").join("&&")
  req.push("(" + nonempty + ")&&!\{n}.data")
  if n.has_prefix("geom_") {
    if p.rank == 1 {
      req.push("\{n}.shape[0]<\{r.ngeom}")
    } else {
      let worlds = if n == "geom_size" { 1 } else { r.nworld }
      req.push("\{n}.shape[0]<\{worlds}||\{n}.shape[1]<\{r.ngeom}")
    }
  } else if n == "mesh_vertex" {
    req.push("\{n}.shape[0]<\{r.vertex_capacity}")
  } else if n == "ncollision_in" {
    req.push("\{n}.shape[0]<1")
  } else {
    req.push("\{n}.shape[0]<\{r.candidate_capacity}")
  }
  "(" + req.join("||") + ")"
}

///|
/// Emit real single-thread-per-candidate GJK/simplex/witness GPU computation.
/// Deep EPA, mesh cooking and final material contact publication are excluded.
pub fn lower(request : Request) -> Lowered raise {
  validate_request(request)
  let entry : Entry = {
    forward: "mr_mjw_native_convex_gjk",
    launch_shape: [request.candidate_capacity],
    parameters: parameters(),
  }
  let signature = entry.parameters.map(p => p.c_type + " " + p.name).join(",")
  let gates = entry.parameters
    .filter(p => p.name != "rejected_out")
    .map(p => shape_gate(request, p))
    .join("||")
  let prefix =
    #|// Copyright 2025 The Newton Developers. SPDX-License-Identifier: Apache-2.0
    #|#define WP_NO_CRT
    #|#include "builtin.h"
    #|static_assert(sizeof(wp::array_t<float>)==56,"Warp 1.17 64-bit array ABI required");
    #|static_assert(sizeof(wp::vec3f)==12&&sizeof(wp::mat33f)==36,"GJK element ABI required");
  let begin = "extern \"C\" __global__ void " +
    entry.forward +
    "(wp::launch_bounds_t<1> dim," +
    signature +
    "){\n" +
    "if(rejected_out.ndim!=1||rejected_out.shape[0]!=5||rejected_out.strides[0]!=4||!rejected_out.data)return;\n" +
    "if(dim.size!=size_t(\{request.candidate_capacity})||dim.shape[0]!=\{request.candidate_capacity}||dim.coord_mult!=1){if(blockIdx.x==0&&threadIdx.x==0)wp::atomic_add(rejected_out,2,1);return;}\n" +
    "for(size_t tid=size_t(blockIdx.x)*blockDim.x+threadIdx.x;tid<dim.size;tid+=size_t(blockDim.x)*gridDim.x){\n" +
    "if(dim.size!=size_t(\{request.candidate_capacity})||" +
    gates +
    "){if(tid==0)wp::atomic_add(rejected_out,2,1);continue;}\n"
  let init =
    #|int id=int(tid);wp::index(status_out,id)=0;wp::index(distance_out,id)=1.0e30f;wp::index(witness1_out,id)=wp::vec3f(0.0f);wp::index(witness2_out,id)=wp::vec3f(0.0f);wp::index(simplex_dim_out,id)=0;wp::index(separated_out,id)=0;wp::index(iterations_out,id)=0;
  let count = "int count=wp::index(ncollision_in,0);if(count<0||count>\{request.candidate_capacity}){if(tid==0)wp::atomic_add(rejected_out,2,1);continue;}if(id>=count)continue;\n"
  let reads =
    #|wp::vec2i pair=wp::index(collision_pair_in,id);int world=wp::index(collision_worldid_in,id),a=pair[0],b=pair[1];
  let index_gate = "if(world<0||world>=\{request.nworld}||a<0||a>=\{request.ngeom}||b<0||b>=\{request.ngeom}||a==b){wp::index(status_out,id)=12;wp::atomic_add(rejected_out,2,1);continue;}\n"
  let geoms =
    #|mr_geom g1,g2;g1.type=wp::index(geom_type,a);g2.type=wp::index(geom_type,b);
    #|if(!mr_supported(g1.type)||!mr_supported(g2.type)){wp::index(status_out,id)=14;wp::atomic_add(rejected_out,4,1);continue;}
    #|g1.index=-1;g2.index=-1;g1.vert=mesh_vertex;g2.vert=mesh_vertex;
    #|g1.vertadr=wp::index(geom_vertexadr,a);g2.vertadr=wp::index(geom_vertexadr,b);g1.vertnum=wp::index(geom_vertexnum,a);g2.vertnum=wp::index(geom_vertexnum,b);
  let mesh_gate = "if((g1.type==7&&(g1.vertadr<0||g1.vertnum<=0||g1.vertadr>\{request.vertex_capacity}||g1.vertnum>\{request.vertex_capacity}-g1.vertadr))||(g2.type==7&&(g2.vertadr<0||g2.vertnum<=0||g2.vertadr>\{request.vertex_capacity}||g2.vertnum>\{request.vertex_capacity}-g2.vertadr))){wp::index(status_out,id)=12;wp::atomic_add(rejected_out,2,1);continue;}\n"
  let pose =
    #|g1.pos=wp::index(geom_xpos_in,world,a);g2.pos=wp::index(geom_xpos_in,world,b);g1.rot=wp::index(geom_xmat_in,world,a);g2.rot=wp::index(geom_xmat_in,world,b);
    #|int sid=world%geom_size.shape[0];g1.size=wp::index(geom_size,sid,a);g2.size=wp::index(geom_size,sid,b);float margin=wp::index(collision_margin_in,id);g1.margin=margin;g2.margin=margin;
    #|if(!mr_valid_geom(g1)||!mr_valid_geom(g2)){wp::index(status_out,id)=13;wp::atomic_add(rejected_out,3,1);continue;}
    #|wp::vec3f origin=g1.pos;g1.pos=wp::vec3f(0.0f);g2.pos=wp::sub(g2.pos,origin);
  let run = "mr_phase_result result=mr_phase(float(\{request.tolerance}),float(\{request.cutoff}),\{request.gjk_iterations},g1,g2);\n"
  let publish =
    #|wp::index(simplex_dim_out,id)=result.gjk.dim;wp::index(iterations_out,id)=result.gjk.iterations;
    #|if(result.status>=10){wp::index(status_out,id)=result.status;wp::atomic_add(rejected_out,result.status-10,1);continue;}
    #|wp::vec3f w1=wp::add(result.x1,origin),w2=wp::add(result.x2,origin);
    #|if(result.status!=2&&(!mr_finite3(w1)||!mr_finite3(w2))){wp::index(status_out,id)=13;wp::atomic_add(rejected_out,3,1);continue;}
    #|wp::index(status_out,id)=result.status;wp::index(separated_out,id)=result.gjk.separated?1:0;
    #|wp::index(distance_out,id)=result.dist;
    #|if(result.status!=2){wp::index(witness1_out,id)=w1;wp::index(witness2_out,id)=w2;}
  let source = prefix +
    "\n" +
    simplex_source() +
    "\n" +
    support_source() +
    "\n" +
    gjk_source() +
    "\n" +
    begin +
    init +
    count +
    reads +
    index_gate +
    geoms +
    mesh_gate +
    pose +
    run +
    publish +
    "\n}\n}\n"
  let source_sha256 = @artifacts.sha256(@utf8.encode(source))
  let identity : Json = {
    "format": "moonrobo-native-convex-gjk-specialization-v1",
    "request": request.to_json(),
    "entry": entry.to_json(),
    "source_sha256": source_sha256.to_json(),
    "mujoco_warp_version": "3.15.0",
    "warp_version": "1.17.0",
  }
  {
    source,
    source_sha256,
    specialization_sha256: @artifacts.sha256(@utf8.encode(identity.stringify())),
    request,
    entry,
  }
}
