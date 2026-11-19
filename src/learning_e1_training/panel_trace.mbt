///|
priv enum TracePolicy {
  Primary
  Comparison
  ComparisonLegs
  ComparisonWaistAndArms
  ComparisonLegGroup(String, Bool)
}

///|
priv struct PanelFrame {
  frame : Int32
  state_before : Array[Double]
  state_after : Array[Double]
  reference_z : Double
  reference_zz : Double
  robot_zz : Double
  setpoint_rad : Array[Double]
  alternate_setpoint_rad : Array[Double]
  reward : Double
  cumulative_reward : Double
  reward_terms : Array[Double]
  height_error_m : Double
  tilt_error : Double
  floor_contact_bodies : Array[String]
  terminated : Bool
} derive(ToJson)

///|
fn trace_setpoint(
  robot : Profile,
  action : Array[Double],
  xi : Array[Double],
) -> Array[Double] {
  Array::makei(robot.joints.length(), j => {
    robot.default_q[j] + robot.scales[j] * action[j] + xi[j + 1]
  })
}

///|
fn measure_trial(
  env : Environment,
  rt : @sim.Runtime,
  kin : @aligned.Kinematics,
  motion : @aligned.MotionLibrary,
  clip : Int32,
  robot : Profile,
  primary : Actor,
  comparison : Actor,
  spec : @inference.ActorSpec,
  before : TracePolicy,
  after : TracePolicy,
  switch_after : Int32,
  capture~ : Bool,
  prefix : Array[PanelFrame],
) -> (Array[PanelFrame], Int32, Bool, Double) raise {
  let start = motion.clip_start[clip]
  let n = motion.clip_end[clip] - start
  let count = robot.joints.length()
  let default_q = robot.embed(robot.default_q)
  let rows : Array[PanelFrame] = []
  let mut history : Array[Array[Double]] = []
  let mut total = 0.0
  let cfg = @aligned.RewardConfig::default()
  env.reset(frame=start)
  for i in 0..<n {
    let f = env.inspect()[0]
    guard f.frame == start + i && f.episode_step == i else {
      fail("unexpected replay progression")
    }
    let obs = @aligned.observation(
      f.state,
      f.previous,
      f.xi,
      default_q,
      motion.states[f.frame],
      spec.mode(),
    )
    if i == 0 {
      history = Array::makei(spec.hist, _ => obs.copy())
    } else {
      history = history[1:].to_owned()
      history.push(obs)
    }
    let goal = motion.goal(f.frame, spec.goal_frames)
    let policy = if i < switch_after { before } else { after }
    let (action, alternate) = match policy {
      Primary =>
        (
          primary.forward_embedded(history, goal),
          if capture {
            comparison.forward_embedded(history, goal)
          } else {
            []
          },
        )
      Comparison =>
        (
          comparison.forward_embedded(history, goal),
          if capture {
            primary.forward_embedded(history, goal)
          } else {
            []
          },
        )
      group => {
        let a = primary.forward_embedded(history, goal)
        let b = comparison.forward_embedded(history, goal)
        for j in 0..<count {
          let leg = robot.joints[j].contains("_leg_")
          let use_comparison = match group {
            ComparisonLegs => leg
            ComparisonWaistAndArms => !leg
            ComparisonLegGroup(part, invert) =>
              leg && robot.joints[j].contains(part) != invert
            _ => false
          }
          if use_comparison {
            a[j] = b[j]
          }
        }
        (a, [])
      }
    }
    let tr = env.step([action])[0]
    total += tr.r
    if !capture && i < switch_after {
      guard prefix.get(i) is Some(row) &&
        row.state_before == tr.s &&
        row.state_after == tr.s1 &&
        row.reward == tr.r else {
        fail("intervention changed the pre-switch trajectory")
      }
    }
    if capture {
      let state = env.inspect()[0].state
      let ref = motion.states[f.frame + 1]
      let z = (state.p[2] - ref.p[2]).abs()
      let tilt = (state.rotation[8] - ref.rotation[8]).abs()
      let terms = @aligned.reward(
        kin,
        state,
        ref,
        motion.bodies[f.frame + 1],
        action,
        f.previous,
      )
      guard (z > cfg.term_height || tilt > cfg.term_tilt) == tr.terminated &&
        terms.reward == tr.r else {
        fail("diagnostics differ from physics reward or termination")
      }
      let touching : Array[String] = []
      for c in rt.collision_contacts() {
        if c.body_a == 0 || c.body_b == 0 {
          let name = rt.body_name(
            if c.body_a == 0 {
              c.body_b
            } else {
              c.body_a
            },
          )
          if !touching.contains(name) {
            touching.push(name)
          }
        }
      }
      rows.push({
        frame: i + 1,
        state_before: tr.s,
        state_after: tr.s1,
        reference_z: ref.p[2],
        reference_zz: ref.rotation[8],
        robot_zz: state.rotation[8],
        setpoint_rad: trace_setpoint(robot, action, f.xi),
        alternate_setpoint_rad: trace_setpoint(robot, alternate, f.xi),
        reward: tr.r,
        cumulative_reward: total,
        reward_terms: [
          terms.body_pos,
          terms.body_ori,
          terms.body_linvel,
          terms.body_angvel,
          terms.root_pos,
          terms.root_ori,
          terms.action_rate,
          terms.joint_limit,
        ],
        height_error_m: z,
        tilt_error: tilt,
        floor_contact_bodies: touching,
        terminated: tr.terminated,
      })
    }
    if tr.done() {
      return (rows, i + 1, tr.terminated, total)
    }
  }
  fail("missing terminal transition")
}

///|
async fn run_panel_traces(
  rt : @sim.Runtime,
  kin : @aligned.Kinematics,
  robot : Profile,
  motion : @aligned.MotionLibrary,
  indices : Array[Int32],
  primary : Actor,
  p : ExportedActor,
  comparison : Actor,
  c : ExportedActor,
  output : String,
) -> Unit {
  guard p.spec.hist == c.spec.hist &&
    p.spec.goal_frames == c.spec.goal_frames &&
    p.spec.observation_mode == c.spec.observation_mode else {
    fail("incompatible observations")
  }
  let env = Environment::new([rt], robot, motion, config={
    ..@tracking.EnvironmentConfig::default(),
    eval_mode: true,
    auto_reset: false,
    randomization: false,
    reset_noise: false,
  })
  for clip in indices {
    let n = motion.clip_end[clip] - motion.clip_start[clip]
    let (late, f, died, _) = measure_trial(
      env,
      rt,
      kin,
      motion,
      clip,
      robot,
      primary,
      comparison,
      p.spec,
      Primary,
      Primary,
      0,
      capture=true,
      [],
    )
    let (early, _, _, _) = measure_trial(
      env,
      rt,
      kin,
      motion,
      clip,
      robot,
      primary,
      comparison,
      p.spec,
      Comparison,
      Comparison,
      0,
      capture=true,
      [],
    )
    guard late[0].state_before == early[0].state_before else {
      fail("paired initial states differ")
    }
    let branches : Array[Json] = []
    fn branch(
      label : String,
      from : TracePolicy,
      to : TracePolicy,
      at : Int32,
      baseline : Array[PanelFrame],
    ) -> Unit raise {
      let (_, steps, terminated, reward) = measure_trial(
        env,
        rt,
        kin,
        motion,
        clip,
        robot,
        primary,
        comparison,
        p.spec,
        from,
        to,
        at,
        capture=false,
        baseline,
      )
      branches.push({
        "policy": label,
        "switch_after_frame": at,
        "steps": steps,
        "terminated": terminated,
        "normalized_return": reward / (n.to_double() * 0.1),
      })
    }
    if died {
      branch("comparison_first_action_only", Comparison, Primary, 1, early)
      for lead in [100, 50, 25, 10, 1] {
        if f > lead && f - lead < early.length() {
          branch("primary_to_comparison", Primary, Comparison, f - lead, late)
          branch("comparison_to_primary", Comparison, Primary, f - lead, early)
        }
      }
      for at in [0, (f - 50).max(0)] {
        branch("comparison_legs", Primary, ComparisonLegs, at, late)
        branch(
          "comparison_waist_and_arms",
          Primary,
          ComparisonWaistAndArms,
          at,
          late,
        )
      }
      if f > 50 {
        for group in ["hip", "knee", "ankle"] {
          for invert in [false, true] {
            let name = (if invert {
                "comparison_legs_except_"
              } else {
                "comparison_only_"
              }) +
              group
            branch(
              name,
              Primary,
              ComparisonLegGroup(group, invert),
              f - 50,
              late,
            )
          }
        }
      }
    }
    let report : Json = {
      "clip_id": motion.names[clip],
      "index": clip,
      "expected_steps": n,
      "reference_sha256": motion.source_sha256[clip],
      "primary_actor": p.archive_sha256,
      "comparison_actor": c.archive_sha256,
      "frame": "1-based post-step at 50 Hz; setpoints applied during transition ending at this frame",
      "state_layout": "root XYZ, quaternion WXYZ, world linear velocity XYZ, world angular velocity XYZ, 29 joint positions, 29 joint velocities",
      "joints": robot.joints,
      "reward_fields": [
        "body_pos_mse", "body_ori_mse", "body_linvel_mse", "body_angvel_mse", "root_pos_sq",
        "root_ori_sq", "action_rate_sq", "soft_joint_limit",
      ],
      "primary": Json(late),
      "comparison": Json(early),
      "interventions": branches,
    }
    @fs.write_file(
      output + "/trace-" + clip.to_string() + ".json",
      @utf8.encode(report.stringify()),
      create_mode=CreateNew,
    )
  }
}
