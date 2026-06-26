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
fn link_pose(
  model : @urdf.UrdfModel,
  telemetry : @core.TelemetryFrame,
  link_name : String,
  remaining : Int,
) -> ViewportLinkPose {
  let index = link_index(model, link_name)
  match parent_joint_for_link(model, link_name) {
    None =>
      {
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
      }
    Some(joint) =>
      if remaining <= 0 {
        unresolved_link_pose(link_name, index, joint.parent_link, joint.name)
      } else {
        let parent = link_pose(
          model,
          telemetry,
          joint.parent_link,
          remaining - 1,
        )
        let position = telemetry_joint_position(telemetry, joint.name)
        {
          name: link_name,
          index,
          parent_link: joint.parent_link,
          parent_joint: joint.name,
          depth: parent.depth + 1,
          x: parent.x + joint.origin.x,
          y: parent.y + joint.origin.y,
          z: parent.z + joint.origin.z,
          transform: joint_transform_text(joint, position),
          status: if parent.status == "unresolved" {
            "unresolved"
          } else {
            "posed"
          },
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
        link_pose(value, telemetry, link, value.links.length() + 1)
      })
      {
        root_link: root_link_name(model),
        simulated_links: links.length(),
        links,
      }
    }
  }
}
