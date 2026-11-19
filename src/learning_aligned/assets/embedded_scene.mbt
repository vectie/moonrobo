///|
/// Build a self-contained position-servo scene from a vendor MJCF. The source
/// and all mesh bytes are preserved and hashed; an optional hinge is fixed at 0.
pub async fn prepare_embedded_scene(
  source : String,
  mesh_directory : String,
  output : String,
  names : Array[String],
  kp : Array[Double],
  kd : Array[Double],
  effort : Array[Double],
  armature : Array[Double],
  locked_joint~ : String? = None,
) -> Json {
  guard !@fs.exists(output) &&
    names.length() > 0 &&
    names.length() <= 29 &&
    [kp, kd, effort, armature].all(x => x.length() == names.length()) else {
    fail("new scene directory and matching actuator vectors required")
  }
  let bytes = @fs.read_file(source).binary()
  let robot = parse_xml(@utf8.decode(bytes))
  guard robot.name == "mujoco" else { fail("expected vendor MJCF") }
  @fs.mkdir(output + "/meshes", recursive=true)
  robot.child("compiler").attributes["meshdir"] = "meshes"
  robot.child("compiler").attributes["fusestatic"] = "false"
  robot.child("option").attributes["timestep"] = "0.005"
  robot.child("option").attributes["integrator"] = "implicitfast"
  let hashes : Map[String, String] = {}
  for mesh in robot.child("asset").children {
    if mesh.name == "mesh" {
      guard mesh.attributes.get("file") is Some(file) &&
        !file.contains("/") &&
        !file.contains("\\") else {
        fail("expected flat vendor mesh filename")
      }
      let data = @fs.read_file(mesh_directory + "/" + file).binary()
      @fs.write_file(output + "/meshes/" + file, data, create_mode=CreateNew)
      hashes[file] = @artifacts.sha256(data)
    }
  }
  if locked_joint is Some(name) {
    remove_embedded_joint(robot, name)
  }
  let actuators = robot.child("actuator")
  actuators.children.clear()
  for i, name in names {
    guard robot.find("joint", name~) is Some(joint) else {
      fail("missing physical hinge " + name)
    }
    joint.attributes["armature"] = armature[i].to_string()
    joint.attributes["damping"] = "0"
    joint.attributes["frictionloss"] = "0"
    actuators.children.push(
      element("position", {
        "name": name,
        "joint": name,
        "kp": kp[i].to_string(),
        "kv": kd[i].to_string(),
        "forcelimited": "true",
        "forcerange": "\{-effort[i]} \{effort[i]}",
        "ctrllimited": "false",
      }),
    )
  }
  let scene = @utf8.encode(robot.xml())
  @fs.write_file(output + "/scene.xml", scene, create_mode=CreateNew)
  let receipt : Json = {
    "format": "moonrobo.embedded-scene.v1",
    "source_sha256": Json(@artifacts.sha256(bytes)),
    "scene_sha256": Json(@artifacts.sha256(scene)),
    "meshes": Json(hashes),
    "locked_joint": Json(locked_joint),
  }
  @fs.write_file(
    output + "/scene.json",
    @utf8.encode(receipt.stringify(indent=2)),
    create_mode=CreateNew,
  )
  receipt
}

///|
fn remove_embedded_joint(node : Element, name : String) -> Unit {
  let keep = node.children.filter(x => {
    !(x.name == "joint" && x.attributes.get("name") == Some(name))
  })
  node.children.clear()
  node.children.append(keep)
  for child in node.children {
    remove_embedded_joint(child, name)
  }
}
