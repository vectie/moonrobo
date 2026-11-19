///|
extern "c" fn monotonic_ns() -> Int64 = "mr_bucket_benchmark_monotonic_ns"

///|
struct Ticket {
  session : String
  id : Array[Int32]
} derive(ToJson, FromJson)

///|
struct Progress {
  mut stage : String
  mut rank : Int32
}

///|
async fn memlock_limits() -> Json {
  let file = @fs.open("/proc/self/limits", mode=ReadOnly)
  defer file.close()
  parse_memlock(file.read_all().text())
}

///|
fn parse_memlock(source : String) -> Json raise {
  guard source.length() <= 16384 else { fail("oversized process limits") }
  for line in source.split("\n") {
    if line.has_prefix("Max locked memory") {
      let words = line.split(" ").filter(x => x != "").to_array()
      guard words.length() == 6 && words[5] == "bytes" else {
        fail("unexpected memlock limits format")
      }
      let soft = @string.parse_int64(words[3])
      let hard = @string.parse_int64(words[4])
      guard soft >= 1073741824L && soft <= hard && hard <= 8589934592L else {
        fail(
          "NCCL requires bounded memlock soft/hard limits of 1..8 GiB; use --ulimit memlock=1073741824:1073741824",
        )
      }
      return { "soft_bytes": Json(soft), "hard_bytes": Json(hard) }
    }
  }
  fail("Max locked memory not found in /proc/self/limits")
}

///|
struct Group {
  name : String
  parameters : Array[@tensor.Tensor]
  updates : Int32
}

///|
fn expected_shapes(
  dims : Array[Int32],
  layer_norm : Bool,
) -> Array[Array[Int32]] {
  let shapes = []
  for i in 0..<(dims.length() - 1) {
    shapes.push([dims[i + 1], dims[i]])
    shapes.push([dims[i + 1]])
    if layer_norm && i + 2 < dims.length() {
      shapes.push([dims[i + 1]])
      shapes.push([dims[i + 1]])
    }
  }
  shapes
}

///|
fn paper_shapes() -> Array[Array[Array[Int32]]] {
  [
    expected_shapes([133, 2048, 2048, 2048, 70], true),
    expected_shapes([730, 2048, 1024, 512, 256, 32], false) +
    expected_shapes([962, 2048, 1024, 512, 256, 29], false),
    expected_shapes([914, 256, 128, 1], false),
  ]
}

///|
fn elements(shape : Array[Int32]) -> Int64 {
  shape.fold(init=1L, (n, width) => n * width.to_int64())
}

///|
fn layout_report(shapes : Array[Array[Int32]], updates : Int32) -> Json {
  let total = shapes.fold(init=0L, (n, shape) => n + elements(shape))
  let legacy = shapes.fold(init=0L, (n, shape) => {
    n + (elements(shape) + 4194303L) / 4194304L
  })
  let buckets = (total + 4194303L) / 4194304L
  {
    "ordered_shapes": Json(shapes),
    "parameter_count": Json(shapes.length()),
    "elements": Json(total),
    "payload_bytes": Json(total * 4L),
    "updates_per_schedule": updates,
    "legacy_collectives_per_update": Json(legacy),
    "bucket_collectives_per_update": Json(buckets),
    "legacy_collectives_per_schedule": Json(legacy * updates.to_int64()),
    "bucket_collectives_per_schedule": Json(buckets * updates.to_int64()),
  }
}

///|
fn model_groups(backend : @tensor.Backend) -> Array[Group] raise {
  let rng = @numeric.Rng::new(179U)
  let world = @gpu.WorldModel::new(backend, rng, cuda_device=0)
  let policy = @gpu.Policy::new(backend, 93, 730, rng, cuda_device=0, hist=10)
  let critic = @gpu.Critic::new(backend, 914, rng, cuda_device=0)
  let groups = [
    { name: "world", parameters: world.net.parameters(), updates: 10, },
    { name: "policy", parameters: policy.parameters(), updates: 1, },
    { name: "critic", parameters: critic.net.parameters(), updates: 20, },
  ]
  let expected = paper_shapes()
  for i, group in groups {
    guard group.parameters.map(p => p.shape()) == expected[i] else {
      fail(
        "actual network parameter order/shapes no longer match fixed paper benchmark: " +
        group.name,
      )
    }
    guard group.parameters.all(p => p.dtype() == Float32) else {
      fail("bucket benchmark requires FP32 parameters")
    }
  }
  groups
}

///|
fn prepare_gradients(groups : Array[Group], rank : Int32) -> Unit raise {
  for group in groups {
    for p in group.parameters {
      p.zero_gradient()
    }
    let first = group.parameters[0]
    let mut loss = first.mean().affine((rank + 1).to_double() / 16.0)
    for i in 1..<group.parameters.length() {
      loss = loss.add(
        group.parameters[i]
        .mean()
        .affine(((i + 1) * (rank + 1)).to_double() / 16.0),
      )
    }
    loss.backward()
  }
}

///|
fn check_memory(snapshot : @tensor.CudaMemoryStats) -> Unit raise {
  guard snapshot.allocated_peak_bytes <= 1090519040L &&
    snapshot.reserved_peak_bytes <= 1090519040L &&
    snapshot.cuda_free_bytes >= 17179869184L else {
    fail(
      "bucket benchmark exceeded 1 GiB + 16 MiB allocator budget or 16 GiB free reserve",
    )
  }
}

///|
fn schedule(
  backend : @tensor.Backend,
  collective : @tensor.Collective,
  groups : Array[Group],
  bucketed : Bool,
  label : String,
  measured : Bool,
  progress : Progress,
) -> Json raise {
  progress.stage = label + (if bucketed { ".bucket" } else { ".legacy" })
  let first = monotonic_ns()
  guard first > 0L else { fail("monotonic clock unavailable") }
  let whole = if measured {
    @tensor.profile_begin(label + ".schedule")
  } else {
    0L
  }
  errdefer @tensor.profile_cancel(whole)
  let phases : Map[String, Json] = Map([])
  for group in groups {
    progress.stage = label +
      (if bucketed { ".bucket." } else { ".legacy." }) +
      group.name
    let began = monotonic_ns()
    let token = if measured {
      @tensor.profile_begin(label + "." + group.name)
    } else {
      0L
    }
    errdefer @tensor.profile_cancel(token)
    for _ in 0..<group.updates {
      if bucketed {
        collective.average_gradients_bucketed(
          group.parameters,
          bucket_bytes=16777216,
        )
      } else {
        collective.average_gradients(group.parameters)
      }
    }
    @tensor.profile_end(token)
    // Identical completion boundary on both routes; finishes final division or
    // scatter. Host timing includes this telemetry/sync call, CUDA events do not
    // include the subsequent host counter queries. Neither is kernel-active time.
    let snapshot = backend.cuda_memory_stats(0, synchronize=true)
    let ended = monotonic_ns()
    check_memory(snapshot)
    phases[group.name] = {
      "host_complete_ms": Json((ended - began).to_double() / 1000000.0),
      "updates": Json(group.updates),
      "memory": Json(snapshot),
    }
  }
  @tensor.profile_end(whole)
  let snapshot = backend.cuda_memory_stats(0, synchronize=true)
  let last = monotonic_ns()
  check_memory(snapshot)
  {
    "host_complete_ms": Json((last - first).to_double() / 1000000.0),
    "phases": Json(phases),
    "memory": Json(snapshot),
  }
}

///|
async fn connect(
  backend : @tensor.Backend,
  rank : Int32,
  path : String,
  session : String,
  progress : Progress,
) -> @tensor.Collective {
  progress.stage = "rendezvous-ticket"
  let deadline = @async.now() + 60000L
  let id = if rank == 0 {
    let id = backend.nccl_id()
    let value : Ticket = {
      session,
      id: Array::makei(128, i => id[i].to_int()),
    }
    let staged = path + "." + session + ".partial"
    @fs.write_file(staged, Json(value).stringify(), create_mode=CreateNew)
    @fs.rename(staged, path, replace=false)
    println(
      (
        {
          "stage": "bucket-benchmark-rendezvous",
          "rank": rank,
          "session": session,
          "id_file": path,
        } : Json).stringify(),
    )
    id
  } else {
    while !@fs.exists(path) {
      guard @async.now() < deadline else {
        fail("benchmark rendezvous timed out")
      }
      @async.sleep(100)
    }
    let file = @fs.open(path, mode=ReadOnly)
    defer file.close()
    let size = file.size()
    guard size > 0L && size <= 4096L else {
      fail("invalid benchmark ticket size")
    }
    let raw = file.read_exactly_at(size.to_int(), position=0L)
    guard file.size() == size else { fail("benchmark ticket changed") }
    let ticket : Ticket = @json.from_json(@json.parse(@utf8.decode(raw)))
    guard ticket.session == session &&
      ticket.id.length() == 128 &&
      ticket.id.all(v => v >= 0 && v <= 255) else {
      fail("benchmark ticket mismatch")
    }
    Bytes::makei(128, i => ticket.id[i].to_byte())
  }
  @fs.write_file(
    path + "." + session + ".rank-\{rank}.consumed",
    "consumed\n",
    create_mode=CreateNew,
  )
  progress.stage = "nccl-connect"
  backend.nccl_connect(id, rank~, world_size=2, cuda_device=0, timeout_ms=60000)
}

///|
async fn run(progress : Progress) -> Unit {
  let args = @env.args()
  guard args.length() == 6 else {
    fail(
      "usage: bucket_benchmark PLUGIN RANK FRESH_ID_FILE FRESH_SESSION FRESH_REPORT_JSON",
    )
  }
  let rank = @string.parse_int(args[2])
  progress.rank = rank
  let session = args[4]
  guard (rank == 0 || rank == 1) &&
    args[3].has_prefix("/") &&
    args[5].has_prefix("/") &&
    session.length() >= 16 &&
    session.length() <= 128 &&
    session
    .iter()
    .all(c => {
      (c >= 'a' && c <= 'z') ||
      (c >= 'A' && c <= 'Z') ||
      (c >= '0' && c <= '9') ||
      c == '-' ||
      c == '_'
    }) else {
    fail("invalid benchmark rank, absolute paths or fresh session")
  }
  guard !@fs.exists(args[5]) else { fail("benchmark report already exists") }
  progress.stage = "memlock-admission"
  let memlock = memlock_limits()
  println(
    (
      { "stage": "bucket-benchmark-memlock", "rank": rank, "limits": memlock } :
      Json).stringify(),
  )
  progress.stage = "backend-open-and-capabilities"
  let backend = @tensor.Backend::open(args[1])
  guard backend.has_gradient_buckets() &&
    backend.has_cuda_memory_telemetry() &&
    backend.cuda_device_count() > 0 else {
    fail("benchmark requires CUDA, bucket and allocator telemetry capabilities")
  }
  guard backend.cuda_free_bytes(0) >= 18270388224L else {
    fail(
      "benchmark needs 17 GiB + 16 MiB CUDA free for its working-set budget and 16 GiB reserve",
    )
  }
  progress.stage = "model-allocation-and-initial-gradients"
  let groups = model_groups(backend)
  prepare_gradients(groups, rank)
  let initial_memory = backend.cuda_memory_stats(0, synchronize=true)
  check_memory(initial_memory)
  let collective = connect(backend, rank, args[3], session, progress)
  defer (collective.close() catch { _ => () })
  // Warm each route three times. Restore all local gradients before every full
  // schedule, never inside the timed region; both routes see identical inputs.
  for warmup in 0..<3 {
    for bucketed in [false, true] {
      progress.stage = "warmup-\{warmup}-prepare-and-barrier"
      prepare_gradients(groups, rank)
      ignore(backend.cuda_memory_stats(0, synchronize=true))
      collective.barrier()
      ignore(
        schedule(
          backend,
          collective,
          groups,
          bucketed,
          "warmup-\{warmup}",
          false,
          progress,
        ),
      )
    }
    println(
      (
        { "stage": "bucket-benchmark-warmup", "rank": rank, "round": warmup } :
        Json).stringify(),
    )
  }
  progress.stage = "configure-profiling"
  @tensor.configure_profiling(backend, cuda_device=0, max_spans=160, nvtx=false)
  defer (@tensor.clear_profiling() catch { _ => () })
  let samples = []
  for block in 0..<10 {
    for position, bucketed in [false, true, true, false] {
      progress.stage = "block-\{block}-position-\{position}-prepare-and-barrier"
      prepare_gradients(groups, rank)
      let before = backend.cuda_memory_stats(0, synchronize=true)
      check_memory(before)
      let sequence = (block * 4 + position).to_int64()
      guard collective.control([sequence]) == [sequence * 2L] else {
        fail("rank schedule disagreement")
      }
      let label = "bucket-bench.\{block}.\{position}"
      let timing = schedule(
        backend, collective, groups, bucketed, label, true, progress,
      )
      samples.push({
        "block": Json(block),
        "position": Json(position),
        "route": if bucketed {
          Json("bucket")
        } else {
          Json("legacy")
        },
        "event_label": Json(label),
        "timing": timing,
      })
    }
    println(
      ({ "stage": "bucket-benchmark-pair", "rank": rank, "block": block } : Json).stringify(),
    )
  }
  progress.stage = "final-telemetry-and-report"
  let final_memory = backend.cuda_memory_stats(0, synchronize=true)
  check_memory(final_memory)
  let layouts : Map[String, Json] = Map([])
  for group in groups {
    layouts[group.name] = layout_report(
      group.parameters.map(p => p.shape()),
      group.updates,
    )
  }
  let report : Json = {
    "schema": "moonrobo.native-bucket-pairs.v1",
    "rank": rank,
    "world_size": 2,
    "session": session,
    "torch_version": backend.version(),
    "scope": "communication-critical-path-only",
    "training_speedup_claimed": false,
    "overlap_claimed": false,
    "parameter_values_changed": false,
    "profile": "paper93-hist10-goal10-native-default-networks",
    "seed": 179,
    "bucket_bytes": 16777216,
    "parameter_elements": 18083716,
    "parameter_payload_bytes": 72334864,
    "updates_per_schedule": 31,
    "legacy_collectives_per_schedule": 280,
    "bucket_collectives_per_schedule": 53,
    "warmup_schedules_per_route": 3,
    "abba_blocks": 10,
    "samples_per_route": 20,
    "layout": Json(layouts),
    "samples": Json(samples),
    "timing": "host includes pack/reduce/divide/scatter and identical CUDA-complete telemetry boundaries; event time is current-stream elapsed including waits, not active NCCL kernel time",
    "gradient_setup": "deterministic rank-dependent mean-loss backward before every schedule; 10/1/20 reductions reuse resulting gradients inside schedule",
    "allocator_budget_bytes": "1090519040",
    "memlock": memlock,
    "initial_memory": Json(initial_memory),
    "final_memory": Json(final_memory),
    "events": @json.parse(@tensor.profiling_report()),
  }
  let text = report.stringify(indent=2) + "\n"
  guard text.length() <= 1048576 else {
    fail("benchmark report exceeded 1 MiB")
  }
  @fs.write_file(args[5], text, create_mode=CreateNew, sync=Full)
  println(
    (
      { "stage": "bucket-benchmark-complete", "rank": rank, "report": args[5] } :
      Json).stringify(),
  )
}

///|
async fn main {
  let progress : Progress = { stage: "arguments", rank: -1, }
  run(progress) catch {
    @tensor.TensorError::Native(message) => {
      println(
        (
          {
            "stage": "bucket-benchmark-failed",
            "operation": progress.stage,
            "rank": progress.rank,
            "native_error": message,
          } : Json).stringify(),
      )
      fail(
        "bucket benchmark rank \{progress.rank} at \{progress.stage}: " +
        message,
      )
    }
    error => {
      println(
        (
          {
            "stage": "bucket-benchmark-failed",
            "operation": progress.stage,
            "rank": progress.rank,
            "error": error.to_string(),
          } : Json).stringify(),
      )
      raise error
    }
  }
}
