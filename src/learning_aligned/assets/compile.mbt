///|
pub async fn compile_description(
  library : String,
  description_directory : String,
  self_collisions~ : Bool = true,
) -> Json {
  let source = description_directory + "/g1_29dof_rev_1_0.urdf"
  let source_bytes = @fs.read_file(source).binary()
  let root = parse_xml(@utf8.decode(source_bytes))
  guard root.name == "robot" else { fail("expected URDF robot root") }
  let keep = root.children.filter(child => child.name != "mujoco")
  root.children.clear()
  root.children.append(keep)
  let extension = element("mujoco", Map([]))
  extension.children.push(
    element("compiler", {
      "meshdir": ".",
      "balanceinertia": "true",
      "discardvisual": "false",
      "fusestatic": "false",
      "strippath": "false",
    }),
  )
  root.children.push(extension)
  let temporary = description_directory + "/_g1_compiler.urdf"
  @fs.write_file(
    temporary,
    @utf8.encode(root.xml()),
    create_mode=CreateOrTruncate,
  )
  let robot_path = description_directory + "/g1_29dof.xml"
  let version = @sim.compile_xml_to_mjcf(library, temporary, robot_path)
  @fs.remove(temporary)
  let robot = parse_xml(@utf8.decode(@fs.read_file(robot_path).binary()))
  guard robot.find("body", name="pelvis") is Some(pelvis) else {
    fail("compiled URDF lacks pelvis")
  }
  pelvis.children.push(element("freejoint", { "name": "floating_base_joint" }))
  @fs.write_file(
    robot_path,
    @utf8.encode(robot.xml()),
    create_mode=CreateOrTruncate,
  )
  let option = robot.child("option")
  option.attributes["timestep"] = "0.005"
  option.attributes["integrator"] = "implicitfast"
  option.attributes["cone"] = "pyramidal"
  let world = robot.child("worldbody")
  world.children.push(
    element("geom", {
      "name": "floor",
      "type": "plane",
      "size": "0 0 0.05",
      "friction": "1 0.005 0.0001",
      "rgba": "0.25 0.28 0.3 1",
      "contype": "1",
      "conaffinity": "2",
    }),
  )
  collision_geoms(pelvis, self_collisions)
  let actuators = element("actuator", Map([]))
  robot.children.push(actuators)
  for name in @aligned.joint_names() {
    let motor = @aligned.motor_of(name)
    guard robot.find("joint", name~) is Some(joint) else {
      fail("robot joint missing: " + name)
    }
    joint.attributes["armature"] = motor.armature.to_string()
    joint.attributes["damping"] = "0"
    joint.attributes["frictionloss"] = "0"
    actuators.children.push(
      element("position", {
        "name": name[:name.length() - 6].to_owned(),
        "joint": name,
        "kp": motor.stiffness().to_string(),
        "kv": motor.damping().to_string(),
        "forcelimited": "true",
        "forcerange": "\{-motor.effort} \{motor.effort}",
        "ctrllimited": "false",
      }),
    )
  }
  let scene_path = description_directory +
    (if self_collisions {
      "/scene.xml"
    } else {
      "/scene-no-self-collision.xml"
    })
  @fs.write_file(
    scene_path,
    @utf8.encode(robot.xml()),
    create_mode=CreateOrTruncate,
  )
  let compiled = @sim.Runtime::open(library, scene_path)
  let (nq, nv, _, nu) = compiled.dimensions()
  guard nq == 36 &&
    nv == 35 &&
    nu == 29 &&
    compiled.joint_names() == @aligned.joint_names() else {
    fail("compiled G1 dimensions or actuator joint order differ")
  }
  let receipt : Json = {
    "format": "moonrobo.aligned-robot-compilation.v1",
    "urdf_sha256": @artifacts.sha256(source_bytes).to_json(),
    "robot_path": robot_path.to_json(),
    "scene_path": scene_path.to_json(),
    "robot_sha256": @artifacts.sha256(@fs.read_file(robot_path).binary()).to_json(),
    "scene_sha256": @artifacts.sha256(@fs.read_file(scene_path).binary()).to_json(),
    "mujoco_version": version.to_json(),
    "self_collisions": self_collisions.to_json(),
    "dimensions": {
      "qpos": nq.to_json(),
      "qvel": nv.to_json(),
      "actions": nu.to_json(),
    },
    "substep_seconds": 0.005,
    "physics_scope": "native MuJoCo; matching retarget URDF and PD constants, not Isaac/MuJoCo-Warp parity",
  }
  @fs.write_file(
    description_directory + "/compilation.json",
    @utf8.encode(receipt.stringify(indent=2) + "\n"),
    create_mode=CreateOrTruncate,
  )
  receipt
}
