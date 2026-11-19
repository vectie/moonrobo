///|
fn parameters() -> Array[Parameter] {
  [
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
  ]
}

///|
fn emit_pair(pair : String) -> String raise {
  match pair {
    "plane-sphere" =>
      "count=1;contacts[0]=mr_plane_sphere(mr_axis(r1),p1,p2,s2[0]);"
    "sphere-sphere" => "count=1;contacts[0]=mr_spheres(p1,s1[0],p2,s2[0]);"
    "sphere-capsule" =>
      "count=1;contacts[0]=mr_sphere_capsule(p1,s1[0],p2,mr_axis(r2),s2[0],s2[1]);"
    "sphere-box" => "count=1;contacts[0]=mr_sphere_box(p1,s1[0],p2,r2,s2);"
    "capsule-capsule" =>
      "count=2;mr_capsules(p1,mr_axis(r1),s1[0],s1[1],p2,mr_axis(r2),s2[0],s2[1],margin,contacts);"
    "plane-capsule" =>
      (
        #|count=2;wp::vec3f n=mr_axis(r1),axis=mr_axis(r2),segment=wp::mul(axis,s2[1]);wp::mat33f frame=mr_plane_capsule_frame(n,axis);
        #|contacts[0]=mr_plane_sphere(n,p1,wp::add(p2,segment),s2[0]);contacts[0].frame=frame;contacts[0].id=0;
        #|contacts[1]=mr_plane_sphere(n,p1,wp::sub(p2,segment),s2[0]);contacts[1].frame=frame;contacts[1].id=1;
      )
    "plane-box" =>
      (
        #|count=8;wp::vec3f n=mr_axis(r1);float center_dist=wp::dot(wp::sub(p2,p1),n);wp::mat33f frame=mr_frame(n);
        #|for(int cornerid=0;cornerid<8;cornerid++){
        #| wp::vec3f corner((cornerid&1)?s2[0]:-s2[0],(cornerid&2)?s2[1]:-s2[1],(cornerid&4)?s2[2]:-s2[2]);corner=wp::mul(r2,corner);
        #| float dist=center_dist+wp::dot(n,corner);contacts[cornerid].dist=dist;
        #| contacts[cornerid].pos=wp::sub(wp::add(corner,p2),wp::mul(wp::mul(n,0.5f),dist));contacts[cornerid].frame=frame;contacts[cornerid].id=cornerid;
        #|}
      )
    _ => raise Unsupported::Invalid("unsupported primitive pair body")
  }
}

///|
fn guards(request : Request) -> String {
  let geom_batches = [
    "geom_solmix", "geom_solref", "geom_solimp", "geom_size", "geom_friction", "geom_margin",
    "geom_gap", "geom_adhesion",
  ]
  let pair_batches = [
    "pair_solref", "pair_solreffriction", "pair_solimp", "pair_margin", "pair_gap",
    "pair_adhesion", "pair_friction",
  ]
  let g = geom_batches.map(n => n + ".shape[0]<=0").join("||")
  let p = pair_batches
    .map(n => n + ".shape[0]<=0||pairid[0]>=" + n + ".shape[1]")
    .join("||")
  "if(world<0||world>=\{request.nworld}||g1<0||g1>=\{request.ngeom}||g2<0||g2>=\{request.ngeom}||pairid[0]<-2||pairid[1]<-1||\{g}){wp::atomic_add(rejected_out,1,1);continue;}\nif(pairid[0]>=0&&(pairid[0]>=pair_dim.shape[0]||\{p})){wp::atomic_add(rejected_out,1,1);continue;}\n"
}

///|
fn shape_gate(request : Request, p : Parameter) -> String {
  let name = p.name
  let requirements : Array[String] = [name + ".ndim!=" + p.rank.to_string()]
  for axis in 0..<p.rank {
    requirements.push("\{name}.shape[\{axis}]<0")
    requirements.push("\{name}.strides[\{axis}]<0")
    requirements.push("(\{name}.strides[\{axis}]%4)!=0")
  }
  let nonempty = Array::makei(p.rank, axis => "\{name}.shape[\{axis}]>0").join(
    "&&",
  )
  requirements.push("(" + nonempty + ")&&!" + name + ".data")
  if name.has_prefix("geom_") {
    if p.rank == 1 {
      requirements.push("\{name}.shape[0]<\{request.ngeom}")
    } else {
      requirements.push(
        "\{name}.shape[0]<" +
        (if name == "geom_xpos_in" || name == "geom_xmat_in" {
          request.nworld.to_string()
        } else {
          "1"
        }),
      )
      requirements.push("\{name}.shape[1]<\{request.ngeom}")
    }
  } else if name.has_prefix("collision_") {
    requirements.push("\{name}.shape[0]<\{request.candidate_capacity}")
  } else if name.has_prefix("contact_") {
    requirements.push("\{name}.shape[0]<\{request.contact_capacity}")
    if p.rank == 2 {
      requirements.push("\{name}.shape[1]!=\{request.efc_slots}")
    }
  } else if name == "nacon_out" || name == "ncollision_in" {
    requirements.push("\{name}.shape[0]<1")
  }
  "(" + requirements.join("||") + ")"
}

///|
/// Build one native primitive entry with explicit rejection counters. Consumers
/// must reject a result if either counter is nonzero; no fallback is generated.
pub fn lower(request : Request) -> Lowered raise {
  guard request.nworld > 0 &&
    request.ngeom > 0 &&
    request.candidate_capacity > 0 &&
    request.candidate_capacity <= 268435455 &&
    request.contact_capacity >= 0 &&
    request.efc_slots > 0 &&
    request.contact_capacity <= 2147483647 / request.efc_slots &&
    request.contact_capacity <= 2147483647 - 8 * request.candidate_capacity &&
    !request.pairs.is_empty() else {
    raise Unsupported::Invalid("invalid/overflowing narrowphase dimensions")
  }
  let seen : Map[String, Unit] = {}
  let branches : Array[String] = []
  let supported : Array[String] = []
  for pair in request.pairs {
    guard !seen.contains(pair) else {
      raise Unsupported::Invalid("duplicate primitive pair")
    }
    seen[pair] = ()
    let (a, b) = pair_types(pair)
    supported.push("(t1==\{a}&&t2==\{b})")
    branches.push("if(t1==\{a}&&t2==\{b}){\n" + emit_pair(pair) + "\n}")
  }
  let entry : Entry = {
    forward: "mr_mjw_native_primitive_contacts",
    launch_shape: [request.candidate_capacity],
    parameters: parameters(),
  }
  let signature = entry.parameters.map(p => p.c_type + " " + p.name).join(",")
  let prefix = "// Copyright 2025-2026 The Newton Developers. SPDX-License-Identifier: Apache-2.0\n#define WP_NO_CRT\n#include \"builtin.h\"\nstatic_assert(sizeof(wp::array_t<float>)==56,\"Warp 1.17 64-bit array ABI required\");\nstatic_assert(sizeof(wp::vec_t<5,float>)==20 && sizeof(wp::mat33f)==36,\"Contact element ABI required\");\n"
  let shape_gates = entry.parameters
    .filter(p => p.name != "rejected_out")
    .map(p => shape_gate(request, p))
    .join("||")
  let begin = "extern \"C\" __global__ void " +
    entry.forward +
    "(wp::launch_bounds_t<1> dim," +
    signature +
    "){\nif(rejected_out.ndim!=1||rejected_out.shape[0]!=2||rejected_out.strides[0]!=4||!rejected_out.data)return;\nfor(size_t tid=size_t(blockIdx.x)*blockDim.x+threadIdx.x;tid<dim.size;tid+=size_t(blockDim.x)*gridDim.x){\nif(" +
    shape_gates +
    "){if(tid==0)wp::atomic_add(rejected_out,1,1);continue;}\nif(wp::index(ncollision_in,0)<0||wp::index(ncollision_in,0)>\{request.candidate_capacity}||wp::index(nacon_out,0)<0){if(tid==0)wp::atomic_add(rejected_out,1,1);continue;}\nif(tid>=size_t(wp::index(ncollision_in,0)))continue;\n"
  let reads =
    #|wp::vec2i geoms=wp::index(collision_pair_in,int(tid)),pairid=wp::index(collision_pairid_in,int(tid));
    #|int world=wp::index(collision_worldid_in,int(tid)),g1=geoms[0],g2=geoms[1];
  let poses =
    #|int t1=wp::index(geom_type,g1),t2=wp::index(geom_type,g2);
    #|wp::vec3f p1=wp::index(geom_xpos_in,world,g1),p2=wp::index(geom_xpos_in,world,g2);
    #|wp::mat33f r1=wp::index(geom_xmat_in,world,g1),r2=wp::index(geom_xmat_in,world,g2);
    #|int sid=world%geom_size.shape[0];wp::vec3f s1=wp::index(geom_size,sid,g1),s2=wp::index(geom_size,sid,g2);
    #|mr_contact contacts[8];int count=0;
  let post = "\nif(count==0){wp::atomic_add(rejected_out,0,1);continue;}\n"
  let source = prefix +
    geometry() +
    capsule_geometry() +
    "\n" +
    begin +
    reads +
    "\n" +
    guards(request) +
    poses +
    "\nif(!(" +
    supported.join("||") +
    ")){wp::atomic_add(rejected_out,0,1);continue;}\n" +
    material_body() +
    "\n" +
    branches.join("else ") +
    post +
    "\nfor(int contactid=0;contactid<count;contactid++){mr_contact c=contacts[contactid];\n" +
    contact_write(request.contact_capacity) +
    "\n}\n}\n}\n"
  let source_sha256 = @artifacts.sha256(@utf8.encode(source))
  let identity : Json = {
    "format": "moonrobo-native-primitive-contacts-v1",
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
