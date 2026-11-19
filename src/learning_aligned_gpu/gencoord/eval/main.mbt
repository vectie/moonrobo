///|
struct Job {
  plugin : String
  mujoco : String
  scene : String
  panel : String
  clips : String
  baseline : String
  layout : String
  checkpoint : String
  output : String
} derive(@json.FromJson)

///|
struct Clip {
  id : String
  sha256 : String
  expected_steps : Int32
} derive(@json.FromJson)

///|
struct Panel {
  clips : Array[Clip]
  source_fps : Double
} derive(@json.FromJson)

///|
struct PreviousClip {
  clip_id : String
  expected_steps : Int32
  normalized_return : Double
  executed_steps : Int32
  termination_frame : Json
  completed_full_duration : Bool
} derive(@json.FromJson, ToJson)

///|
struct Baseline {
  panel_sha256 : String
  mujoco_library_sha256 : String
  scene_sha256 : String
  norm_return : Double
  per_clip : Array[PreviousClip]
} derive(@json.FromJson)

///|
struct Layout {
  context_dim : Int32
  dt : Double
  decimation : Int32
} derive(@json.FromJson)

///|
fn simulate(
  model : @gc.GenModel,
  b : @tensor.Backend,
  rt : @sim.Runtime,
  kin : @aligned.Kinematics,
  clip : Clip,
  directory : String,
  rate : Double,
  scale : Array[Double],
  offset : Array[Double],
) -> @aligned.ClipEvaluation raise {
  let data = @fs.read_file_to_bytes(directory + "/" + clip.id + ".csv")
  assert_eq(@artifacts.sha256(data), clip.sha256)
  let source : @aligned.MotionClip = {
    name: clip.id,
    sha256: clip.sha256,
    rows: @aligned.parse_motion_csv(@utf8.decode(data)),
  }
  let motion = @aligned.MotionLibrary::new([source], kin, source_fps=rate)
  let env = @tracking.Environment::new([rt], motion, config={
    ..@tracking.EnvironmentConfig::default(),
    eval_mode: true,
    auto_reset: false,
    randomization: false,
    reset_noise: false,
  })
  env.reset(frames=[0])
  assert_eq(motion.clip_end[0], clip.expected_steps)
  let upload = (dim : Array[Int32], xs : Array[Double]) => {
    b.from_values(dim, xs, cuda_device=-1, requires_grad=false, dtype=Float32)
  }
  let state_rows = motion.states.map(@aligned.flatten_state)
  let rewards = []
  let mut stop = None
  for t in 0..<clip.expected_steps {
    let sample = env.inspect()[0]
    assert_eq((sample.frame, sample.episode_step), (t, t))
    let state = @gc.GenState::from_replay(
      b,
      upload([1, 71], @aligned.flatten_state(sample.state)),
    )
    let window = []
    for frame in @gc.preview_frames(t, clip.expected_steps) {
      window.append(state_rows[frame])
    }
    let goal = state.goals(b, upload([1, 10, 71], window))
    let action = model.act(state, goal, frozen=true).values()
    let tr = env.step([action], default_q=offset, scales=scale)[0]
    rewards.push(tr.r)
    if tr.terminated {
      stop = Some(t + 1)
    }
    if tr.done() {
      break
    }
  }
  {
    clip_id: clip.id,
    expected_steps: clip.expected_steps,
    rewards,
    terminated: stop is Some(_),
    termination_frame: stop,
    strict_rmse: None,
  }
}

///|
async fn main {
  try {
    if @env.args() is [_, "paper-catalog", config] {
      score_catalog(config)
      return
    }
    if @env.args() is [_, "author-play", config] {
      play_panel(config)
      return
    }
    guard @env.args() is [_, path] else {
      fail("usage: gencoord-eval JOB.json")
    }
    let job : Job = @json.from_json(@json.parse(@fs.read_file_to_string(path)))
    guard !@fs.path_exists(job.output) else {
      fail("evaluation artifact already exists")
    }
    let baseline_bytes = @fs.read_file_to_bytes(job.baseline)
    let old : Baseline = @json.from_json(
      @json.parse(@utf8.decode(baseline_bytes)),
    )
    let panel_bytes = @fs.read_file_to_bytes(job.panel)
    assert_eq(old.panel_sha256, @artifacts.sha256(panel_bytes))
    assert_eq(
      old.scene_sha256,
      @artifacts.sha256(@fs.read_file_to_bytes(job.scene)),
    )
    assert_eq(
      old.mujoco_library_sha256,
      @artifacts.sha256(@fs.read_file_to_bytes(job.mujoco)),
    )
    let panel : Panel = @json.from_json(@json.parse(@utf8.decode(panel_bytes)))
    guard panel.clips.length() == 40 &&
      old.per_clip.length() == 40 &&
      panel.source_fps == 60.0 else {
      fail("expected the frozen 40-motion panel")
    }
    let layout : Layout = @json.from_json(
      @json.parse(@fs.read_file_to_string(job.layout)),
    )
    let b = @tensor.Backend::open(job.plugin)
    let rt = @sim.Runtime::open(job.mujoco, job.scene)
    let kin = @tracking.kinematics(rt)
    let buffer = () => {
      b.from_values(
        [29],
        Array::make(29, 0.0),
        cuda_device=-1,
        requires_grad=false,
        dtype=Float32,
      )
    }
    let model = @gc.GenModel::new(
      b,
      buffer(),
      buffer(),
      context_dim=layout.context_dim,
      dt=layout.dt,
      decimation=layout.decimation,
      device=-1,
    )
    let learner = @gc.GenLearner::new(model, @geometry.Context::new(b, kin, -1))
    let (updates, steps) = learner.load_weights(job.checkpoint)
    let scale = model.scale.values()
    let offset = model.offset.values()
    let trials = []
    let pairs = []
    for i, clip in panel.clips {
      let prev = old.per_clip[i]
      assert_eq(
        (prev.clip_id, prev.expected_steps),
        (clip.id, clip.expected_steps),
      )
      let trial = simulate(
        model,
        b,
        rt,
        kin,
        clip,
        job.clips,
        panel.source_fps,
        scale,
        offset,
      )
      let row = @aligned.summarize_evaluations([trial]).per_clip[0]
      let pair = Json::object({
        "clip": Json(clip.id),
        "previous": prev.to_json(),
        "gencoord": row.to_json(),
        "delta_normalized_return": Json(
          row.normalized_return - prev.normalized_return,
        ),
      })
      println(pair.stringify())
      trials.push(trial)
      pairs.push(pair)
    }
    let names = panel.clips.map(c => c.id)
    let scores = @aligned.summarize_evaluations(trials, expected_clip_ids=names)
    guard scores.benchmark_complete else { fail("incomplete paired panel") }
    let report = scores.report_json(names, {
      "robot": "unitree-g1",
      "backend": "native-mujoco",
    })
    guard report is Object(fields) else { fail("invalid report") }
    fields["panel_sha256"] = Json(old.panel_sha256)
    fields["scene_sha256"] = Json(old.scene_sha256)
    fields["mujoco_library_sha256"] = Json(old.mujoco_library_sha256)
    fields["previous_report_sha256"] = Json(@artifacts.sha256(baseline_bytes))
    fields["physical_steps"] = Json(steps)
    fields["learner_updates"] = Json(updates)
    fields["paired_mean_difference"] = Json(
      scores.norm_return - old.norm_return,
    )
    fields["paired"] = Json::array(pairs)
    @fs.write_string_to_file(job.output, report.stringify())
  } catch {
    @tensor.TensorError::Native(message) => fail(message)
    e => fail(e.to_string())
  }
}
