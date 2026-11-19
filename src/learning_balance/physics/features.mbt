///|
/// Extract observation-only static geometry from a compiled MuJoCo model. Rejects mocap bodies, unobserved moving hinges, and unsupported floating-root layouts.
pub fn make_spec(
  runtime : @native_physics.Runtime,
  foot_names~ : Array[String] = ["left_foot", "right_foot"],
) -> @balance.Kinematics raise {
  let root = runtime.root_body()
  guard runtime.joint_type(0) == 0 && runtime.body_parent(root) == 0 else {
    fail("balance geometry requires a floating-root hinge tree")
  }
  let selected = [root]
  let map : Map[Int32, Int32] = {}
  map[root] = 0
  for body in (root + 1)..<runtime.body_count() {
    if map.contains(runtime.body_parent(body)) {
      map[body] = selected.length()
      selected.push(body)
    }
  }
  let q_indices = runtime.q_indices()
  let bodies : Array[@balance.Body] = []
  for body in selected {
    guard runtime.body_mocap_id(body) < 0 else {
      fail("mocap body geometry is not observation-derived")
    }
    let joints : Array[@balance.Hinge] = []
    if body != root {
      for joint in runtime.body_joint_ids(body) {
        guard runtime.joint_type(joint) == 3 else {
          fail("all observed moving child joints must be hinges")
        }
        let address = runtime.joint_qpos_address(joint)
        let mut index = -1
        for i, q in q_indices {
          if q == address {
            index = i
          }
        }
        guard index >= 0 else {
          fail("unobserved child joint in balance geometry")
        }
        joints.push({
          observation_index: index,
          axis: runtime.joint_axis(joint),
          anchor: runtime.joint_pivot(joint),
          reference: runtime.joint_qref(joint),
        })
      }
    }
    bodies.push({
      parent: if body == root {
        -1
      } else {
        map[runtime.body_parent(body)]
      },
      position: runtime.body_offset_pos(body),
      quaternion_wxyz: runtime.body_offset_quat(body),
      com_position: runtime.body_inertial_pos(body),
      mass: runtime.body_mass(body),
      joints,
    })
  }
  let feet : Array[@balance.Foot] = []
  for name in foot_names {
    let mut found = -1
    for site in 0..<runtime.site_count() {
      if runtime.site_name(site) == name {
        found = site
      }
    }
    guard found >= 0 else { fail("missing foot support site: " + name) }
    guard map.get(runtime.site_body(found)) is Some(body) else {
      fail("support site lies outside floating-root subtree")
    }
    feet.push({ body, position: runtime.site_local_pos(found), })
  }
  { nu: runtime.joint_names().length(), bodies, feet, }
}

///|
/// A separate RNG per declared command schedule keeps reset noise independent. The distribution matches Python's limits; the RNG stream is explicitly MoonBit, not NumPy PCG64.
pub fn sample_reference(
  runtime : @native_physics.Runtime,
  case : Json,
  seed : Int32,
) -> (Array[Double]?, @native_physics.JointSines?) raise {
  let parsed : @native_physics.Case = @json.from_json(case)
  if parsed.motion != "pose_offset" && parsed.motion != "random_joint_sines" {
    return (None, None)
  }
  let limits = field(case, "goal_offset_rad")
  let lower = parameter_number(limits, "lower", None)
  let waist = parameter_number(limits, "waist", None)
  let upper = parameter_number(limits, "upper", None)
  guard lower >= 0.0 && waist >= 0.0 && upper >= 0.0 else {
    fail("negative reference motion amplitude")
  }
  let names = runtime.joint_names()
  let amplitudes = names.map(fn(name) {
    if name.has_prefix("waist_") {
      waist
    } else if ["shoulder", "elbow", "wrist"].any(fn(part) {
        name.contains(part)
      }) {
      upper
    } else {
      lower
    }
  })
  if parsed.motion == "pose_offset" {
    let rng = @numeric.Rng::new(seed.to_uint() ^ 1729U)
    (Some(amplitudes.map(fn(a) { a * (2.0 * rng.uniform() - 1.0) })), None)
  } else {
    let rng = @numeric.Rng::new(seed.to_uint() ^ 2718U)
    (
      None,
      Some({
        amplitude: amplitudes.map(fn(a) { a * (0.3 + 0.7 * rng.uniform()) }),
        bias: amplitudes.map(fn(a) { a * (-0.2 + 0.4 * rng.uniform()) }),
        frequency_hz: names.map(fn(_) { 0.15 + 0.5 * rng.uniform() }),
        phase_rad: names.map(fn(_) {
          -3.141592653589793 + 6.283185307179586 * rng.uniform()
        }),
      }),
    )
  }
}
