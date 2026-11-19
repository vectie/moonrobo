///|
/// These real native fixtures are written and type-checked only. They require an installed MuJoCo library when execution is later authorized.
async fn contract_runtime() -> (@native_physics.Runtime, String) {
  guard @env.get_env_var("MOONROBO_MUJOCO_LIBRARY") is Some(library) else {
    fail("deferred physics contracts require MOONROBO_MUJOCO_LIBRARY")
  }
  let folder = @fs.tmpdir(prefix="moonrobo-branch-contract-")
  let xml =
    #|<mujoco><option timestep=".002" gravity="0 0 0"/>
    #|<worldbody><body pos="0 0 1"><freejoint/><geom type="sphere" size=".1"/>
    #|<site name="left_foot" pos="0 .1 -.1"/><site name="right_foot" pos="0 -.1 -.1"/>
    #|<body><joint name="left_ankle_pitch_joint"/><geom type="capsule" size=".03 .1"/></body>
    #|</body></worldbody><actuator><position joint="left_ankle_pitch_joint" kp="10" ctrlrange="-1 1"/></actuator>
    #|<keyframe><key name="home" qpos="0 0 1 1 0 0 0 0"/></keyframe></mujoco>
  let scene = folder + "/scene.xml"
  @fs.write_file(scene, @utf8.encode(xml), create_mode=CreateOrTruncate)
  (@native_physics.Runtime::open(library, scene), folder)
}

///|
async test "restored branches preserve time previous applied controls and real transitions" {
  let (runtime, folder) = contract_runtime()
  defer (@fs.rmdir(folder, recursive=true) catch { _ => () })
  let case : @native_physics.Case = {
    id: "toy",
    family: "training-family",
    split: "train",
    keyframe: "home",
    motion: "stand",
    friction: 1,
  }
  let captured : Array[BranchOrigin] = []
  let predict = fn(
    _obs : Array[Double],
    goal : Array[Double],
  ) -> Array[Double] {
    goal
  }
  let (parent, _) = runtime.rollout(
    case,
    1,
    "policy",
    0.1,
    0.02,
    () => 0.0,
    policy=predict,
    trace=(i, action, goal) => {
      if i == 2 {
        captured.push({
          integration: runtime.integration(),
          previous: action.copy(),
          goal: goal.copy(),
          start_step: 2,
          parent_episode_id: "parent",
        })
      }
    },
  )
  assert_eq(captured.length(), 1)
  let original = runtime.integration()
  let config : BranchConfig = {
    branch_steps: 3,
    pulse_steps: 2,
    dt: 0.02,
    fall_height: 0.35,
    fall_upright: 0.5,
  }
  let (baseline, _) = branch_rollout(
    runtime,
    captured[0],
    case,
    predict,
    [0.0],
    config,
    "zero",
  )
  assert_true(unperturbed_replay_error(parent, 2, baseline) < 0.000000000001)
  assert_eq(runtime.integration(), original)
  let (pulse, _) = branch_rollout(
    runtime,
    captured[0],
    case,
    predict,
    [0.05],
    config,
    "pulse",
  )
  assert_eq(runtime.integration(), original)
  assert_eq(pulse.steps.map(s => s.time_s), [0.04, 0.06, 0.08])
  assert_eq(pulse.steps.map(s => s.applied_action), [[0.05], [0.05], [0.0]])
  assert_eq(pulse.steps.map(s => s.observation[s.observation.length() - 1]), [
    0.0, 0.05, 0.05,
  ])
  assert_true(pulse.steps[2].truncated)
  assert_false(pulse.steps[2].terminated)
  assert_eq(pulse.source_family, "training-family")
}

///|
async test "teacher labels stay separate from applied controls and heldout cases are excluded" {
  let (runtime, folder) = contract_runtime()
  defer (@fs.rmdir(folder, recursive=true) catch { _ => () })
  let actor = @training.Actor::new(
    { mean: Array::make(9, 0.0), scale: Array::make(9, 1.0), },
    { mean: [0.0], scale: [1.0], },
    [-1.0],
    [1.0],
    0.1,
    { q_indices: [7], v_state_indices: [14], nq: 8, },
    4,
    @numeric.Rng::new(17U),
  )
  let training : Json = {
    "id": "training",
    "family": "toy",
    "split": "train",
    "motion": "stand",
    "keyframe": "home",
    "friction": 1,
  }
  let heldout : Json = {
    "id": "heldout",
    "family": "toy",
    "split": "validation",
    "motion": "stand",
    "keyframe": "absent-heldout-keyframe",
    "friction": 1,
  }
  let collection : Json = {
    "control_dt_s": 0.02,
    "duration_s": 0.04,
    "fall_height_m": 0.35,
    "fall_upright_z": 0.5,
    "cases": [training, heldout],
  }
  let parameters : @balance.FeedbackParameters = {
    angle_gain: 0,
    rate_gain: 0,
    com_gain: 0,
    velocity_gain: 0,
    pitch_bias: 0.2,
    joint_damping: 0,
    residual_bound: 0.3,
    hip_share: 0,
    waist_share: 0,
    waist_dynamic_only: false,
    support_gain: 0,
  }
  let (episodes, labels) = collect_teacher_labels(
    runtime,
    actor,
    collection,
    parameters,
    1,
    @numeric.Rng::new(8U),
  )
  assert_eq(episodes.length(), 2)
  assert_eq(labels.length(), 4)
  assert_true(episodes.all(e => e.case_id == "training" && e.split == "train"))
  assert_eq(labels.map(p => p.target), [[0.2], [0.2], [0.2], [0.2]])
  let mut point = 0
  for episode in episodes {
    for step in episode.steps {
      assert_eq(step.applied_action, [0.0])
      assert_eq(labels[point].observation, step.observation)
      assert_eq(labels[point].goal, step.goal)
      assert_true(labels[point].target != step.applied_action)
      point += 1
    }
  }
}

///|
/// Original final policy/PPO evaluation spans all declared cases, while selection uses only validation cases. Authored but not executed.
async test "explicit all-case evaluation yields nine trials without widening validation selection" {
  let (runtime, folder) = contract_runtime()
  defer (@fs.rmdir(folder, recursive=true) catch { _ => () })
  let cases : Array[Json] = ["train", "validation", "test"].map(split => {
    (
      {
        "id": split.to_json(),
        "family": "toy",
        "split": split.to_json(),
        "keyframe": "home",
        "motion": "stand",
        "friction": 1,
      } : Json)
  })
  let experiment : Json = {
    "control_dt_s": 0.02,
    "duration_s": 0.04,
    "fall_height_m": 0.35,
    "fall_upright_z": 0.5,
  }
  let (summary, episodes, trials) = evaluate(
    runtime,
    cases,
    [0, 1, 2],
    experiment,
    None,
    "all",
    @numeric.Rng::new(8U),
  )
  assert_eq(trials.length(), 9)
  assert_eq(episodes.length(), 9)
  assert_eq(
    field(counted_summary(summary, trials.length()), "trials"),
    (9).to_json(),
  )
  let (_, selected, selection) = evaluate(
    runtime,
    cases,
    [0, 1, 2],
    experiment,
    None,
    "validation",
    @numeric.Rng::new(8U),
  )
  assert_eq(selection.length(), 3)
  assert_true(selected.all(episode => episode.split == "validation"))
}
