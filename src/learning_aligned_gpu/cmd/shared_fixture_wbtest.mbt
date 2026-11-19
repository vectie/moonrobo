///|
// Isolated, opt-in cross-language measurement. It never changes train defaults.
struct SharedTensor {
  name : String
  blob : @stream.BlobDescriptor
} derive(ToJson, FromJson)

///|
struct SharedFixture {
  schema : String
  metadata : @gpu.CheckpointMetadata
  records : Array[SharedTensor]
  source_checkpoint : String?
} derive(ToJson, FromJson)

///|
extern "C" fn shared_clock_ms() -> Double = "moonrobo_shared_monotonic_ms"

///|
async fn shared_write(
  root : String,
  name : String,
  t : @tensor.Tensor,
) -> SharedTensor {
  let shape = t.shape()
  let flat = t.stop_gradient().reshape([-1])
  guard flat.shape()[0] <= 16777216 else {
    fail("shared tensor exceeds 16M values")
  }
  let blob = @stream.write_f64le(root, name + ".f64", shape, (offset, count) => {
    let values = flat.narrow(0, offset.to_int(), count).values()
    guard values.all(@numeric.finite) else { fail("nonfinite shared fixture") }
    values
  })
  { name, blob, }
}

///|
async fn shared_json(path : String, value : Json) -> Unit {
  @fs.write_file(path, value.stringify(indent=2) + "\n", create_mode=CreateNew)
}

///|
async fn shared_read(
  root : String,
  fixture : SharedFixture,
  backend : @tensor.Backend,
  name : String,
  integer~ : Bool = false,
) -> @tensor.Tensor {
  let selected = fixture.records.filter(r => r.name == name)
  guard selected is [record] && record.blob.count <= 16777216L else {
    fail("missing/oversized shared input " + name)
  }
  let values = FixedArray::make(record.blob.count.to_int(), 0.0)
  @stream.read_f64le(root, record.blob, (offset, data) => {
    for i, value in data {
      values[offset.to_int() + i] = value
    }
  })
  backend.from_fixed_values(
    record.blob.shape,
    values,
    cuda_device=0,
    requires_grad=false,
    dtype=if integer { Int64 } else { Float32 },
  )
}

///|
async fn shared_snapshot(
  root : String,
  learner : @gpu.Learner,
  active : String,
) -> Json {
  let records = []
  let optimizers = [learner.opt_world, learner.opt_policy, learner.opt_critic]
  for i, name in ["world", "policy", "critic"] {
    let opt = optimizers[i]
    let parameters = match i {
      0 => learner.world.net.parameters()
      1 => learner.policy.parameters()
      _ => learner.critic.net.parameters()
    }
    for j, p in parameters {
      records.push(shared_write(root, "\{name}-\{j}-parameter", p))
      if active == name || (active == "actor" && i > 0) {
        records.push(shared_write(root, "\{name}-\{j}-gradient", p.gradient()))
      }
      let info = @json.parse(opt.audit_metadata())
      guard info is { "states": Array(states), .. } else { fail("Adam audit") }
      if states[j] is { "present": True, .. } {
        records.push(
          shared_write(
            root,
            "\{name}-\{j}-moment1",
            opt.audit_tensor(j, kind=1),
          ),
        )
        records.push(
          shared_write(
            root,
            "\{name}-\{j}-moment2",
            opt.audit_tensor(j, kind=2),
          ),
        )
      }
    }
  }
  {
    "records": Json(records),
    "optimizer_metadata": Json(
      optimizers.map(o => @json.parse(o.audit_metadata())),
    ),
    "metadata": Json(learner.checkpoint_metadata()),
  }
}

///|
async test "shared-input paper-width isolated comparison" {
  guard @env.get_env_var("MOONROBO_SHARED_MODE") is Some(mode) else { return }
  guard ["export", "export-trained", "world", "actor"].contains(mode) else {
    fail("shared mode")
  }
  let observer = @env.get_env_var("MOONROBO_SHARED_OBSERVER").unwrap_or("off")
  guard ["off", "events", "ranges", "aten"].contains(observer) else {
    fail("shared observer")
  }
  let input = @env.get_env_var("MOONROBO_SHARED_INPUT").unwrap()
  let output = @env.get_env_var("MOONROBO_SHARED_OUTPUT").unwrap()
  guard input.has_prefix("/") &&
    output.has_prefix("/") &&
    !@fs.exists(output + "/result.json") else {
    fail("fresh absolute shared paths required")
  }
  let backend = @tensor.Backend::open(
    @env.get_env_var("MOONROBO_TENSOR_LIBRARY").unwrap(),
  )
  ignore(
    backend.configure_cuda_tf32(
      matmul=true,
      cudnn_conv=true,
      cudnn_rnn=true,
      before_first_tensor=true,
    ),
  )
  guard backend.cuda_free_bytes(0) > 68719476736L else {
    fail("shared fixture requires 64GiB free including 16GiB reserve")
  }
  let model = @sim.Runtime::open(
    "/opt/isaaclab-venv/lib/python3.12/site-packages/mujoco/libmujoco.so.3.15.0",
    "/workspace/moonrobo/data/g1_description/scene-no-self-collision.xml",
    require_position_servos=false,
  )
  let context = @geometry.Context::new(
    backend,
    @tracking.kinematics(model),
    0,
    body_orientation_batched=true,
  )
  let config : @aligned.LearnerConfig = {
    ..@aligned.LearnerConfig::default(),
    policy_batch: 4096,
    wm_batch: 2048,
    wm_batches: 1,
  }
  let learner = @gpu.Learner::new(
    backend,
    context,
    config~,
    mode=@aligned.Smc,
    cuda_device=0,
    actor_microbatch=512,
    optimizations={
      ..@gpu.ExecutionOptimizations::default(),
      reuse_geometry: true,
      body_orientation_batched: true,
      adam_checked_norm: true,
    },
  )
  let upload = (shape, values) => {
    backend.from_values(
      shape,
      values,
      cuda_device=0,
      requires_grad=false,
      dtype=Float32,
    )
  }
  if mode == "export-trained" {
    shared_export_trained(output, learner, model)
    return
  }
  if mode == "export" {
    let defaults = @aligned.default_joint_positions()
    let state = upload(
      [4096, 71],
      Array::makei(4096 * 71, i => {
        let j = i % 71
        let row = i / 71
        match j {
          0 | 1 => 0.01 * (row % 9 - 4).to_double() * (j + 1).to_double()
          2 => 0.76 + 0.002 * (row % 5).to_double()
          3 => 1.0
          4..<7 => 0.01 * ((row + j) % 11 - 5).to_double()
          7..<10 => 0.03 * (row % 13 - 6).to_double() * (j - 6).to_double()
          10..<13 => 0.02 * (row % 9 - 4).to_double() * (j - 9).to_double()
          13..<42 => defaults[j - 13] + (row % 17 - 8).to_double() * 0.0002
          _ => 0.05 * ((row + j) % 7 - 3).to_double()
        }
      }),
    )
    let xi = upload(
      [4096, 33],
      Array::makei(4096 * 33, i => if i % 33 == 0 { 0.75 } else { 0.0 }),
    )
    let next = backend.concat([state.narrow(0, 1, 4095), state.narrow(0, 0, 1)])
    let world : @gpu.WorldBatch = {
      s: backend.concat(Array::make(4, state)).reshape([2048, 8, 71]),
      s1: backend.concat(Array::make(4, next)).reshape([2048, 8, 71]),
      actions: upload(
        [2048, 8, 29],
        Array::makei(2048 * 8 * 29, i => 0.001 * (i % 23 - 11).to_double()),
      ),
      xi: backend.concat(Array::make(4, xi)).reshape([2048, 8, 33]),
      mask: upload(
        [2048, 8],
        Array::makei(2048 * 8, i => if i % 13 == 0 { 0.0 } else { 1.0 }),
      ),
    }
    learner.observe(
      world.s.reshape([-1, 71]),
      world.actions.reshape([-1, 29]),
      world.xi.reshape([-1, 33]),
      world.s1.reshape([-1, 71]),
    )
    // Nonzero dynamics output weights and allocated Adam state before measurement.
    ignore(learner.fit_world_batch(world))
    let previous = upload([4096, 29], Array::make(4096 * 29, 0.0))
    let ref_state = @geometry.State::from_flat71(backend, state)
    let history = backend.stack(
      Array::make(
        10,
        context.observation(ref_state, previous, xi, ref_state, @aligned.Smc),
      ),
      axis=1,
    )
    let goal = upload(
      [4096, 730],
      Array::makei(4096 * 730, i => 0.002 * (i % 31 - 15).to_double()),
    )
    learner.policy.update_normalizers(history.reshape([-1, 99]), goal)
    let records = []
    for
      (name, value) in [
        ("world-s", world.s),
        ("world-s1", world.s1),
        ("world-actions", world.actions),
        ("world-xi", world.xi),
        ("world-mask", world.mask),
        ("state", state),
        ("xi", xi),
        ("previous", previous),
        ("history", history),
        ("goal", goal),
        (
          "noise",
          upload(
            [4096, 99],
            Array::makei(4096 * 99, i => 0.001 * (i % 17 - 8).to_double()),
          ),
        ),
      ] {
      records.push(shared_write(output, name, value))
    }
    for epoch in 0..<5 {
      records.push(
        shared_write(
          output,
          "order-\{epoch}",
          backend.from_values(
            [131072],
            Array::makei(131072, i => {
              ((i * 37 + epoch * 17) % 131072).to_double()
            }),
            cuda_device=0,
            requires_grad=false,
            dtype=Int64,
          ),
        ),
      )
    }
    learner.save_optimizers(output)
    shared_json(
      output + "/initial.json",
      shared_snapshot(output, learner, "none"),
    )
    shared_json(
      output + "/fixture.json",
      Json(SharedFixture::{
        schema: "moonrobo.shared-compute-fixture.v1",
        metadata: learner.checkpoint_metadata(),
        records,
        source_checkpoint: None,
      }),
    )
    shared_json(output + "/result.json", {
      "exported": true,
      "synthetic_controlled_inputs": true,
      "not_training_trajectory_or_throughput_result": true,
    })
    return
  }
  let fixture : SharedFixture = @json.from_json(
    @json.parse(@fs.read_file(input + "/fixture.json").text()),
  )
  guard fixture.schema == "moonrobo.shared-compute-fixture.v1" else {
    fail("fixture schema")
  }
  let world : @gpu.WorldBatch = {
    s: shared_read(input, fixture, backend, "world-s"),
    s1: shared_read(input, fixture, backend, "world-s1"),
    actions: shared_read(input, fixture, backend, "world-actions"),
    xi: shared_read(input, fixture, backend, "world-xi"),
    mask: shared_read(input, fixture, backend, "world-mask"),
  }
  let state = shared_read(input, fixture, backend, "state")
  let references = []
  let goals = []
  let noises = []
  if fixture.source_checkpoint is Some(_) {
    for t in 0..<33 {
      references.push(@geometry.State::{
        p: shared_read(input, fixture, backend, "reference-\{t}-p"),
        rotation: shared_read(input, fixture, backend, "reference-\{t}-r"),
        v: shared_read(input, fixture, backend, "reference-\{t}-v"),
        w: shared_read(input, fixture, backend, "reference-\{t}-w"),
        q: shared_read(input, fixture, backend, "reference-\{t}-q"),
        qd: shared_read(input, fixture, backend, "reference-\{t}-qd"),
      })
      goals.push(shared_read(input, fixture, backend, "goal-\{t}"))
      if t < 32 {
        noises.push(shared_read(input, fixture, backend, "noise-\{t}"))
      }
    }
  } else {
    references.append(
      Array::make(33, @geometry.State::from_flat71(backend, state)),
    )
    goals.append(Array::make(33, shared_read(input, fixture, backend, "goal")))
    noises.append(
      Array::make(32, shared_read(input, fixture, backend, "noise")),
    )
  }
  let packed = backend.stack(
    references.map(r => context.pack_reference_bodies(r)),
  )
  let orders = []
  for i in 0..<5 {
    orders.push(
      shared_read(input, fixture, backend, "order-\{i}", integer=true),
    )
  }
  let policy : @gpu.PolicyBatch = {
    state,
    previous: shared_read(input, fixture, backend, "previous"),
    xi: shared_read(input, fixture, backend, "xi"),
    history: shared_read(input, fixture, backend, "history"),
    references,
    goals,
    step_noise: noises,
    critic_orders: orders,
    reference_fk: Some(packed),
  }
  let rows : Array[Json] = []
  // Every repetition restores identical weights, Adam moments and normalizers.
  // Restore/IO, memory inspection and JSON writes are outside the timed window.
  let repetitions = if @env.get_env_var("MOONROBO_SHARED_REPETITIONS") ==
    Some("1") {
    1
  } else {
    13
  }
  for iteration in 0..<repetitions {
    learner.load_optimizers(input)
    learner.restore_metadata(fixture.metadata)
    hotspot_gate_memory(backend, "shared-before")
    let observing = observer != "off" && iteration >= 3
    if observing {
      @tensor.configure_profiling(
        backend,
        cuda_device=if observer == "events" { 0 } else { -1 },
        max_spans=512,
        nvtx=observer != "events",
      )
    }
    if observing && observer == "aten" {
      @tensor.configure_operator_diagnostics(
        backend,
        cuda_device=0,
        iteration=1,
        phase="world",
        observer~,
        max_ranges=65536,
      )
    }
    let diagnostic = @tensor.operator_diagnostic_iteration_begin(
      1,
      phase="world",
    )
    let capture = if observing && iteration == 3 {
      @tensor.profile_begin("shared.compute.capture")
    } else {
      0L
    }
    let start = shared_clock_ms()
    let metrics : Array[Double] = if mode == "world" {
      let m = learner.fit_world_batch(world)
      [m.wm_loss, m.wm_error_last]
    } else {
      let m = learner.update_policy(policy)
      [m.policy_loss, m.critic_loss, m.imagined_reward, m.imagined_survival]
    }
    let submitted = shared_clock_ms()
    ignore(backend.cuda_memory_stats(0, synchronize=true))
    let drained = shared_clock_ms()
    @tensor.profile_end(capture)
    @tensor.operator_diagnostic_iteration_end(diagnostic)
    let profile = if observing {
      @json.parse(@tensor.profiling_report())
    } else {
      Json::null()
    }
    let diagnostics = if observing && observer == "aten" {
      @json.parse(@tensor.operator_diagnostics_report())
    } else {
      Json::null()
    }
    @tensor.clear_profiling()
    @tensor.clear_operator_diagnostics()
    rows.push({
      "iteration": Json(iteration),
      "steady": Json(iteration >= 3),
      "observer_active": Json(observing),
      "host_call_ms": Json(submitted - start),
      "drain_ms": Json(drained - submitted),
      "wall_ms": Json(drained - start),
      "metrics": Json(metrics),
      "profile": profile,
      "diagnostics": diagnostics,
    })
    println("SHARED_ROW \{iteration} \{drained - start}")
  }
  hotspot_gate_memory(backend, "shared-after")
  shared_json(
    output + "/final.json",
    shared_snapshot(
      output,
      learner,
      if mode == "world" {
        "world"
      } else {
        "actor"
      },
    ),
  )
  shared_json(output + "/result.json", {
    "schema": "moonrobo.shared-compute-result.v1",
    "implementation": "moonbit",
    "phase": Json(mode),
    "observer": Json(observer),
    "rows": Json(rows),
    "same_initial_state_each_repeat": true,
    "synthetic_controlled_inputs": Json(fixture.source_checkpoint is None),
    "source_checkpoint": Json(fixture.source_checkpoint),
    "includes_sampling_or_upload": false,
    "host_call_includes_implicit_waits": true,
    "cpu_and_stream_elapsed_overlap": true,
    "memory": Json(backend.cuda_memory_stats(0, synchronize=true)),
  })
}

///|
async fn shared_export_trained(
  root : String,
  learner : @gpu.Learner,
  model : @sim.Runtime,
) -> Unit {
  let source = "/workspace/moonrobo/runs/hotspot-followup-measured-world-20261026-c/run-0/train/generation-60-1792982719679"
  let saved : StreamGeneration = @json.from_json(
    @json.parse(@fs.read_file(source + "/state.json").text()),
  )
  guard saved.runtime.iteration == 60 &&
    saved.runtime.num_envs == 256 &&
    saved.runtime.capacity == 1000 else {
    fail("fixed trained fixture identity")
  }
  let backend = learner.backend
  learner.load_optimizers(source)
  // wm_batches controls the outer driver only; architecture/Adam are unchanged.
  guard { ..saved.learner.config, wm_batches: 1, }.to_json() ==
    learner.config.to_json() else {
    fail("trained fixture network/protocol mismatch")
  }
  learner.restore_metadata({ ..saved.learner, config: learner.config, })
  let replay = @aligned.ReplayBuffer::new(1000, 256).prepare_checkpoint_v2(
    source,
    saved.runtime.replay,
    _ => (),
  )
  let limits : @runner.BatchLimits = {
    max_reference_frames: 135168,
    max_tensor_values: 127016960L,
  }
  let loaded = @aligned.load_motion_manifest(
    "/workspace/moonrobo/data/manifest.json",
    @tracking.kinematics(model),
    split="train",
    compute_body_features=true,
    storage="mmap",
    cache_dir="/motion-cache",
    max_gather_frames=135168,
  )
  let catalog = @json.parse(@fs.read_file(source + "/catalog.json").text())
  guard catalog is { "motion_names": names, "motion_sha256": hashes, .. } &&
    names == Json(loaded.motion.names) &&
    hashes == Json(loaded.motion.source_sha256) else {
    fail("trained motion catalog differs")
  }
  // Exact source-run cap: 1376MiB for states/goals; FK has its separate existing
  // 512MiB hard cap inside ResidentReferences. Do not conflate the two budgets.
  let references = @runner.ResidentReferences::new(
    backend,
    loaded.motion,
    10,
    cuda_device=0,
    max_bytes=1442840576L,
    limits~,
    reference_context=Some(learner.context),
  )
  let rng = @numeric.Rng::new(saved.runtime.rng)
  let world = @runner.sample_world_batch(
    backend,
    replay,
    learner.config,
    rng,
    cuda_device=0,
    limits~,
    staging_max_bytes=Some(134217728L),
  )
  let policy = @runner.sample_policy_batch(
    backend,
    replay,
    loaded.motion,
    learner.config,
    @aligned.Smc,
    rng,
    cuda_device=0,
    limits~,
    resident_references=Some(references),
    noise_staging_max_bytes=Some(16777216L),
  )
  let records = []
  for
    (name, value) in [
      ("world-s", world.s),
      ("world-s1", world.s1),
      ("world-actions", world.actions),
      ("world-xi", world.xi),
      ("world-mask", world.mask),
      ("state", policy.state),
      ("xi", policy.xi),
      ("previous", policy.previous),
      ("history", policy.history),
    ] {
    records.push(shared_write(root, name, value))
  }
  for t, reference in policy.references {
    for
      (key, value) in [
        ("p", reference.p),
        ("r", reference.rotation),
        ("v", reference.v),
        ("w", reference.w),
        ("q", reference.q),
        ("qd", reference.qd),
      ] {
      records.push(shared_write(root, "reference-\{t}-\{key}", value))
    }
    records.push(shared_write(root, "goal-\{t}", policy.goals[t]))
    if t < 32 {
      records.push(shared_write(root, "noise-\{t}", policy.step_noise[t]))
    }
  }
  for i, order in policy.critic_orders {
    records.push(shared_write(root, "order-\{i}", order))
  }
  learner.save_optimizers(root)
  shared_json(root + "/initial.json", shared_snapshot(root, learner, "none"))
  shared_json(
    root + "/fixture.json",
    Json(SharedFixture::{
      schema: "moonrobo.shared-compute-fixture.v1",
      metadata: learner.checkpoint_metadata(),
      records,
      source_checkpoint: Some(source),
    }),
  )
  shared_json(root + "/result.json", {
    "exported": true,
    "synthetic_controlled_inputs": false,
    "source_checkpoint": Json(source),
    "source_iteration": 60,
    "source_rng": Json(saved.runtime.rng),
    "sampling_order": "one world batch then one actor batch; both isolated measurements restore the iteration60 model, not a continuation",
    "not_training_trajectory_or_throughput_result": true,
  })
}
