///|
/// Check the admitted control frames through the same loader the trainer uses.
async test "qualified E1 scratch curriculum preserves all control frames and arm targets" {
  guard @env.get_env_var("MOONROBO_E1_RETRAIN_DATASET") is Some(directory) else {
    return
  }
  let library = @env.get_env_var("MOONROBO_MUJOCO_LIBRARY").unwrap()
  let dataset = open_dataset(directory)
  let admission = require_admission(directory, dataset, library)
  let records : Array[Json] = json_field(admission, "accepted")
  let rt = @sim.Runtime::open(library, directory + "/scene.xml")
  rt.configure_collision(true)
  let robot = dataset.robot
  let kin = @tracking.kinematics(
    rt,
    names=robot.joints,
    tracked_names=robot.tracked,
    root_name="base_link",
  )
  let layout = @tracking.joint_layout(rt, names=robot.joints)
  let feet = [
    id_of_body(rt, "l_leg_ankle_roll_link"),
    id_of_body(rt, "r_leg_ankle_roll_link"),
  ]
  let mut frames = 0
  let mut deepest = 0.0
  let mut lowest = 1.0e9
  let mut speed_ratio = 0.0
  assert_eq(records.length(), dataset.entries.length())
  for i, entry in dataset.entries {
    let report_file : String = json_field(records[i], "report")
    let report = @json.parse(
      @utf8.decode(read_bounded(directory + "/" + report_file, 4194304L)),
    )
    let expected : Int32 = json_field(report, "output_frames")
    let m = load_motion(
      directory,
      { ..dataset, entries: [entry], },
      kin,
      entry.split,
    )
    assert_eq(m.states.length(), expected)
    for f in 0..<expected {
      let s = m.states[f]
      set_pose(rt, layout, s)
      deepest = deepest.max(rt.self_penetration())
      for foot in feet {
        lowest = lowest.min(rt.body_floor_distance(foot))
      }
      for j in 0..<robot.joints.length() {
        assert_true(
          s.q[j] >= kin.q_lo[j] - 0.000001 && s.q[j] <= kin.q_hi[j] + 0.000001,
        )
        if f > 0 {
          let speed = (s.q[j] - m.states[f - 1].q[j]).abs() * 50.0
          speed_ratio = speed_ratio.max(speed / robot.velocity[j])
          assert_true(speed <= robot.velocity[j] + 0.00001)
        }
      }
    }
    for f in [0, expected / 2, expected - 1] {
      let preview = m.goal(f, 10)
      for k, future in m.future_frames(f, 10) {
        for j, name in robot.joints {
          if name.contains("shoulder") ||
            name.contains("elbow") ||
            name == "waist_roll_joint" {
            assert_eq(preview[k * 73 + 15 + j], m.states[future].q[j])
            assert_eq(preview[k * 73 + 44 + j], m.states[future].qd[j] * 0.1)
          }
        }
      }
    }
    frames += expected
  }
  assert_true(deepest <= Self_penetration_limit_m && lowest >= -0.025)
  let summary : Json = {
    "e1_checked_clips": dataset.entries.length(),
    "control_frames": frames,
    "max_self_penetration_m": deepest,
    "min_sole_m": lowest,
    "max_joint_speed_ratio": speed_ratio,
  }
  println(summary.stringify())
}
