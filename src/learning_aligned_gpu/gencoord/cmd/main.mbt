///|
struct Config {
  plugin : String
  device : String
  seed : Int32
  environments : Int32
  motion_file : String
  layout : String
  output : String
  steps : Int32
  save_interval : Int32
  world_batch : Int32
  actor_batch : Int32
  actor_microbatch : Int32
  replay_capacity : Int32
  memory_probe : String?
} derive(@json.FromJson, ToJson)

///|
struct Layout {
  geometry : @aligned.Kinematics
  context_dim : Int32
  decimation : Int32
  dt : Double
  frames : Int32
  bins : Int32
  height : Double
  tilt : Double
  joint_names : Array[String]
} derive(@json.FromJson)

///|
struct Corpus {
  frames : Int32
  clips : Int32
  manifest_sha256 : String
  source_host_bytes : Int64?
} derive(@json.FromJson)

///|
async fn inspect_motion(source : String) -> Corpus {
  let sidecar = source + "/source.json"
  if @fs.path_exists(sidecar) {
    return @json.from_json(@json.parse(@fs.read_file_to_string(sidecar)))
  }
  guard @env.get_env_var("MOONROBO_MJLAB_PYTHON") is Some(python) else {
    fail(
      "set MOONROBO_MJLAB_PYTHON to the physics venv for native mjlab motion inputs",
    )
  }
  let (code, out, err) = @process.collect_output(python, [
    "-c", "import json,sys; from motion_source import inspect; print(json.dumps(inspect(sys.argv[1])))",
    source,
  ])
  guard code == 0 else { fail("mjlab motion inspection: " + err.text()) }
  @json.from_json(@json.parse(out.text()))
}

///|
fn clip_ends(
  times : @tensor.Tensor,
  ends : Array[Int32],
) -> @tensor.Tensor raise {
  let values = times
    .values()
    .map(x => {
      let time = x.to_int()
      guard time >= 0 && time < ends[ends.length() - 1] else {
        fail("reference cursor outside library")
      }
      let mut lo = 0
      let mut hi = ends.length() - 1
      while lo < hi {
        let mid = lo + (hi - lo) / 2
        if ends[mid] <= time {
          lo = mid + 1
        } else {
          hi = mid
        }
      }
      (ends[lo] - 1).to_double()
    })
  times.backend.from_values(
    [values.length()],
    values,
    cuda_device=times.cuda_device(),
    dtype=Int64,
    requires_grad=false,
  )
}

///|
/// GB10 has shared host/device memory. Account for device allocations once
/// against both observations. Preserve the production 80% limit and 16 GiB floor.
async fn admit(b : @tensor.Backend, peak : Int64, phase : String) -> Unit {
  let remaining = @linuxmem.host_available().min(b.cuda_free_bytes(0))
  let budget = (remaining / 100L * 80L).min(remaining - 17179869184L)
  println(
    Json::object({
      "phase": Json(phase),
      "free_bytes": Json(remaining),
      "planned_additional": Json(peak),
      "budget": Json(budget),
    }).stringify(),
  )
  guard peak > 0L && budget >= peak else {
    fail("memory admission declined " + phase)
  }
}

///|
struct MemorySample {
  physical_steps : Int32
  learner_updates : Int32
  manifest_sha256 : String
  cuda : @tensor.CudaMemoryStats
} derive(@json.FromJson)

///|
struct ProbeCheckpoint {
  format : String
  physical_steps : Int32
  updates : Int32
} derive(@json.FromJson)

///|
fn decode_config(raw : Json) -> Config raise {
  // Archived configs serialize an absent probe as JSON null.
  if raw is Object(fields) && fields.get("memory_probe") is Some(Null) {
    fields.remove("memory_probe")
  }
  @json.from_json(raw)
}

///|
fn actor_memory_budget(cfg : Config, corpus : Corpus) -> Int64 raise {
  let conservative = cfg.actor_microbatch.to_int64() * 32L * 1100000L
  guard cfg.memory_probe is Some(probe) else { return conservative }
  let read = (path : String) => {
    @json.parse(@fs.read_file_to_string(probe + "/" + path))
  }
  let prior = decode_config(read("run.json"))
  let start : MemorySample = @json.from_json(read("progress-1.json"))
  let warm : MemorySample = @json.from_json(read("progress-21.json"))
  let checkpoint : ProbeCheckpoint = @json.from_json(
    read("step-21/complete.json"),
  )
  guard checkpoint.format == "moonrobo.author-gencoord.weights.v2" &&
    checkpoint.physical_steps == 21 &&
    checkpoint.updates == warm.learner_updates &&
    prior.output == probe &&
    prior.plugin == cfg.plugin &&
    prior.device == cfg.device &&
    prior.seed == cfg.seed &&
    prior.environments == cfg.environments &&
    prior.world_batch == cfg.world_batch &&
    prior.actor_batch == cfg.actor_batch &&
    prior.replay_capacity == cfg.replay_capacity &&
    prior.motion_file == cfg.motion_file &&
    prior.actor_microbatch >= 512 &&
    cfg.actor_microbatch >= prior.actor_microbatch &&
    cfg.actor_microbatch <= 2 * prior.actor_microbatch &&
    start.physical_steps == 1 &&
    start.learner_updates == 0 &&
    warm.physical_steps == 21 &&
    warm.learner_updates >= 2 &&
    start.manifest_sha256 == corpus.manifest_sha256 &&
    warm.manifest_sha256 == corpus.manifest_sha256 &&
    warm.cuda.reserved_peak_bytes >= warm.cuda.allocated_peak_bytes &&
    warm.cuda.device == start.cuda.device &&
    warm.cuda.cuda_total_bytes == start.cuda.cuda_total_bytes &&
    warm.cuda.reserved_peak_bytes <= warm.cuda.cuda_total_bytes &&
    warm.cuda.reserved_peak_bytes > start.cuda.allocated_current_bytes else {
    fail("incompatible 4096-environment allocator calibration")
  }
  // Include allocator slack and lazy optimizer state in the measured envelope.
  // Increase at most 2x, with another 50% on top of the scaled observed peak.
  let envelope = warm.cuda.reserved_peak_bytes -
    start.cuda.allocated_current_bytes
  let forecast = envelope *
    cfg.actor_microbatch.to_int64() *
    3L /
    (prior.actor_microbatch.to_int64() * 2L)
  println(
    Json::object({
      "memory_probe": Json(probe),
      "measured_extra_bytes": Json(envelope),
      "prior_microbatch": Json(prior.actor_microbatch),
      "actor_microbatch": Json(cfg.actor_microbatch),
      "actor_budget_bytes": Json(forecast),
    }).stringify(),
  )
  forecast
}

///|
async fn run() -> Unit {
  guard @env.args() is [_, path] else {
    fail("usage: moonrobo-gencoord CONFIG.json")
  }
  let cfg = decode_config(@json.parse(@fs.read_file_to_string(path)))
  guard cfg.device == "cuda:0" &&
    cfg.environments > 0 &&
    cfg.environments <= 4096 &&
    cfg.world_batch > 0 &&
    cfg.world_batch <= 2048 &&
    cfg.actor_batch > 0 &&
    cfg.actor_batch <= 4096 &&
    cfg.actor_microbatch > 0 &&
    cfg.actor_microbatch <= cfg.actor_batch &&
    cfg.steps > 0 &&
    cfg.save_interval > 0 &&
    cfg.replay_capacity >= 8 &&
    cfg.replay_capacity <= 1000 &&
    !@fs.path_exists(cfg.output) else {
    fail("invalid run configuration or output already exists")
  }
  let corpus = inspect_motion(cfg.motion_file)
  let extra_host = corpus.source_host_bytes.unwrap_or(0L)
  guard corpus.frames > 0 && corpus.clips > 0 && extra_host >= 0L else {
    fail("empty G1 motion library")
  }
  let b = @tensor.Backend::open(cfg.plugin)
  let gib = 1073741824L
  // Source field transfer, simulator startup and CUDA/Warp compilation.
  let sim_peak = corpus.frames.to_int64() * 300L +
    cfg.environments.to_int64() * 5242880L +
    5L * gib
  guard extra_host <= @int64.max_value - sim_peak else {
    fail("motion source exceeds the addressable memory range")
  }
  admit(b, sim_peak + extra_host, "before-mjlab")
  @fs.create_dir(cfg.output)
  @fs.write_string_to_file(cfg.output + "/run.json", cfg.to_json().stringify())
  let sim = b.open_mjlab(path)
  let layout : Layout = @json.from_json(
    @json.parse(@fs.read_file_to_string(cfg.layout)),
  )
  guard layout.dt == 0.02 &&
    layout.context_dim > 0 &&
    corpus.frames == layout.frames &&
    layout.joint_names == @aligned.joint_names() else {
    fail("physical task, motion or joint layout mismatch")
  }
  let learned_peak = cfg.replay_capacity.to_int64() *
    cfg.environments.to_int64() *
    (4L * (129 + layout.context_dim).to_int64() + 12L) +
    actor_memory_budget(cfg, corpus) +
    cfg.world_batch.to_int64() * 7L * 130000L +
    cfg.actor_batch.to_int64() * 32L * 13000L +
    layout.bins.to_int64() * 100L +
    4L * gib
  admit(b, learned_peak, "before-learner")
  let refs = @gc.GenMotions::from_fields(
    b,
    Array::makei(6, i => sim.exchange(9 + i)),
  )
  let ends = sim.exchange(8).values().map(x => x.to_int())
  guard ends.length() == corpus.clips &&
    ends[ends.length() - 1] == corpus.frames else {
    fail("clip partition mismatch")
  }
  let model = @gc.GenModel::new(
    b,
    sim.exchange(0),
    sim.exchange(1),
    context_dim=layout.context_dim,
    device=0,
    dt=layout.dt,
    decimation=layout.decimation,
  )
  let reward = { ..@aligned.RewardConfig::default(), soft_limit_factor: 1.0, }
  let learner = @gc.GenLearner::new(
    model,
    @geometry.Context::new(
      b,
      layout.geometry,
      0,
      reward_cfg=reward,
      body_orientation_batched=true,
    ),
  )
  let replay = @gc.GenReplay::new(
    model.scale,
    sim.exchange(4),
    cfg.environments,
    layout.context_dim,
    cap=cfg.replay_capacity,
  )
  let sampler = @gc.DeviceReset::new(
    model.scale,
    layout.bins,
    layout.frames,
    cfg.environments,
    layout.dt,
  )
  let ratio = cfg.environments.to_double() /
    10.0 /
    cfg.world_batch.to_double() /
    8.0 *
    16.0
  ignore(sim.exchange(15))
  let mut prev = 0.0
  let mut updates = 0
  let mut world = 0.0
  let mut actor = 0.0
  let mut critic = 0.0
  for step in 0..<cfg.steps {
    let flat = sim.exchange(2)
    let state = @gc.GenState::from_replay(b, flat)
    let ctx = sim.exchange(3)
    let time = sim.exchange(4)
    let goal = state.goals(b, refs.window(time, clip_ends(time, ends)))
    let action = model.act(state, goal).stop_gradient()
    let previous = sim.exchange(5)
    let physical = sim.exchange(6, input=action)
    let results = physical.values()
    let done_ = Array::makei(cfg.environments, i => results[i * 5 + 1] != 0.0)
    replay.insert(b, flat, action, previous, ctx, time, done_)
    if sampler.record(time.values().map(t => t.to_int()), results, physical)
      is Some(weights) {
      ignore(sim.exchange(7, input=weights))
    }
    model.observe(state, action, goal)
    let repeats = if step == 0 {
      1
    } else {
      ((step.to_double() - prev) * ratio).to_int()
    }
    if step > 0 {
      prev += repeats.to_double() / ratio
    }
    if step + 1 >= 8 {
      for _ in 0..<repeats {
        world = 0.0
        for _ in 0..<10 {
          world += replay.fit_world(learner, cfg.world_batch) / 10.0
        }
        let (initial, prev_action, context, start) = replay.actor_start(
          cfg.actor_batch,
        )
        let (ret, v) = learner.improve(
          refs,
          initial,
          prev_action,
          context,
          start,
          clip_ends(start, ends),
          start.randperm(cfg.actor_batch * 32),
          height=layout.height,
          tilt=layout.tilt,
          microbatch=cfg.actor_microbatch,
        )
        actor = ret
        critic = v
        updates += 1
      }
    }
    if step % 10 == 0 || step + 1 == cfg.steps {
      let mean_reward = results.foldi(init=0.0, (i, sum, x) => {
          if i % 5 == 0 {
            sum + x
          } else {
            sum
          }
        }) /
        cfg.environments.to_double()
      let metric = Json::object({
        "physical_steps": Json(step + 1),
        "learner_updates": Json(updates),
        "world_loss": Json(world),
        "imagined_return": Json(actor),
        "critic_loss": Json(critic),
        "physical_step_reward": Json(mean_reward),
        "manifest_sha256": Json(corpus.manifest_sha256),
        "cuda": if b.has_cuda_memory_telemetry() {
          b.cuda_memory_stats(0).to_json()
        } else {
          Json::object({ "cuda_free_bytes": Json(b.cuda_free_bytes(0)) })
        },
      }).stringify()
      @fs.write_string_to_file(
        cfg.output + "/progress-" + (step + 1).to_string() + ".json",
        metric,
      )
      println(metric)
    }
    if ((step + 1) % cfg.save_interval == 0 || step + 1 == cfg.steps) &&
      updates > 0 {
      learner.save_weights(
        cfg.output + "/step-" + (step + 1).to_string(),
        updates,
        step + 1,
      )
    }
  }
}

///|
async fn main {
  run() catch {
    @tensor.TensorError::Native(message) =>
      fail("GenCoord LibTorch/mjlab: " + message)
    e => raise e
  }
}
