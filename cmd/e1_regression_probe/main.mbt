///|
fn history_append(
  history : Array[Array[Double]],
  frame : @aligned.CollectorFrame,
  motion : @aligned.MotionLibrary,
  robot : @e1.Profile,
) -> Array[Array[Double]] raise {
  let obs = @aligned.observation(
    frame.state,
    frame.previous,
    frame.xi,
    robot.embed(robot.default_q),
    motion.states[frame.frame],
    @aligned.Smc,
  )
  if history.is_empty() {
    Array::makei(10, _ => obs.copy())
  } else {
    let next = history[1:].to_owned()
    next.push(obs)
    next
  }
}

///|
async fn write(path : String, value : Json) -> Unit {
  @fs.write_file(
    path,
    @utf8.encode(value.stringify(indent=2)),
    create_mode=CreateNew,
  )
}

///|
fn magnitude(x : Array[Double]) -> Double {
  x.map(v => v * v).fold(init=0.0, (a, b) => a + b).sqrt()
}

///|
fn stats(values : Array[Double]) -> Json {
  let ordered = values.copy()
  ordered.sort()
  {
    "p50": ordered[(ordered.length() - 1) / 2],
    "p95": ordered[((ordered.length() - 1).to_double() * 0.95).to_int()],
    "p99": ordered[((ordered.length() - 1).to_double() * 0.99).to_int()],
    "maximum": ordered[ordered.length() - 1],
  }
}

///|
fn reference_metrics(motion : @aligned.MotionLibrary, active : Int32) -> Json {
  let speed = []
  let angular = []
  let acceleration = []
  let angular_acceleration = []
  let joint_acceleration = []
  let mut worst_frame = 0
  let mut worst_angular = 0.0
  for f in 2..<(motion.states.length() - 2) {
    let s = motion.states[f]
    let previous = motion.states[f - 1]
    let next = motion.states[f + 1]
    speed.push(magnitude(s.v))
    angular.push(magnitude(s.w))
    acceleration.push(magnitude(@aligned.vec_sub(next.v, previous.v)) / 0.04)
    angular_acceleration.push(
      magnitude(@aligned.vec_sub(next.w, previous.w)) / 0.04,
    )
    if magnitude(s.w) > worst_angular {
      worst_angular = magnitude(s.w)
      worst_frame = f
    }
    let mut a = 0.0
    for j in 0..<active {
      a = a.max((next.qd[j] - previous.qd[j]).abs() / 0.04)
    }
    joint_acceleration.push(a)
  }
  {
    "frames": motion.states.length(),
    "root_speed_m_s": stats(speed),
    "root_angular_speed_rad_s": stats(angular),
    "root_acceleration_m_s2": stats(acceleration),
    "root_angular_acceleration_rad_s2": stats(angular_acceleration),
    "maximum_joint_acceleration_per_frame_rad_s2": stats(joint_acceleration),
    "maximum_root_angular_speed_frame": worst_frame,
  }
}

///|
fn tensor(
  backend : @tensor.Backend,
  width : Int32,
  rows : Array[Array[Double]],
) -> @tensor.Tensor raise {
  let values = []
  for row in rows {
    values.append(row)
  }
  backend.from_values(
    [rows.length(), width],
    values,
    dtype=Float32,
    cuda_device=-1,
    requires_grad=false,
  )
}

///|
async fn main {
  guard @env.args() is [_, mode, root, output] else {
    fail("mode job-root new-report")
  }
  let library = "/opt/isaaclab-venv/lib/python3.12/site-packages/mujoco/libmujoco.so.3.15.0"
  let plugin = root + "/libmoonrobo_learning_tensor.so"
  let dataset_dir = root + "/data-qualified-v9"
  let dataset = @e1.open_dataset(dataset_dir)
  let rt = @sim.Runtime::open(library, dataset_dir + "/scene.xml")
  let kin = @tracking.kinematics(
    rt,
    names=dataset.robot.joints,
    tracked_names=dataset.robot.tracked,
    root_name="base_link",
  )
  let motion = @e1.load_motion(
    dataset_dir,
    dataset,
    kin,
    if mode == "world" {
      "validation"
    } else {
      "train"
    },
  )
  let env = @e1.Environment::new([rt], dataset.robot, motion, config={
    ..@tracking.EnvironmentConfig::default(),
    eval_mode: true,
    auto_reset: false,
    randomization: false,
    reset_noise: false,
  })
  if mode == "references" {
    let g1rt = @sim.Runtime::open(library, "/g1/scene.xml")
    let g1kin = @tracking.kinematics(g1rt)
    let results : Array[Json] = []
    for entry in dataset.entries {
      if entry.split != "train" {
        continue
      }
      let rows : Array[Array[Double]] = @json.from_json(
        @json.parse(
          @utf8.decode(@fs.read_file(dataset_dir + "/" + entry.file).binary()),
        ),
      )
      let target = @aligned.MotionLibrary::new(
        [{ name: entry.id, sha256: entry.sha256, rows, }],
        kin,
        source_fps=50.0,
        compute_body_features=false,
      )
      if entry.id.has_prefix("g1-") {
        let path = root +
          "/source-g1-refs/lafan1_g1/" +
          entry.id[3:].to_owned() +
          ".csv"
        guard @e1.hash_file(path) == entry.source_sha256 else {
          fail("G1 source identity")
        }
        let source_rows = @aligned.parse_motion_csv(
          @utf8.decode(@fs.read_file(path).binary()),
        )
        let source = @aligned.MotionLibrary::new(
          [{ name: entry.id, sha256: entry.source_sha256, rows: source_rows, }],
          g1kin,
          source_fps=30.0,
          compute_body_features=false,
        )
        results.push({
          "clip": entry.id,
          "source_g1": reference_metrics(source, 29),
          "retargeted_e1": reference_metrics(target, 23),
        })
      } else {
        let old_rows : Array[Array[Double]] = @json.from_json(
          @json.parse(
            @utf8.decode(
              @fs.read_file(root + "/data-23/motions/0_boxing.json").binary(),
            ),
          ),
        )
        let source = @aligned.MotionLibrary::new(
          [{ name: entry.id, sha256: "staged-vendor", rows: old_rows, }],
          kin,
          source_fps=50.0,
          compute_body_features=false,
        )
        results.push({
          "clip": entry.id,
          "source_vendor": reference_metrics(source, 23),
          "retargeted_e1": reference_metrics(target, 23),
        })
      }
    }
    write(output, {
      "format": "moonrobo.e1-reference-dynamics-audit.v1",
      "control_hz": 50,
      "scope": "same-source comparison after resampling to 50Hz; central-difference kinematics, not inverse dynamics or contact-force feasibility",
      "results": results,
    })
    return
  }
  if mode == "segments" {
    let results : Array[Json] = []
    for iteration in [4000, 5500, 6000] {
      let (actor, metadata) = @e1.load_actor(
        root +
        "/out/train-qualified/evaluation-" +
        iteration.to_string() +
        "/actor",
        plugin,
      )
      guard metadata.identity.dataset_sha256 ==
        @e1.hash_file(dataset_dir + "/dataset.json") else {
        fail("dataset")
      }
      for (clip, starts) in [(3, [0, 8000, 10300]), (4, [0, 8000, 10500])] {
        for start in starts {
          env.reset(frame=motion.clip_start[clip] + start)
          let mut history : Array[Array[Double]] = []
          let mut executed = 0
          let mut reward = 0.0
          let mut failed = false
          let mut root_error = 0.0
          for _ in 0..<500 {
            let frame = env.inspect()[0]
            history = history_append(history, frame, motion, dataset.robot)
            let action = actor.forward_embedded(
              history,
              motion.goal(frame.frame, 10),
            )
            let transition = env.step([action])[0]
            reward += transition.r
            executed += 1
            let state = @aligned.unflatten_state(transition.s1)
            let reference = motion.states[(frame.frame + 1).min(
                motion.clip_end[clip],
              )]
            let delta = @aligned.vec_sub(state.p, reference.p)
            root_error = root_error.max(
              delta.map(x => x * x).fold(init=0.0, (a, b) => a + b).sqrt(),
            )
            if transition.done() {
              failed = transition.terminated
              break
            }
          }
          results.push({
            "checkpoint": iteration,
            "clip": motion.names[clip],
            "start_frame": start,
            "requested_steps": 500,
            "executed_steps": executed,
            "failed": failed,
            "normalized_segment_return": reward / 50.0,
            "maximum_root_position_error_m": root_error,
          })
        }
      }
    }
    write(output, {
      "format": "moonrobo.e1-regression-segment-probe.v1",
      "benchmark": false,
      "scope": "counterfactual resets onto reference states; 10-second segments do not replace full-motion evaluation",
      "results": results,
    })
    return
  }
  guard mode == "world" else { fail("mode") }
  // Capture one fixed held-out physical corpus before loading any compared WM.
  let (reference_actor, _) = @e1.load_actor(
    root + "/out/train-qualified/evaluation-4000/actor",
    plugin,
  )
  let rng = @numeric.Rng::new(771U)
  let initial : Array[Array[Double]] = []
  let actions : Array[Array[Array[Double]]] = []
  let targets : Array[Array[Array[Double]]] = []
  let xis : Array[Array[Double]] = []
  for window in 0..<32 {
    env.reset(frame=(motion.states.length() - 10) * window / 31)
    initial.push(@aligned.flatten_state(env.inspect()[0].state))
    let aa = []
    let ss = []
    let mut history = []
    for _ in 0..<8 {
      let frame = env.inspect()[0]
      history = history_append(history, frame, motion, dataset.robot)
      let action = reference_actor.forward_embedded(
        history,
        motion.goal(frame.frame, 10),
      )
      for j in 0..<dataset.robot.joints.length() {
        action[j] += 0.06 * rng.uniform() - 0.03
      }
      let tr = env.step([action])[0]
      guard !tr.done() else {
        fail("fixed world probe crossed an episode boundary")
      }
      aa.push(action)
      ss.push(tr.s1)
    }
    actions.push(aa)
    targets.push(ss)
    xis.push(env.inspect()[0].xi)
  }
  let backend = @tensor.Backend::open(plugin)
  let context = @geometry.Context::new(
    backend,
    kin,
    -1,
    default_q=dataset.robot.embed(dataset.robot.default_q),
    active_joints=dataset.robot.joints.length(),
  )
  let results : Array[Json] = []
  for iteration in [3000, 4000, 4500, 5500, 6000] {
    let directory = root +
      "/out/train-qualified/generation-" +
      iteration.to_string()
    let saved : @e1.Saved = @json.from_json(
      @json.parse(
        @utf8.decode(@fs.read_file(directory + "/checkpoint.json").binary()),
      ),
    )
    guard @e1.hash_file(directory + "/world.pt") == saved.files["world.pt"] else {
      fail("world archive digest")
    }
    let m = saved.learner
    let world = @gpu.WorldModel::new(
      backend,
      @numeric.Rng::new(1U),
      hidden=m.config.wm_hidden,
      layer_norm_mode=m.world_layer_norm_mode.unwrap_or(Expanded),
      linear_mode=m.world_linear_mode.unwrap_or(MatmulBias),
      mlp_precision=m.mlp_precision.unwrap_or(Fp32),
    )
    let loader = backend.adam(world.net.parameters(), beta2=0.95)
    loader.load(directory + "/world.pt")
    for
      (norm, snapshot) in [
        (world.input_norm, m.normalizers[0]),
        (world.output_norm, m.normalizers[1]),
      ] {
      norm.mean = backend.from_values(
        [snapshot.mean.length()],
        snapshot.mean,
        dtype=Float32,
        cuda_device=-1,
        requires_grad=false,
      )
      norm.variance = backend.from_values(
        [snapshot.variance.length()],
        snapshot.variance,
        dtype=Float32,
        cuda_device=-1,
        requires_grad=false,
      )
      norm.count = snapshot.count
    }
    let frozen = world.net.frozen()
    let mut state = @geometry.State::from_flat71(
      backend,
      tensor(backend, 71, initial),
    )
    let xi = @geometry.normalize_xi(backend, tensor(backend, 33, xis))
    for step in 0..<8 {
      let input = @geometry.world_inputs(
        backend,
        state,
        tensor(backend, 29, actions.map(a => a[step])),
        xi,
        heading_mode=m.heading_mode.unwrap_or(OrthonormalAtlas),
      )
      let delta = world.delta(input, frozen_net=frozen)
      state = context.project_state(
        @geometry.world_integrate(
          backend,
          state,
          delta,
          heading_mode=m.heading_mode.unwrap_or(OrthonormalAtlas),
        ),
      )
      let target = @geometry.State::from_flat71(
        backend,
        tensor(backend, 71, targets.map(s => s[step])),
      )
      let errors = @geometry.state_error(
        backend,
        state,
        target,
        heading_mode=m.heading_mode.unwrap_or(OrthonormalAtlas),
        smc_rotation=m.smc_world_rotation.unwrap_or(false),
      ).values()
      if step == 0 || step == 7 {
        let mut pos = 0.0
        let mut rot = 0.0
        let mut q = 0.0
        let mut qd = 0.0
        for row in 0..<32 {
          for j in 0..<3 {
            pos += errors[row * 70 + j] * errors[row * 70 + j]
            rot += errors[row * 70 + 3 + j] * errors[row * 70 + 3 + j]
          }
          for j in 0..<dataset.robot.joints.length() {
            q += errors[row * 70 + 12 + j] * errors[row * 70 + 12 + j]
            qd += errors[row * 70 + 41 + j] * errors[row * 70 + 41 + j]
          }
        }
        results.push({
          "checkpoint": iteration,
          "horizon": step + 1,
          "root_position_rmse_m": (pos / 96.0).sqrt(),
          "rotation_component_rmse_rad": (rot / 96.0).sqrt(),
          "joint_position_rmse_rad": (q /
          (32 * dataset.robot.joints.length()).to_double()).sqrt(),
          "joint_velocity_rmse_rad_s": (qd /
          (32 * dataset.robot.joints.length()).to_double()).sqrt(),
        })
      }
    }
  }
  write(output, {
    "format": "moonrobo.e1-fixed-world-probe.v1",
    "benchmark": false,
    "windows": 32,
    "physical_transitions": 256,
    "scope": "identical held-out boxing physical transitions, reference-state resets, actor4000 plus fixed action noise; physical-unit errors, no optimizer steps",
    "results": results,
  })
}
