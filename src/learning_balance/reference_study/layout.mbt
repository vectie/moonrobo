///|
fn goal_axes(joints : Array[String], bodies : Array[String]) -> Array[Json] {
  let out : Array[Json] = []
  fn add(prefix : String, names : Array[String], unit : String) {
    for name in names {
      out.push({ "name": (prefix + name).to_json(), "unit": unit.to_json() })
    }
  }
  add("reference.joint_position.", joints, "rad")
  add("reference.joint_velocity.", joints, "rad/s")
  add("reference.gravity_root.", ["x", "y", "z"], "1")
  add("reference.root_height.", ["z"], "m")
  add("reference.root_linear_velocity_root.", ["x", "y", "z"], "m/s")
  add("reference.root_angular_velocity_root.", ["x", "y", "z"], "rad/s")
  for body in bodies {
    add("reference.body_position_root." + body + ".", ["x", "y", "z"], "m")
  }
  for body in bodies {
    add(
      "reference.body_rotation_root." + body + ".",
      ["c0x", "c0y", "c0z", "c1x", "c1y", "c1z"],
      "1",
    )
  }
  out
}

///|
fn layout(runtime : @sim.Runtime, dt : Double) -> Json raise {
  let (nq, nv, na, nu) = runtime.dimensions()
  let bodies : Array[String] = []
  for i in 1..<runtime.body_count() {
    bodies.push(runtime.body_name(i))
  }
  {
    "nq": nq.to_json(),
    "nv": nv.to_json(),
    "na": na.to_json(),
    "nu": nu.to_json(),
    "joint_names": runtime.joint_names().to_json(),
    "body_names": bodies.to_json(),
    "q_indices": runtime.q_indices().to_json(),
    "v_indices": runtime.v_indices().to_json(),
    "root_body_index": (runtime.root_body() - 1).to_json(),
    "dt_s": dt.to_json(),
    "goal_axes": goal_axes(runtime.joint_names(), bodies).to_json(),
    "state_convention": "MuJoCo qpos then qvel then act; free-root quaternion wxyz; world Z up; root angular qvel local",
    "integration_convention": "mjSTATE_INTEGRATION, including solver warm start and user inputs; pinned MuJoCo only",
    "body_velocity_convention": "mj_objectVelocity(mjOBJ_BODY, flg_local=0), angular xyz then linear xyz",
    "preview_convention": "at action i use frames i+1..i+K; repeat end only with valid=false mask",
    "actor_goal_excludes": [
      "source_setpoint", "source_goal", "integration", "actual_robot_global_pose",
    ],
    "actor_goal_frame": "reference root frame including tilt; root height in world; world XY and yaw removed",
  }
}

///|
fn field(value : Json, key : String) -> Json raise {
  guard value is Object(fields) && fields.get(key) is Some(result) else {
    fail("missing study field: " + key)
  }
  result
}

///|
fn number(value : Json, key : String) -> Double raise {
  @json.from_json(field(value, key))
}

///|
fn text(value : Json, key : String) -> String raise {
  @json.from_json(field(value, key))
}

///|
fn mutate(value : Json, fields : Map[String, Json]) -> Json raise {
  guard value is Object(original) else { fail("expected study object") }
  let copy : Map[String, Json] = Map([])
  for key, v in original {
    copy[key] = v
  }
  for key, v in fields {
    copy[key] = v
  }
  Json::object(copy)
}
