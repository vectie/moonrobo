///|
struct PlayJob {
  panel_play : Bool
  plugin : String
  device : String
  environments : Int32
  seed : Int32
  motion_file : String
  panel : String
  source_manifest : String
  layout : String
  checkpoint : String
  policy_kind : String
  legacy_actor_sha256 : String?
  output : String
} derive(@json.FromJson)

///|
struct NativeCatalog {
  frames : Int32
  clips : Int32
  source_manifest_sha256 : String
  manifest_sha256 : String
} derive(@json.FromJson)

///|
struct SourceClip {
  id : String
  sha256 : String
  fps : Double
} derive(@json.FromJson)

///|
struct SourcePanel {
  clips : Array[SourceClip]
} derive(@json.FromJson)

///|
struct LegacyCheckpoint {
  learner : @gpu.CheckpointMetadata
} derive(@json.FromJson)

///|
priv enum PlayPolicy {
  GenCoord(@gc.GenModel, @gc.GenMotions)
  Legacy(
    @inference.Actor,
    Array[@aligned.State],
    Array[Array[Array[Double]]],
    Array[Double],
    Array[Double],
    Array[Double]
  )
}

///|
fn read_play_json(path : String) -> Json raise {
  @json.parse(@fs.read_file_to_string(path))
}

///|
fn cpu_rows(
  b : @tensor.Backend,
  shape : Array[Int32],
  x : Array[Double],
) -> @tensor.Tensor raise {
  b.from_values(shape, x, cuda_device=-1, dtype=Float32, requires_grad=false)
}

///|
fn frame_ids(b : @tensor.Backend, a : Array[Int32]) -> @tensor.Tensor raise {
  b.from_values(
    [a.length()],
    a.map(i => i.to_double()),
    cuda_device=-1,
    dtype=Int64,
    requires_grad=false,
  )
}

///|
fn load_play_policy(
  job : PlayJob,
  b : @tensor.Backend,
  all : @tensor.Tensor,
  scale : Array[Double],
  offset : Array[Double],
) -> (PlayPolicy, Int32) raise {
  if job.policy_kind == "gencoord" {
    let model = @gc.GenModel::new(
      b,
      cpu_rows(b, [29], scale),
      cpu_rows(b, [29], offset),
      context_dim=33,
      device=-1,
      dt=0.02,
      decimation=4,
    )
    guard read_play_json(job.layout) is Object(fields) else {
      fail("invalid play layout")
    }
    let kin : @aligned.Kinematics = @json.from_json(fields["geometry"])
    let learner = @gc.GenLearner::new(model, @geometry.Context::new(b, kin, -1))
    let (_, steps) = learner.load_weights(job.checkpoint)
    assert_eq((model.scale.values(), model.offset.values()), (scale, offset))
    (GenCoord(model, @gc.GenMotions::new(b, all)), steps)
  } else {
    guard job.policy_kind == "legacy" && job.legacy_actor_sha256 is Some(digest) else {
      fail("unknown G1 policy or missing historical actor digest")
    }
    let archive = job.checkpoint + "/policy.pt"
    assert_eq(@artifacts.sha256(@fs.read_file_to_bytes(archive)), digest)
    let ck : LegacyCheckpoint = @json.from_json(
      read_play_json(job.checkpoint + "/state.json"),
    )
    let actor = @inference.Actor::load_archive(
      b,
      archive,
      @inference.ActorSpec::from_checkpoint(ck.learner),
    )
    let flat = all.values()
    let states = Array::makei(all.shape()[0], i => {
      @aligned.unflatten_state(flat[i * 71:i * 71 + 71].to_owned())
    })
    let q0 = @aligned.default_joint_positions()
    let ones = @aligned.action_to_setpoint(Array::make(29, 1.0))
    let legacy_scale = Array::makei(29, i => ones[i] - q0[i])
    guard scale.all(v => @numeric.finite(v) && v > 0.0) else {
      fail("invalid author action scaling")
    }
    let ratio = Array::makei(29, i => legacy_scale[i] / scale[i])
    let bias = Array::makei(29, i => (q0[i] - offset[i]) / scale[i])
    guard read_play_json(job.checkpoint + "/receipt.json") is Object(fields) else {
      fail("invalid historical checkpoint receipt")
    }
    let it : Int32 = @json.from_json(fields["iteration"])
    (
      Legacy(
        actor,
        states,
        Array::makei(job.environments, _ => []),
        q0,
        ratio,
        bias,
      ),
      it,
    )
  }
}

///|
fn PlayPolicy::actions(
  self : PlayPolicy,
  b : @tensor.Backend,
  flat : Array[Double],
  times : Array[Int32],
  ends : Array[Int32],
  active : Array[Bool],
  encoder_bias : Array[Double],
  previous : Array[Array[Double]],
) -> Array[Double] raise {
  let n = times.length()
  match self {
    GenCoord(model, refs) => {
      let s = @gc.GenState::from_replay(b, cpu_rows(b, [n, 71], flat))
      let goal = s.goals(
        b,
        refs.window(frame_ids(b, times), frame_ids(b, ends)),
      )
      model.act(s, goal, frozen=true).values()
    }
    Legacy(actor, refs, history, q0, ratio, bias) => {
      let out = Array::make(n * 29, 0.0)
      for i in 0..<n {
        if active[i] {
          let t = times[i]
          let state = @aligned.unflatten_state(
            flat[i * 71:i * 71 + 71].to_owned(),
          )
          // mjlab measures q + encoder_bias and applies target - encoder_bias.
          // The historical actor's calibration variable has the opposite sign.
          let xi = Array::make(33, 0.0)
          for j in 0..<29 {
            xi[1 + j] = -encoder_bias[i * 29 + j]
          }
          let obs = @aligned.observation(
            state,
            previous[i],
            xi,
            q0,
            refs[t],
            actor.spec.mode(),
          )
          history[i] = if history[i].is_empty() {
            Array::makei(actor.spec.hist, _ => obs)
          } else {
            let next = history[i][1:].to_owned()
            next.push(obs)
            next
          }
          let preview = Array::makei(actor.spec.goal_frames, k => {
            refs[(t + 1 + k).min(ends[i])]
          })
          let raw = actor.forward(
            history[i],
            @aligned.goal_from_states(refs[t], preview),
          )
          previous[i] = raw
          for j in 0..<29 {
            out[i * 29 + j] = ratio[j] * raw[j] + bias[j]
          }
        }
      }
      out
    }
  }
}

///|
async fn play_panel(path : String) -> Unit {
  let job : PlayJob = @json.from_json(read_play_json(path))
  let n = job.environments
  guard job.panel_play &&
    n == 40 &&
    job.device == "cuda:0" &&
    !@fs.path_exists(job.output) else {
    fail("author-play requires a fresh 40-motion CUDA panel")
  }
  let panel_bytes = @fs.read_file_to_bytes(job.panel)
  let panel : Panel = @json.from_json(@json.parse(@utf8.decode(panel_bytes)))
  let source_bytes = @fs.read_file_to_bytes(job.source_manifest)
  let manifest : SourcePanel = @json.from_json(
    @json.parse(@utf8.decode(source_bytes)),
  )
  let catalog : NativeCatalog = @json.from_json(
    read_play_json(job.motion_file + "/source.json"),
  )
  let names : Array[String] = @json.from_json(
    read_play_json(job.motion_file + "/motion_names.json"),
  )
  assert_eq(catalog.source_manifest_sha256, @artifacts.sha256(source_bytes))
  assert_eq(names, panel.clips.map(c => c.id))
  assert_eq((catalog.clips, manifest.clips.length(), names.length()), (n, n, n))
  for i, row in manifest.clips {
    assert_eq(
      (row.id, row.sha256, row.fps),
      (names[i], panel.clips[i].sha256, panel.source_fps),
    )
  }
  let b = @tensor.Backend::open(job.plugin)
  let free = @linuxmem.host_available().min(b.cuda_free_bytes(0))
  let budget = (free / 100L * 80L).min(free - 17179869184L)
  let planned = 6L * 1073741824L +
    n.to_int64() * 5242880L +
    catalog.frames.to_int64() * 1700L
  guard planned <= budget else { fail("author-play memory admission declined") }
  let sim = b.open_mjlab(path)
  let starts = sim.exchange(16).values().map(x => x.to_int())
  let ends = sim.exchange(8).values().map(x => x.to_int() - 1)
  assert_eq(
    (starts.length(), ends.length(), starts[0], ends[n - 1] + 1),
    (n, n, 0, catalog.frames),
  )
  for i in 1..<n {
    assert_eq(starts[i], ends[i - 1] + 1)
  }
  let maximum = sim.exchange(18).values()[0]
  assert_true((maximum - 0.1).abs() < 1.0e-6)
  let gpu_refs = b.concat(Array::makei(6, i => sim.exchange(9 + i)), axis=1)
  let all = cpu_rows(b, [catalog.frames, 71], gpu_refs.values())
  let scale = sim.exchange(0).values()
  let offset = sim.exchange(1).values()
  let (policy, steps) = load_play_policy(job, b, all, scale, offset)
  let previous = Array::makei(n, _ => Array::make(29, 0.0))
  let trials : Array[@aligned.ClipEvaluation] = Array::makei(n, i => {
    clip_id: names[i],
    expected_steps: ends[i] - starts[i] + 1,
    rewards: [],
    terminated: false,
    termination_frame: None,
    strict_rmse: None,
  })
  let active = Array::make(n, true)
  let initial_state = sim.exchange(2).values()
  let expected = all.index_select(frame_ids(b, starts)).values()
  guard read_play_json(job.layout) is Object(layout) else {
    fail("missing play bounds")
  }
  let kin : @aligned.Kinematics = @json.from_json(layout["geometry"])
  let mut reset_error = 0.0
  for i in 0..<n {
    for j in 0..<71 {
      let idx = i * 71 + j
      let reference = if j >= 13 && j < 42 {
        // Upstream reset_to_frame clamps joint positions to the asset's soft limits.
        expected[idx].max(kin.q_lo[j - 13]).min(kin.q_hi[j - 13])
      } else {
        expected[idx]
      }
      let error = (initial_state[idx] - reference).abs()
      guard @numeric.finite(error) && error <= 2.0e-5 else {
        fail("stale or inconsistent observations after motion seek")
      }
      reset_error = reset_error.max(error)
    }
  }
  let initial_context = sim.exchange(3).values()
  let initial_bias = sim.exchange(17).values()
  let longest = trials.fold(init=0, (m, r) => m.max(r.expected_steps))
  for t in 0..<longest {
    if !active.contains(true) {
      break
    }
    let cursor = sim.exchange(4).values().map(v => v.to_int())
    for i in 0..<n {
      if active[i] {
        assert_eq(cursor[i], starts[i] + t)
      } else {
        cursor[i] = starts[i]
      }
    }
    let actions = policy.actions(
      b,
      sim.exchange(2).values(),
      cursor,
      ends,
      active,
      sim.exchange(17).values(),
      previous,
    )
    guard actions.length() == 29 * n && actions.all(@numeric.finite) else {
      fail("invalid policy actions")
    }
    let result = sim
      .exchange(
        6,
        input=b.from_values(
          [n, 29],
          actions,
          cuda_device=0,
          dtype=Float32,
          requires_grad=false,
        ),
      )
      .values()
    for i in 0..<n {
      if active[i] {
        let r = trials[i]
        let reward = result[i * 5]
        assert_true(@numeric.finite(reward))
        r.rewards.push(reward)
        if result[i * 5 + 1] != 0.0 {
          let fell = result[i * 5 + 2] != 0.0
          let end_ = result[i * 5 + 3] != 0.0
          guard (fell || end_) && result[i * 5 + 4] == 0.0 else {
            fail("unexpected author-play timeout")
          }
          if end_ {
            assert_eq(t + 1, r.expected_steps)
          }
          trials[i] = {
            ..r,
            terminated: fell,
            termination_frame: if fell {
              Some(t + 1)
            } else {
              None
            },
          }
          active[i] = false
        }
      }
    }
  }
  guard !active.contains(true) else { fail("incomplete author-play rollout") }
  let scores = @aligned.summarize_evaluations(trials, expected_clip_ids=names)
  guard scores.benchmark_complete else { fail("incomplete panel score") }
  guard scores.report_json(names, {
      "robot": "unitree-g1",
      "backend": "mjlab-mujoco-warp",
    })
    is Object(fields) else {
    fail("invalid panel report")
  }
  fields["protocol"] = Json::object({
    "environment": "SuperMimic-GenCoord-G1 play defaults",
    "start": "published reset_to_frame at the first frame, one world per clip",
    "end": "first physical failure or author motion_end timeout",
    "reward": "original mjlab reward before command advancement",
    "normalization": "sum / (author-converted frames * maximum step reward), equal clip weights",
    "max_step_reward": Json(maximum),
  })
  fields["panel_sha256"] = Json(@artifacts.sha256(panel_bytes))
  fields["reference_sha256"] = Json(catalog.manifest_sha256)
  fields["policy_kind"] = Json(job.policy_kind)
  fields["checkpoint_counter"] = Json(steps)
  fields["seed"] = Json(job.seed)
  fields["initial_reference_max_abs"] = Json(reset_error)
  fields["initial_state"] = Json(initial_state)
  fields["initial_context"] = Json(initial_context)
  fields["initial_encoder_bias"] = Json(initial_bias)
  @fs.write_string_to_file(job.output, Json::object(fields).stringify())
}
