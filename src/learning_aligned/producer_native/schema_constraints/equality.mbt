// Derived from pinned Newton solvers/mujoco/equality.py and _convert_to_mjc.
// SPDX-FileCopyrightText: Copyright (c) 2026 The Newton Developers
// SPDX-License-Identifier: Apache-2.0

///|
fn owner(world : Int32, row_world : Int32) -> Unit raise {
  guard world == -1 || world == row_world else {
    fail("equality references another local world")
  }
}

///|
fn body(request : EqualityRequest, index : Int32, world : Int32) -> Unit raise {
  guard index >= -1 && index < request.body_world.length() else {
    fail("invalid equality body reference")
  }
  if index >= 0 {
    owner(request.body_world[index], world)
  }
}

///|
fn joint(request : EqualityRequest, index : Int32, world : Int32) -> Unit raise {
  guard index >= 0 && index < request.joints.length() else {
    fail("invalid equality joint reference")
  }
  let value = request.joints[index]
  guard value.linear_dofs >= 0 &&
    value.linear_dofs <= 1 &&
    value.angular_dofs >= 0 &&
    value.angular_dofs <= 1 &&
    value.linear_dofs + value.angular_dofs == 1 else {
    fail("joint equality requires a scalar joint")
  }
  owner(value.world, world)
}

///|
fn xml(value : String) -> String raise {
  let mut result = ""
  for c in value {
    guard c >= ' ' else {
      fail("exported model names may not contain XML control characters")
    }
    result += match c {
      '&' => "&amp;"
      '"' => "&quot;"
      '\'' => "&apos;"
      '<' => "&lt;"
      '>' => "&gt;"
      _ => "\{c}"
    }
  }
  result
}

///|
fn numbers(values : Array[Double]) -> String {
  values.map(v => v.to_string()).join(" ")
}

///|
fn world_starts(rows : Array[Equality], worlds : Int32) -> Array[Int32] raise {
  let counts = Array::make(worlds, 0)
  let mut front = 0
  let mut have_local = false
  let mut tail = false
  let mut previous = 0
  for row in rows {
    guard row.world >= -1 && row.world < worlds else {
      fail("invalid equality world")
    }
    if row.world == -1 {
      if have_local {
        tail = true
      } else {
        front += 1
      }
    } else {
      guard !tail && row.world >= previous else {
        fail("equality rows must retain contiguous model world ordering")
      }
      previous = row.world
      have_local = true
      counts[row.world] += 1
    }
  }
  let starts = [front]
  for count in counts {
    starts.push(starts.last().unwrap() + count)
  }
  starts.push(rows.length())
  starts
}

///|
/// Materializes the pure equality-frequency rows used by pinned public
/// helpers. This does not infer compiler reference constants or assemble J/H.
pub fn prepare_equalities(request : EqualityRequest) -> Prepared raise {
  guard request.world_count >= 1 &&
    request.world_count <= 65536 &&
    request.rows.length() <= 65536 &&
    request.body_world.length() <= 65536 &&
    request.joints.length() <= 65536 &&
    request.body_names.length() == request.body_world.length() &&
    request.joint_names.length() == request.joints.length() else {
    fail("unsupported equality topology cardinality")
  }
  for world in request.body_world {
    guard world >= -1 && world < request.world_count else {
      fail("invalid body world metadata")
    }
  }
  for item in request.joints {
    guard item.world >= -1 && item.world < request.world_count else {
      fail("invalid joint world metadata")
    }
  }
  for names in [request.body_names, request.joint_names] {
    let seen : Map[String, Unit] = Map([])
    for name in names {
      guard !name.is_empty() && name.length() <= 1024 && !seen.contains(name) else {
        fail("actual exported body/joint names must be unique and nonempty")
      }
      ignore(xml(name))
      seen[name] = ()
    }
  }
  let starts = world_starts(request.rows, request.world_count)
  let kinds : Array[Int32] = []
  let objects : Array[Int32] = []
  let bodies1 : Array[Int32] = []
  let bodies2 : Array[Int32] = []
  let joints1 : Array[Int32] = []
  let joints2 : Array[Int32] = []
  let worlds : Array[Int32] = []
  let enabled : Array[Bool] = []
  let anchors : Array[Double] = []
  let poses : Array[Double] = []
  let torques : Array[Double] = []
  let polynomials : Array[Double] = []
  let solrefs : Array[Double] = []
  let solimps : Array[Double] = []
  let spec_data : Array[Double] = []
  let labels : Array[String] = []
  let converted : Array[Json] = []
  let lines = ["<mujocoinclude>", "  <equality>"]
  for row in request.rows {
    let kind = match row.kind {
      "connect" => 0
      "weld" => 1
      "joint" => 2
      _ => fail("unsupported equality kind")
    }
    let anchor = vector(row.anchor, [0.0, 0.0, 0.0], 3)
    let defaults = if kind == 1 {
      [0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 0.0]
    } else {
      [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 1.0]
    }
    let pose = vector(row.relpose, defaults, 7)
    let torque = rounded(
      row.torquescale.unwrap_or(if kind == 1 { 1.0 } else { 0.0 }),
    )
    let coef = row.polycoef.unwrap_or(if kind == 2 { [0.0, 1.0] } else { [] })
    guard coef.length() <= 5 else {
      fail("joint polynomial accepts at most five coefficients")
    }
    let polynomial = Array::makei(5, i => {
      if i < coef.length() {
        rounded(coef[i])
      } else {
        0.0
      }
    })
    let solref = vector(row.solref, [0.02, 1.0], 2)
    let solimp = vector(row.solimp, [0.9, 0.95, 0.001, 0.5, 2.0], 5)
    let (name1, name2) = if kind == 2 {
      joint(request, row.joint1, row.world)
      joint(request, row.joint2, row.world)
      guard row.joint1 != row.joint2 &&
        row.body1 == -1 &&
        row.body2 == -1 &&
        row.anchor is None &&
        row.relpose is None &&
        row.torquescale is None else {
        fail("joint equality has same joint or unsupported body/pose fields")
      }
      (request.joint_names[row.joint1], request.joint_names[row.joint2])
    } else {
      body(request, row.body1, row.world)
      body(request, row.body2, row.world)
      guard row.body1 != row.body2 &&
        (row.body1 >= 0 || row.body2 >= 0) &&
        row.joint1 == -1 &&
        row.joint2 == -1 &&
        row.polycoef is None else {
        fail("body equality requires distinct bodies and no joint fields")
      }
      if kind == 0 {
        guard row.relpose is None && row.torquescale is None else {
          fail("connect equality does not use weld pose/torque fields")
        }
      }
      (
        if row.body1 < 0 {
          "world"
        } else {
          request.body_names[row.body1]
        },
        if row.body2 < 0 {
          "world"
        } else {
          request.body_names[row.body2]
        },
      )
    }
    let data = Array::make(11, 0.0)
    if kind == 2 {
      for i in 0..<5 {
        data[i] = polynomial[i]
      }
    } else {
      for i in 0..<3 {
        data[i] = anchor[i]
      }
      if kind == 1 {
        for i in 0..<3 {
          data[3 + i] = pose[i]
        }
        data[6] = pose[6]
        data[7] = pose[3]
        data[8] = pose[4]
        data[9] = pose[5]
        data[10] = torque
      }
    }
    kinds.push(kind)
    objects.push(if kind == 2 { 3 } else { 1 })
    bodies1.push(row.body1)
    bodies2.push(row.body2)
    joints1.push(row.joint1)
    joints2.push(row.joint2)
    worlds.push(row.world)
    enabled.push(row.enabled)
    labels.push(row.label)
    torques.push(torque)
    for value in anchor {
      anchors.push(value)
    }
    for value in pose {
      poses.push(value)
    }
    for value in polynomial {
      polynomials.push(value)
    }
    for value in solref {
      solrefs.push(value)
    }
    for value in solimp {
      solimps.push(value)
    }
    for value in data {
      spec_data.push(value)
    }
    let common = " active=\"\{row.enabled}\" solref=\"\{numbers(solref)}\" solimp=\"\{numbers(solimp)}\""
    let attrs = if kind == 2 {
      " joint1=\"\{xml(name1)}\" joint2=\"\{xml(name2)}\" polycoef=\"\{numbers(polynomial)}\""
    } else {
      " body1=\"\{xml(name1)}\" body2=\"\{xml(name2)}\" anchor=\"\{numbers(anchor)}\""
    }
    let weld = if kind == 1 {
      " relpose=\"\{numbers([pose[0],pose[1],pose[2],pose[6],pose[3],pose[4],pose[5]])}\" torquescale=\"\{torque}\""
    } else {
      ""
    }
    lines.push("    <\{row.kind}\{attrs}\{weld}\{common}/>")
    converted.push({
      "type": Json(kind),
      "objtype": Json(if kind == 2 { 3 } else { 1 }),
      "name1": Json(name1),
      "name2": Json(name2),
      "data": Json(data),
      "active": Json(row.enabled),
      "solref": Json(solref),
      "solimp": Json(solimp),
      "reference_pose_inference_pending": Json(
        kind == 1 &&
        pose[3] == 0.0 &&
        pose[4] == 0.0 &&
        pose[5] == 0.0 &&
        pose[6] == 0.0,
      ),
    })
  }
  lines.push("  </equality>")
  lines.push("</mujocoinclude>")
  let n = request.rows.length()
  let arrays = [
    ints("mujoco.equality_constraint_type", kinds),
    ints("mujoco.equality_constraint_objtype", objects),
    ints("mujoco.equality_constraint_body1", bodies1),
    ints("mujoco.equality_constraint_body2", bodies2),
    ints("mujoco.equality_constraint_joint1", joints1),
    ints("mujoco.equality_constraint_joint2", joints2),
    ints("mujoco.equality_constraint_world", worlds),
    booleans("mujoco.equality_constraint_enabled", enabled),
    floats("mujoco.equality_constraint_anchor", anchors, [n], 3),
    floats("mujoco.equality_constraint_relpose", poses, [n], 7),
    floats("mujoco.equality_constraint_torquescale", torques, [n], 1),
    floats("mujoco.equality_constraint_polycoef", polynomials, [n, 5], 1),
    floats("mujoco.eq_solref", solrefs, [n], 2),
    floats("mujoco.eq_solimp", solimps, [n], 5),
    ints("mujoco.equality_constraint_target_kind", Array::make(n, 0)),
    ints("mujoco.equality_constraint_target", Array::make(n, -1)),
    ints("mujoco.equality_constraint_world_start", starts),
    floats("prepared.mjs_equality_data", spec_data, [n, 11], 1, kind="f64"),
  ]
  let metadata : Json = {
    "format": "moonrobo-newton-pure-equality-storage-v1",
    "count": Json(n),
    "world_count": Json(request.world_count),
    "labels": Json(labels),
    "mjs_authoring": Json(converted),
    "arrays": Json(arrays.map(a => a.metadata())),
    "float_storage": "Newton-float32; MjSpec authored slots are float32 values promoted to Double",
    "mjs_data_is_compiler_output": false,
    "mjs_authoring_world_selection": "all input rows; non-separated model branch only",
    "separate_world_model_selection_implemented": false,
    "body_and_joint_names_supplied_by_caller": true,
    "loop_joint_and_mimic_projection": false,
    "full_constraint_jacobian_generated": false,
    "full_newton_model_constructed": false,
    "numeric_equivalence_verified": false,
  }
  { arrays, metadata, mjcf: lines.join("\n") + "\n", }
}
