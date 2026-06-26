///|
pub(all) struct ViewportLinkPose {
  name : String
  index : Int
  parent_link : String
  parent_joint : String
  depth : Int
  x : Double
  y : Double
  z : Double
  transform : String
  status : String
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct UrdfViewportSimulation {
  root_link : String
  simulated_links : Int
  links : Array[ViewportLinkPose]
} derive(Debug, Eq, ToJson, FromJson)

///|
priv struct Vec3 {
  x : Double
  y : Double
  z : Double
}

///|
priv struct Basis {
  xx : Double
  xy : Double
  xz : Double
  yx : Double
  yy : Double
  yz : Double
  zx : Double
  zy : Double
  zz : Double
}

///|
priv struct LinkTransform {
  pose : ViewportLinkPose
  basis : Basis
}

///|
fn identity_basis() -> Basis {
  {
    xx: 1.0,
    xy: 0.0,
    xz: 0.0,
    yx: 0.0,
    yy: 1.0,
    yz: 0.0,
    zx: 0.0,
    zy: 0.0,
    zz: 1.0,
  }
}

///|
fn mat_vec(basis : Basis, vec : Vec3) -> Vec3 {
  {
    x: basis.xx * vec.x + basis.xy * vec.y + basis.xz * vec.z,
    y: basis.yx * vec.x + basis.yy * vec.y + basis.yz * vec.z,
    z: basis.zx * vec.x + basis.zy * vec.y + basis.zz * vec.z,
  }
}

///|
fn mat_mul(a : Basis, b : Basis) -> Basis {
  {
    xx: a.xx * b.xx + a.xy * b.yx + a.xz * b.zx,
    xy: a.xx * b.xy + a.xy * b.yy + a.xz * b.zy,
    xz: a.xx * b.xz + a.xy * b.yz + a.xz * b.zz,
    yx: a.yx * b.xx + a.yy * b.yx + a.yz * b.zx,
    yy: a.yx * b.xy + a.yy * b.yy + a.yz * b.zy,
    yz: a.yx * b.xz + a.yy * b.yz + a.yz * b.zz,
    zx: a.zx * b.xx + a.zy * b.yx + a.zz * b.zx,
    zy: a.zx * b.xy + a.zy * b.yy + a.zz * b.zy,
    zz: a.zx * b.xz + a.zy * b.yz + a.zz * b.zz,
  }
}

///|
fn parse_vector_part(text : String, index : Int) -> Double {
  let mut current = 0
  for part in text.split(" ") {
    if !part.is_empty() {
      if current == index {
        return @string.parse_double(part) catch { _ => 0.0 }
      }
      current += 1
    }
  }
  0.0
}

///|
fn axis_vec(axis : String) -> Vec3 {
  {
    x: parse_vector_part(axis, 0),
    y: parse_vector_part(axis, 1),
    z: parse_vector_part(axis, 2),
  }
}

///|
fn normalize(vec : Vec3) -> Vec3 {
  let length = (vec.x * vec.x + vec.y * vec.y + vec.z * vec.z).sqrt()
  if length > 0.0 {
    { x: vec.x / length, y: vec.y / length, z: vec.z / length }
  } else {
    { x: 0.0, y: 0.0, z: 1.0 }
  }
}

///|
fn axis_rotation(axis : String, angle : Double) -> Basis {
  let a = normalize(axis_vec(axis))
  let c = @math.cos(angle)
  let s = @math.sin(angle)
  let t = 1.0 - c
  {
    xx: t * a.x * a.x + c,
    xy: t * a.x * a.y - s * a.z,
    xz: t * a.x * a.z + s * a.y,
    yx: t * a.x * a.y + s * a.z,
    yy: t * a.y * a.y + c,
    yz: t * a.y * a.z - s * a.x,
    zx: t * a.x * a.z - s * a.y,
    zy: t * a.y * a.z + s * a.x,
    zz: t * a.z * a.z + c,
  }
}

///|
fn rpy_rotation(roll : Double, pitch : Double, yaw : Double) -> Basis {
  let rx = axis_rotation("1 0 0", roll)
  let ry = axis_rotation("0 1 0", pitch)
  let rz = axis_rotation("0 0 1", yaw)
  mat_mul(mat_mul(rz, ry), rx)
}

///|
pub fn model_limit_lower(joint : @urdf.UrdfJoint?) -> Double? {
  match joint {
    Some({ limit: Some({ lower: value, .. }), .. }) => value
    _ => None
  }
}

///|
pub fn model_limit_upper(joint : @urdf.UrdfJoint?) -> Double? {
  match joint {
    Some({ limit: Some({ upper: value, .. }), .. }) => value
    _ => None
  }
}

///|
pub fn normalized_position(
  position : Double,
  lower : Double?,
  upper : Double?,
) -> Double? {
  match (lower, upper) {
    (Some(lo), Some(hi)) =>
      if hi > lo {
        Some((position - lo) / (hi - lo))
      } else {
        None
      }
    _ => None
  }
}

///|
pub fn limit_state(
  mapped : Bool,
  model_mapped : Bool,
  position : Double,
  lower : Double?,
  upper : Double?,
) -> String {
  if !mapped {
    "missing-telemetry"
  } else if !model_mapped {
    "missing-model"
  } else {
    match (lower, upper) {
      (Some(lo), Some(hi)) =>
        if position < lo {
          "below-limit"
        } else if position > hi {
          "above-limit"
        } else {
          "ok"
        }
      (Some(lo), None) => if position < lo { "below-limit" } else { "ok" }
      (None, Some(hi)) => if position > hi { "above-limit" } else { "ok" }
      (None, None) => "unbounded"
    }
  }
}

///|
fn parent_joint_for_link(
  model : @urdf.UrdfModel,
  link_name : String,
) -> @urdf.UrdfJoint? {
  for joint in model.joints {
    if joint.child_link == link_name {
      return Some(joint)
    }
  }
  None
}

///|
fn link_index(model : @urdf.UrdfModel, link_name : String) -> Int {
  for index in 0..<model.links.length() {
    if model.links[index] == link_name {
      return index
    }
  }
  -1
}

///|
pub fn root_link_name(model : @urdf.UrdfModel?) -> String {
  match model {
    None => ""
    Some(value) => {
      for link in value.links {
        if parent_joint_for_link(value, link) is None {
          return link
        }
      }
      if value.links.is_empty() {
        ""
      } else {
        value.links[0]
      }
    }
  }
}

///|
pub fn telemetry_joint_position(
  telemetry : @core.TelemetryFrame,
  joint_name : String,
) -> Double {
  for joint in telemetry.joints {
    if joint.name == joint_name {
      return joint.position
    }
  }
  0.0
}

///|
fn joint_transform_text(joint : @urdf.UrdfJoint, position : Double) -> String {
  "xyz(\{joint.origin.xyz}) rpy(\{joint.origin.rpy}) axis(\{joint.axis}) q(\{position})"
}

///|
fn unresolved_link_pose(
  name : String,
  index : Int,
  parent_link : String,
  parent_joint : String,
) -> ViewportLinkPose {
  {
    name,
    index,
    parent_link,
    parent_joint,
    depth: 0,
    x: 0.0,
    y: 0.0,
    z: 0.0,
    transform: "unresolved",
    status: "unresolved",
  }
}

///|
fn unresolved_link_transform(
  name : String,
  index : Int,
  parent_link : String,
  parent_joint : String,
) -> LinkTransform {
  {
    pose: unresolved_link_pose(name, index, parent_link, parent_joint),
    basis: identity_basis(),
  }
}

///|
fn root_link_transform(link_name : String, index : Int) -> LinkTransform {
  {
    pose: {
      name: link_name,
      index,
      parent_link: "",
      parent_joint: "",
      depth: 0,
      x: 0.0,
      y: 0.0,
      z: 0.0,
      transform: "root",
      status: "root",
    },
    basis: identity_basis(),
  }
}

///|
fn link_transform(
  model : @urdf.UrdfModel,
  telemetry : @core.TelemetryFrame,
  link_name : String,
  remaining : Int,
) -> LinkTransform {
  let index = link_index(model, link_name)
  match parent_joint_for_link(model, link_name) {
    None => root_link_transform(link_name, index)
    Some(joint) =>
      if remaining <= 0 {
        unresolved_link_transform(
          link_name,
          index,
          joint.parent_link,
          joint.name,
        )
      } else {
        let parent = link_transform(
          model,
          telemetry,
          joint.parent_link,
          remaining - 1,
        )
        let position = telemetry_joint_position(telemetry, joint.name)
        let local_origin = {
          x: joint.origin.x,
          y: joint.origin.y,
          z: joint.origin.z,
        }
        let world_origin = mat_vec(parent.basis, local_origin)
        let origin_basis = rpy_rotation(
          joint.origin.roll,
          joint.origin.pitch,
          joint.origin.yaw,
        )
        let joint_basis = axis_rotation(joint.axis, position)
        let child_basis = mat_mul(
          parent.basis,
          mat_mul(origin_basis, joint_basis),
        )
        {
          pose: {
            name: link_name,
            index,
            parent_link: joint.parent_link,
            parent_joint: joint.name,
            depth: parent.pose.depth + 1,
            x: parent.pose.x + world_origin.x,
            y: parent.pose.y + world_origin.y,
            z: parent.pose.z + world_origin.z,
            transform: joint_transform_text(joint, position),
            status: if parent.pose.status == "unresolved" {
              "unresolved"
            } else {
              "posed"
            },
          },
          basis: child_basis,
        }
      }
  }
}

///|
pub fn simulate(
  model : @urdf.UrdfModel?,
  telemetry : @core.TelemetryFrame,
) -> UrdfViewportSimulation {
  match model {
    None => { root_link: "", simulated_links: 0, links: [] }
    Some(value) => {
      let links = value.links.map(fn(link) {
        link_transform(value, telemetry, link, value.links.length() + 1).pose
      })
      {
        root_link: root_link_name(model),
        simulated_links: links.length(),
        links,
      }
    }
  }
}
