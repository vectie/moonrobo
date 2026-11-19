///|
struct GateRecord {
  name : String
  source_dtype : String
  blob : @stream.BlobDescriptor
} derive(ToJson, FromJson)

///|
async fn gate_json(path : String, value : Json) -> Unit {
  @fs.write_file(
    path,
    value.stringify(indent=2) + "\n",
    create_mode=CreateNew,
    sync=Full,
  )
}

///|
async fn gate_text(path : String) -> String {
  let file = @fs.open(path, mode=ReadOnly)
  defer file.close()
  // procfs/cgroup pseudo-files report size zero; read through a bounded buffer.
  let bytes = FixedArray::make(65537, b'\x00')
  let size = file.read_at(bytes, position=0L)
  guard size > 0 && size <= 65536 else {
    fail("gate control file exceeds bound")
  }
  @utf8.decode(Bytes::makei(size, i => bytes[i])).trim().to_owned()
}

///|
async fn gate_file_sha(path : String) -> String {
  let file = @fs.open(path, mode=ReadOnly)
  defer file.close()
  let size = file.size()
  guard size > 0L && size <= 1073741824L else {
    fail("gate pinned file exceeds 1GiB")
  }
  let hash = @crypto.SHA256::new()
  for offset = 0L; offset < size; {
    let count = (size - offset).min(65536L).to_int()
    hash.update(file.read_exactly_at(count, position=offset))
    continue offset + count.to_int64()
  }
  guard file.size() == size else { fail("gate pinned file changed length") }
  @crypto.bytes_to_hex_string(hash.finalize())
}

///|
async fn gate_memory(backend : @tensor.Backend, device : Int32) -> Json {
  if device < 0 {
    return { "profile": "cpu-smoke", "cuda_executed": false }
  }
  guard @fs.exists("/proc/meminfo") && @fs.exists("/sys/fs/cgroup/memory.max") else {
    fail("CUDA gate requires Linux and readable cgroup v2 memory limits")
  }
  let limit = @string.parse_int64(gate_text("/sys/fs/cgroup/memory.max"))
  let used = @string.parse_int64(gate_text("/sys/fs/cgroup/memory.current"))
  let peak = @string.parse_int64(gate_text("/sys/fs/cgroup/memory.peak"))
  guard (limit == 17179869184L || limit == 25769803776L) &&
    gate_text("/sys/fs/cgroup/memory.swap.max") == "0" else {
    fail(
      "CUDA gate requires an actual fresh 16GiB or 24GiB cgroup with zero swap",
    )
  }
  let mut available = 0L
  for line in gate_text("/proc/meminfo").split("\n") {
    if line.has_prefix("MemAvailable:") {
      let fields = line.split(" ").filter(s => s != "").to_array()
      guard fields.length() == 3 && fields[2] == "kB" else {
        fail("invalid MemAvailable")
      }
      available = @string.parse_int64(fields[1]) * 1024L
    }
  }
  guard available > 0L else { fail("unknown host memory availability") }
  let events = gate_text("/sys/fs/cgroup/memory.events")
  for line in events.split("\n") {
    let parts = line.split(" ").to_array()
    if parts.length() == 2 &&
      (
        parts[0] == "oom" ||
        parts[0] == "oom_kill" ||
        parts[0] == "oom_group_kill"
      ) {
      guard @string.parse_int64(parts[1]) == 0L else {
        fail("gate cgroup reports OOM")
      }
    }
  }
  let free = backend.cuda_free_bytes(device)
  {
    "memory_limit_bytes": Json(limit),
    "host_available_bytes": Json(available),
    "cgroup_remaining_bytes": Json((limit - used).max(0L)),
    "cgroup_current_bytes": Json(used),
    "cgroup_peak_bytes": Json(peak),
    "cuda_free_bytes": Json(free),
    "memory_events": Json(events),
    "point_sample_only": true,
  }
}

///|
fn gate_memory_budget(value : Json) -> Unit raise {
  guard value is Object(fields) else { fail("invalid memory sample") }
  let host : Int64 = @json.from_json(fields["host_available_bytes"])
  let group : Int64 = @json.from_json(fields["cgroup_remaining_bytes"])
  let cuda : Int64 = @json.from_json(fields["cuda_free_bytes"])
  let available = host.min(group).min(cuda)
  // Conservative admission estimate, not a claimed measured allocator peak.
  guard available.to_double() * 0.65 >= 8589934592.0 else {
    fail("8GiB gate estimate exceeds 65% of host/cgroup/CUDA available memory")
  }
}

///|
async fn gate_tensor_record(
  root : String,
  name : String,
  tensor : @tensor.Tensor,
) -> GateRecord {
  guard tensor.dtype() == Float32 else {
    fail("gate snapshots require Float32 tensors")
  }
  let shape = tensor.shape()
  let mut count = 1L
  for dim in shape {
    guard dim > 0 && count <= 16777216L / dim.to_int64() else {
      fail("gate tensor exceeds 16M elements")
    }
    count *= dim.to_int64()
  }
  // These dense model parameters, gradients and prepared inputs are bounded by
  // the fixed profile. Slice before host transfer: <=8192 values / 64KiB.
  let flat = tensor.stop_gradient().reshape([-1])
  let blob = @stream.write_f64le(root, name + ".f64", shape, (offset, n) => {
    let values = flat.narrow(0, offset.to_int(), n).values()
    guard values.all(@numeric.finite) else { fail("nonfinite gate tensor") }
    values
  })
  { name, source_dtype: "float32", blob, }
}

///|
async fn gate_values_record(
  root : String,
  name : String,
  values : Array[Double],
) -> GateRecord {
  guard !values.is_empty() &&
    values.length() <= 65536 &&
    values.all(@numeric.finite) else {
    fail("invalid bounded gate scalar record")
  }
  let blob = @stream.write_f64le(root, name + ".f64", [values.length()], (
    offset,
    n,
  ) => values[offset.to_int():offset.to_int() + n].to_owned())
  { name, source_dtype: "float64", blob, }
}

///|
async fn gate_snapshot(
  root : String,
  phase : String,
  learner : Learner,
  metrics : Array[Double],
) -> Unit {
  let directory = root + "/" + phase
  @fs.mkdir(directory)
  let records = [gate_values_record(directory, "metrics", metrics)]
  let optimizer_metadata = []
  let names = ["world", "policy", "critic"]
  let optimizers = [learner.opt_world, learner.opt_policy, learner.opt_critic]
  let parameters = [
    learner.world.net.parameters(),
    learner.policy.parameters(),
    learner.critic.net.parameters(),
  ]
  for i in 0..<3 {
    let metadata : AdamAuditMetadata = @json.from_json(
      @json.parse(optimizers[i].audit_metadata()),
    )
    optimizer_metadata.push(Json(metadata))
    for p in 0..<metadata.parameter_count {
      let kinds = if metadata.states[p].present { 3 } else { 1 }
      for kind in 0..<kinds {
        records.push(
          gate_tensor_record(
            directory,
            "\{names[i]}-\{p}-kind\{kind}",
            optimizers[i].audit_tensor(p, kind~),
          ),
        )
      }
      // Audit every updated model's actual post-clip gradient. Unused/frozen
      // models are not given fabricated gradients; a missing active grad fails.
      if (phase.has_prefix("world-") && i == 0) ||
        (phase.has_prefix("actor-") && i > 0) {
        records.push(
          gate_tensor_record(
            directory,
            "\{names[i]}-\{p}-gradient",
            parameters[i][p].gradient(),
          ),
        )
      }
    }
  }
  for i, norm in learner.normalizers() {
    records.push(gate_tensor_record(directory, "norm-\{i}-mean", norm.mean))
    records.push(
      gate_tensor_record(directory, "norm-\{i}-variance", norm.variance),
    )
  }
  gate_json(directory + "/snapshot.json", {
    "format": "moonrobo.microbatch-numerical-snapshot.v1",
    "phase": Json(phase),
    "optimizer_metadata": Json(optimizer_metadata),
    "normalizer_counts": Json(learner.normalizers().map(n => n.count)),
    "records": Json(records),
    "memory": gate_memory(learner.backend, learner.cuda_device),
  })
}

///|
test "microbatch numerical gate retains 65 percent minimum resource admission" {
  let enough : Json = {
    "host_available_bytes": Json(34359738368L),
    "cgroup_remaining_bytes": Json(17179869184L),
    "cuda_free_bytes": Json(25769803776L),
  }
  gate_memory_budget(enough)
  for
    key in ["host_available_bytes", "cgroup_remaining_bytes", "cuda_free_bytes"] {
    guard enough is Object(original) else { fail("fixture") }
    let fields = original.copy()
    fields[key] = Json(8589934592L)
    try gate_memory_budget(Json(fields)) catch {
      _ => ()
    } noraise {
      _ => fail("low resource accepted")
    }
  }
}
