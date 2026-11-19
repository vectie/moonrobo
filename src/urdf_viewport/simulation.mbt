///|
pub(all) struct ViewportLinkPose {
  name : String
  index : Int32
  parent_link : String
  parent_joint : String
  depth : Int32
  x : Double
  y : Double
  z : Double
  world_basis : ViewportBasis
  transform : String
  status : String
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct UrdfViewportSimulation {
  root_link : String
  simulated_links : Int32
  links : Array[ViewportLinkPose]
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct ViewportVisualInstance {
  index : Int32
  link_name : String
  geometry_kind : String
  x : Double
  y : Double
  z : Double
  world_basis : ViewportBasis
  link_status : String
} derive(Debug, Eq, ToJson, FromJson)

///|
pub type ViewportBasis = @geometry.Basis3

///|
type Vec3 = @geometry.Vec3

///|
priv struct LinkTransform {
  pose : ViewportLinkPose
  basis : ViewportBasis
}

///|
fn identity_basis() -> ViewportBasis {
  @geometry.identity_basis3()
}

///|
fn mat_vec(basis : ViewportBasis, vec : Vec3) -> Vec3 {
  basis.mul_vec3(vec)
}

///|
fn mat_mul(a : ViewportBasis, b : ViewportBasis) -> ViewportBasis {
  a.mul_basis3(b)
}

///|
fn parse_vector_part(text : String, index : Int32) -> Double {
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
fn axis_rotation(axis : String, angle : Double) -> ViewportBasis {
  @geometry.axis_angle_basis3(axis_vec(axis), angle)
}

///|
fn rpy_rotation(roll : Double, pitch : Double, yaw : Double) -> ViewportBasis {
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
fn link_index(model : @urdf.UrdfModel, link_name : String) -> Int32 {
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
  index : Int32,
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
    world_basis: identity_basis(),
    transform: "unresolved",
    status: "unresolved",
  }
}

///|
fn unresolved_link_transform(
  name : String,
  index : Int32,
  parent_link : String,
  parent_joint : String,
) -> LinkTransform {
  {
    pose: unresolved_link_pose(name, index, parent_link, parent_joint),
    basis: identity_basis(),
  }
}

///|
fn root_link_transform(link_name : String, index : Int32) -> LinkTransform {
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
      world_basis: identity_basis(),
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
  remaining : Int32,
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
        let local_origin : Vec3 = {
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
            world_basis: child_basis,
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
    None => { root_link: "", simulated_links: 0, links: [], }
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

///|
fn link_pose_by_name(
  simulation : UrdfViewportSimulation,
  link_name : String,
) -> ViewportLinkPose? {
  for link in simulation.links {
    if link.name == link_name {
      return Some(link)
    }
  }
  None
}

///|
fn visual_instance(
  simulation : UrdfViewportSimulation,
  visual : @urdf.UrdfVisual,
  index : Int32,
) -> ViewportVisualInstance {
  match link_pose_by_name(simulation, visual.link_name) {
    Some(link) => {
      let local_origin : Vec3 = {
        x: visual.origin.x,
        y: visual.origin.y,
        z: visual.origin.z,
      }
      let world_origin = mat_vec(link.world_basis, local_origin)
      let visual_basis = rpy_rotation(
        visual.origin.roll,
        visual.origin.pitch,
        visual.origin.yaw,
      )
      {
        index,
        link_name: visual.link_name,
        geometry_kind: visual.geometry_kind,
        x: link.x + world_origin.x,
        y: link.y + world_origin.y,
        z: link.z + world_origin.z,
        world_basis: mat_mul(link.world_basis, visual_basis),
        link_status: link.status,
      }
    }
    None =>
      {
        index,
        link_name: visual.link_name,
        geometry_kind: visual.geometry_kind,
        x: 0.0,
        y: 0.0,
        z: 0.0,
        world_basis: identity_basis(),
        link_status: "missing-link",
      }
  }
}

///|
pub fn visual_instances(
  model : @urdf.UrdfModel?,
  telemetry : @core.TelemetryFrame,
) -> Array[ViewportVisualInstance] {
  match model {
    None => []
    Some(value) => {
      let simulation = simulate(Some(value), telemetry)
      let instances : Array[ViewportVisualInstance] = []
      for index in 0..<value.visuals.length() {
        instances.push(visual_instance(simulation, value.visuals[index], index))
      }
      instances
    }
  }
}
