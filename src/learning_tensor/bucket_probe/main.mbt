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
async fn rendezvous(
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
    let ticket : Ticket = {
      session,
      id: Array::makei(id.length(), i => id[i].to_int()),
    }
    let staged = path + "." + session + ".partial"
    @fs.write_file(staged, Json(ticket).stringify(), create_mode=CreateNew)
    @fs.rename(staged, path, replace=false)
    println(
      (
        {
          "stage": "bucket-probe-rendezvous",
          "session": session,
          "rank": rank,
          "id_file": path,
        } : Json).stringify(),
    )
    id
  } else {
    while !@fs.exists(path) {
      guard @async.now() < deadline else {
        fail("bucket probe rendezvous timed out")
      }
      @async.sleep(100)
    }
    let file = @fs.open(path, mode=ReadOnly)
    defer file.close()
    let size = file.size()
    guard size > 0L && size <= 4096L else {
      fail("oversized bucket probe ticket")
    }
    let bytes = file.read_exactly_at(size.to_int(), position=0L)
    guard file.size() == size else { fail("bucket probe ticket changed") }
    let ticket : Ticket = @json.from_json(@json.parse(@utf8.decode(bytes)))
    guard ticket.session == session &&
      ticket.id.length() == 128 &&
      ticket.id.all(x => x >= 0 && x <= 255) else {
      fail("bucket probe session/ID mismatch")
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
fn parameters(
  backend : @tensor.Backend,
  sizes : Array[Int32],
  dtype : @tensor.DType,
) -> Array[@tensor.Tensor] raise {
  sizes.map(size => {
    backend.from_values(
      [size],
      Array::makei(size, i => (i % 31 - 15).to_double() / 128.0),
      cuda_device=0,
      requires_grad=true,
      dtype~,
    )
  })
}

///|
fn backward(
  parameters : Array[@tensor.Tensor],
  rank : Int32,
  step : Int32,
) -> Unit raise {
  let mut loss = parameters[1]
    .sum()
    .affine((2 * (step + 1) * (rank + 1)).to_double() / 16.0)
  for i in 0..<parameters.length() {
    if i == 1 || (i == 2 && rank == 0) {
      continue
    }
    loss = loss.add(
      parameters[i]
      .sum()
      .affine(((i + 1) * (step + 1) * (rank + 1)).to_double() / 16.0),
    )
  }
  loss.backward()
}

///|
fn compare(a : @tensor.Tensor, b : @tensor.Tensor) -> Double raise {
  guard a.shape() == b.shape() else {
    fail("bucket probe tensor shape mismatch")
  }
  guard a.shape().length() == 1 else {
    fail("bucket probe expects flat parameters")
  }
  let size = a.shape()[0]
  let mut maximum = 0.0
  for start = 0; start < size; {
    let width = (size - start).min(4096)
    let av = a.reshape([-1]).narrow(0, start, width).values()
    let bv = b.reshape([-1]).narrow(0, start, width).values()
    for i in 0..<width {
      guard !av[i].is_nan() &&
        !av[i].is_inf() &&
        !bv[i].is_nan() &&
        !bv[i].is_inf() else {
        fail("nonfinite bucket probe comparison")
      }
      let delta = (av[i] - bv[i]).abs()
      guard delta <= 2.0e-7 + 2.0e-6 * bv[i].abs() else {
        fail("bucket probe difference exceeds fixed 2e-7 + 2e-6*abs(reference)")
      }
      maximum = maximum.max(delta)
    }
    continue start + width
  }
  maximum
}

///|
fn analytic_gradient(
  parameters : Array[@tensor.Tensor],
  step : Int32,
) -> Unit raise {
  for i, parameter in parameters {
    let expected = ((i + 1) * (step + 1)).to_double() *
      (if i == 2 { 1.0 } else { 1.5 }) /
      16.0
    let gradient = parameter.gradient()
    let size = parameter.shape()[0]
    for start = 0; start < size; {
      let width = (size - start).min(4096)
      for actual in gradient.narrow(0, start, width).values() {
        guard actual == expected else {
          fail("SUM/world or missing-gradient zero semantics changed")
        }
      }
      continue start + width
    }
  }
}

///|
fn run_cases(
  backend : @tensor.Backend,
  group : @tensor.Collective,
  rank : Int32,
  progress : Progress,
) -> Json raise {
  // Fixed 1 MiB capacity bounds the probe independently of production choices.
  let bucket_bytes = 1048576
  let sizes = [0, 1, 262143, 262144, 262145, 7]
  progress.stage = "allocate-boundary-parameters"
  let reference = parameters(backend, sizes, Float32)
  let candidate = parameters(backend, sizes, Float32)
  progress.stage = "invalid-capacity-and-count-rejections"
  for bytes in [0, 1048575, 67108865] {
    try group.average_gradients_bucketed(candidate, bucket_bytes=bytes) catch {
      @tensor.TensorError::Native(message) => {
        guard message.contains("1..64 MiB") else {
          fail("wrong bucket capacity rejection")
        }
      }
    } noraise {
      _ => fail("invalid bucket capacity was accepted")
    }
  }
  for invalid in [[], Array::make(4097, candidate[1])] {
    try group.average_gradients_bucketed(invalid, bucket_bytes~) catch {
      @tensor.TensorError::Native(message) => {
        guard message.contains("1..4096 parameters") else {
          fail("wrong bucket count rejection")
        }
      }
    } noraise {
      _ => fail("invalid bucket parameter count was accepted")
    }
  }
  progress.stage = "create-adam"
  let oa = backend.adam(reference)
  let ob = backend.adam(candidate)
  let mut maximum = 0.0
  for step in 0..<3 {
    progress.stage = "step-\{step}-backward"
    oa.zero_grad()
    ob.zero_grad()
    backward(reference, rank, step)
    backward(candidate, rank, step)
    progress.stage = "step-\{step}-legacy-average"
    group.average_gradients(reference)
    progress.stage = "step-\{step}-bucket-average"
    group.average_gradients_bucketed(candidate, bucket_bytes~)
    progress.stage = "step-\{step}-gradient-compare"
    analytic_gradient(reference, step)
    analytic_gradient(candidate, step)
    for i in 0..<sizes.length() {
      maximum = maximum.max(
        compare(reference[i].gradient(), candidate[i].gradient()),
      )
    }
    progress.stage = "step-\{step}-legacy-adam"
    oa.step(clip_norm=1.0, clip_value=0.1)
    progress.stage = "step-\{step}-bucket-adam"
    ob.step(clip_norm=1.0, clip_value=0.1)
    progress.stage = "step-\{step}-adam-state-compare"
    guard oa.audit_metadata() == ob.audit_metadata() else {
      fail("Adam metadata mismatch")
    }
    for i in 0..<sizes.length() {
      for kind in 0..<3 {
        maximum = maximum.max(
          compare(oa.audit_tensor(i, kind~), ob.audit_tensor(i, kind~)),
        )
      }
    }
  }
  // Consecutive dtype switches flush partial buckets without reordering.
  progress.stage = "mixed-dtype-allocate-and-backward"
  let mixed_a = parameters(backend, [7], Float64) +
    parameters(backend, [3], Float32) +
    parameters(backend, [131073], Float64)
  let mixed_b = parameters(backend, [7], Float64) +
    parameters(backend, [3], Float32) +
    parameters(backend, [131073], Float64)
  backward(mixed_a, rank, 0)
  backward(mixed_b, rank, 0)
  progress.stage = "mixed-dtype-legacy-average"
  group.average_gradients(mixed_a)
  progress.stage = "mixed-dtype-bucket-average"
  group.average_gradients_bucketed(mixed_b, bucket_bytes~)
  progress.stage = "mixed-dtype-compare"
  analytic_gradient(mixed_a, 0)
  analytic_gradient(mixed_b, 0)
  for i in 0..<3 {
    maximum = maximum.max(compare(mixed_a[i].gradient(), mixed_b[i].gradient()))
  }
  // Nonfinite averaged gradients must still fail before mutating Adam state.
  for index, nonfinite in [0.0 / 0.0, 1.0 / 0.0] {
    progress.stage = "nonfinite-\{index}-allocate-and-backward"
    let p = parameters(backend, [2], Float32)
    let optimizer = backend.adam(p)
    let before = p[0].values()
    let metadata = optimizer.audit_metadata()
    p[0].sum().affine(if rank == 0 { nonfinite } else { 1.0 }).backward()
    progress.stage = "nonfinite-\{index}-bucket-average"
    group.average_gradients_bucketed(p, bucket_bytes~)
    progress.stage = "nonfinite-\{index}-adam-rejection"
    try optimizer.step(clip_norm=1.0) catch {
      @tensor.TensorError::Native(message) => {
        guard message.contains("nonfinite Adam gradient") else {
          fail("unexpected Adam rejection")
        }
      }
    } noraise {
      _ => fail("nonfinite gradient was accepted")
    }
    guard p[0].values() == before && optimizer.audit_metadata() == metadata else {
      fail("nonfinite rejection mutated parameters/Adam state")
    }
  }
  {
    "stage": "bucket-probe-complete",
    "rank": rank,
    "world_size": 2,
    "bucket_bytes": bucket_bytes,
    "optimizer_steps_compared": 3,
    "boundary_sizes": Json(sizes),
    "dtype_transition_checked": true,
    "rank_specific_missing_gradient_checked": true,
    "capacity_and_count_bounds_checked": true,
    "nonfinite_rejection_checked": true,
    "max_absolute_error": Json(maximum),
    "atol": 2.0e-7,
    "rtol": 2.0e-6,
    "performance_claimed": false,
  }
}

///|
async fn run(progress : Progress) -> Unit {
  let args = @env.args()
  guard args.length() == 5 else {
    fail("usage: bucket_probe PLUGIN RANK FRESH_ID_FILE FRESH_SESSION")
  }
  let rank = @string.parse_int(args[2])
  progress.rank = rank
  guard (rank == 0 || rank == 1) &&
    args[3].has_prefix("/") &&
    args[4].length() >= 16 &&
    args[4].length() <= 128 &&
    args[4]
    .iter()
    .all(c => {
      (c >= 'a' && c <= 'z') ||
      (c >= 'A' && c <= 'Z') ||
      (c >= '0' && c <= '9') ||
      c == '-' ||
      c == '_'
    }) else {
    fail(
      "bucket probe requires rank 0/1, absolute ID path and fresh 16..128-character session",
    )
  }
  progress.stage = "memlock-admission"
  let memlock = memlock_limits()
  println(
    ({ "stage": "bucket-probe-memlock", "rank": rank, "limits": memlock } : Json).stringify(),
  )
  progress.stage = "backend-open-and-capabilities"
  let backend = @tensor.Backend::open(args[1])
  guard backend.has_gradient_buckets() && backend.cuda_device_count() > 0 else {
    fail(
      "bucket probe requires the optional gradient bucket extension and CUDA",
    )
  }
  guard backend.cuda_free_bytes(0) >= 17179869184L else {
    fail("bucket probe needs at least 16 GiB CUDA free before allocating")
  }
  let group = rendezvous(backend, rank, args[3], args[4], progress)
  defer (group.close() catch { _ => () })
  println(run_cases(backend, group, rank, progress).stringify())
}

///|
async fn main {
  let progress : Progress = { stage: "arguments", rank: -1, }
  run(progress) catch {
    @tensor.TensorError::Native(message) => {
      println(
        (
          {
            "stage": "bucket-probe-failed",
            "operation": progress.stage,
            "rank": progress.rank,
            "native_error": message,
          } : Json).stringify(),
      )
      fail(
        "bucket probe rank \{progress.rank} at \{progress.stage}: " + message,
      )
    }
    error => {
      println(
        (
          {
            "stage": "bucket-probe-failed",
            "operation": progress.stage,
            "rank": progress.rank,
            "error": error.to_string(),
          } : Json).stringify(),
      )
      raise error
    }
  }
}
