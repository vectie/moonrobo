///|
struct CriticTraceDigest {
  name : String
  source_dtype : String
  shape : Array[Int32]
  count : Int64
  sha256 : String
} derive(ToJson, FromJson)

///|
struct CriticTraceFinal {
  records : Array[CriticTraceDigest]
  optimizer_metadata : Array[AdamAuditMetadata]
  normalizer_counts : Array[Double]
} derive(ToJson)

///|
struct CriticTraceFrozen {
  format : String
  phase : String
  records : Array[GateRecord]
  optimizer_metadata : Array[AdamAuditMetadata]
  normalizer_counts : Array[Double]
} derive(FromJson)

///|
async fn trace_read_json(path : String) -> (Json, String) {
  guard @fs.realpath(path) == path &&
    @fs.kind(path, follow_symlink=false) is Regular else {
    fail("trace baseline metadata must be canonical regular file")
  }
  let file = @fs.open(path, mode=ReadOnly)
  defer file.close()
  let size = file.size()
  guard size > 0L && size <= 1048576L else { fail("trace JSON exceeds 1MiB") }
  let bytes = file.read_exactly_at(size.to_int(), position=0L)
  guard file.size() == size else { fail("trace JSON changed length") }
  let hash = @crypto.SHA256::new()
  hash.update(bytes)
  (
    @json.parse(@utf8.decode(bytes)),
    @crypto.bytes_to_hex_string(hash.finalize()),
  )
}

///|
fn trace_digest_tensor(
  name : String,
  tensor : @tensor.Tensor,
) -> CriticTraceDigest raise {
  guard tensor.dtype() == Float32 else {
    fail("trace final tensor requires Float32")
  }
  let shape = tensor.shape()
  let mut count = 1L
  for dim in shape {
    guard dim > 0 && count <= 16777216L / dim.to_int64() else {
      fail("trace final tensor exceeds 16M values")
    }
    count *= dim.to_int64()
  }
  let flat = tensor.stop_gradient().reshape([-1])
  let hash = @crypto.SHA256::new()
  for offset = 0L; offset < count; {
    let n = (count - offset).min(8192L).to_int()
    digest_values(hash, flat.narrow(0, offset.to_int(), n).values())
    continue offset + n.to_int64()
  }
  {
    name,
    source_dtype: "float32",
    shape,
    count,
    sha256: @crypto.bytes_to_hex_string(hash.finalize()),
  }
}

///|
fn trace_metric_values(metric : PolicyMetrics) -> Array[Double] {
  [
    metric.policy_loss,
    metric.critic_loss,
    metric.imagined_reward,
    metric.imagined_survival,
    metric.imagined_steps.to_double(),
    metric.critic_updates.to_double(),
  ]
}

///|
fn trace_final_digest(
  learner : Learner,
  metric : PolicyMetrics,
) -> CriticTraceFinal raise {
  let metrics = trace_metric_values(metric)
  let hash = @crypto.SHA256::new()
  digest_values(hash, metrics)
  let records : Array[CriticTraceDigest] = [
    {
      name: "metrics",
      source_dtype: "float64",
      shape: [6],
      count: 6L,
      sha256: @crypto.bytes_to_hex_string(hash.finalize()),
    },
  ]
  let metadata = []
  let names = ["world", "policy", "critic"]
  let optimizers = [learner.opt_world, learner.opt_policy, learner.opt_critic]
  let parameters = [
    learner.world.net.parameters(),
    learner.policy.parameters(),
    learner.critic.net.parameters(),
  ]
  for i in 0..<3 {
    let info : AdamAuditMetadata = @json.from_json(
      @json.parse(optimizers[i].audit_metadata()),
    )
    metadata.push(info)
    for p in 0..<info.parameter_count {
      let kinds = if info.states[p].present { 3 } else { 1 }
      for kind in 0..<kinds {
        records.push(
          trace_digest_tensor(
            "\{names[i]}-\{p}-kind\{kind}",
            optimizers[i].audit_tensor(p, kind~),
          ),
        )
      }
      if i > 0 {
        records.push(
          trace_digest_tensor(
            "\{names[i]}-\{p}-gradient",
            parameters[i][p].gradient(),
          ),
        )
      }
    }
  }
  for i, norm in learner.normalizers() {
    records.push(trace_digest_tensor("norm-\{i}-mean", norm.mean))
    records.push(trace_digest_tensor("norm-\{i}-variance", norm.variance))
  }
  {
    records,
    optimizer_metadata: metadata,
    normalizer_counts: learner.normalizers().map(n => n.count),
  }
}

///|
// Return named differences so the diagnostic evidence is written before a
// failed equality check. This compares all old actor-1 record identities, not
// merely the two investigated columns. It does not re-read old numeric payloads.
fn trace_compare_frozen(
  current : CriticTraceFinal,
  old : CriticTraceFrozen,
) -> Array[String] raise {
  guard old.format == "moonrobo.microbatch-numerical-snapshot.v1" &&
    old.phase == "actor-1" &&
    old.records.length() <= 256 else {
    fail("invalid frozen actor-1 snapshot")
  }
  let differences = []
  if current.optimizer_metadata.to_json() != old.optimizer_metadata.to_json() {
    differences.push("optimizer-metadata")
  }
  if current.normalizer_counts.to_json() != old.normalizer_counts.to_json() {
    differences.push("normalizer-counts")
  }
  let entries : Map[String, GateRecord] = {}
  for record in old.records {
    guard !entries.contains(record.name) && record.blob.dtype == "f64le" else {
      fail("duplicate/invalid frozen record")
    }
    entries[record.name] = record
  }
  if current.records.length() != entries.length() {
    differences.push("record-inventory-length")
  }
  for record in current.records {
    guard entries.get(record.name) is Some(previous) else {
      fail("frozen record missing \{record.name}")
    }
    if previous.source_dtype != record.source_dtype ||
      previous.blob.shape != record.shape ||
      previous.blob.count != record.count ||
      previous.blob.byte_length != record.count * 8L ||
      previous.blob.sha256 != record.sha256 {
      differences.push(record.name)
    }
    entries.remove(record.name)
  }
  if !entries.is_empty() {
    differences.push("extra-frozen-records")
  }
  differences
}

///|
async fn trace_write_records(root : String, trace : CriticTrace) -> Json {
  trace.finish()
  let directory = root + "/actual-critic-trace"
  @fs.mkdir(directory)
  let records = []
  for record in trace.records {
    // The codec stores scalar losses as [1]; source_shape retains the actual [].
    let storage_shape = if record.shape.is_empty() { [1] } else { record.shape }
    let blob = @stream.write_f64le(
      directory,
      record.name + ".f64",
      storage_shape,
      (offset, count) => {
        record.values[offset.to_int():offset.to_int() + count].to_owned()
      },
    )
    records.push({
      "name": Json(record.name),
      "source_dtype": Json(record.source_dtype),
      "source_shape": Json(record.shape),
      "blob": Json(blob),
    })
  }
  let report : Json = {
    "format": "moonrobo.actual-critic-trace.v1",
    "scope": "first actual production actor update; no extra critic training loop",
    "completed_steps": Json(trace.completed_steps),
    "first_layer_output_rows": Json(trace.rows),
    "first_layer_selected_input_columns": [146, 147],
    "numeric_values": Json(trace.used_values),
    "numeric_value_limit": 1048576,
    "numeric_bytes": Json(trace.used_values * 8),
    "transfer_chunk_bytes": 65536,
    "record_limit": 256,
    "norm_count": Json(trace.norm_count),
    "norm_epsilon": Json(trace.norm_epsilon),
    "records": Json(records),
    "optimizer_metadata": Json(trace.adam_metadata),
    "before_gradients": "after existing optional allreduce, before existing Adam::step clipping",
    "after_gradients": "post-clipping gradients retained by the existing Adam::step",
    "clip_coefficient": Json::null(),
    "normalized_inputs": "actual tensor supplied to Network::forward, including each of 20 minibatches",
    "missing_initial_moments": "absent optimizer state is marked in metadata and has no fabricated zero sidecar",
    "native_tensor_handles_retained": false,
    "cpu_float64_reconstruction": false,
    "cuda_full_split_parity_proven": false,
  }
  gate_json(directory + "/trace.json", report)
  report
}

///|
test "trace frozen summary comparison rejects changed state and metadata" {
  let record : CriticTraceDigest = {
    name: "metrics",
    source_dtype: "float64",
    shape: [6],
    count: 6L,
    sha256: "a".repeat(64),
  }
  let current : CriticTraceFinal = {
    records: [record],
    optimizer_metadata: [],
    normalizer_counts: [132.0],
  }
  let old : CriticTraceFrozen = {
    format: "moonrobo.microbatch-numerical-snapshot.v1",
    phase: "actor-1",
    optimizer_metadata: [],
    normalizer_counts: [132.0],
    records: [
      {
        name: "metrics",
        source_dtype: "float64",
        blob: {
          file: "metrics.f64",
          dtype: "f64le",
          shape: [6],
          count: 6L,
          byte_length: 48L,
          sha256: "a".repeat(64),
        },
      },
    ],
  }
  assert_eq(trace_compare_frozen(current, old), [])
  assert_eq(
    trace_compare_frozen(
      { ..current, records: [{ ..record, sha256: "b".repeat(64), }], },
      old,
    ),
    ["metrics"],
  )
  assert_eq(
    trace_compare_frozen({ ..current, normalizer_counts: [131.0], }, old),
    ["normalizer-counts"],
  )
}

///|
async test "actual critic trace streams valid bounded sidecars and refuses overwrite" {
  guard @env.get_env_var("MOONROBO_TENSOR_LIBRARY") is Some(path) else {
    println(
      "SKIP critic trace writer CPU integration: set MOONROBO_TENSOR_LIBRARY",
    )
    return
  }
  let backend = @tensor.Backend::open(path)
  let config = {
    ..micro_config(),
    wm_batch: 4,
    policy_batch: 4,
    critic_epochs: 5,
    critic_minibatches: 4,
  }
  let learner = Learner::new(
    backend,
    micro_context(backend),
    config~,
    seed=1U,
    world_microbatch=2,
    actor_microbatch=2,
  )
  let (world, policy) = gate_batches(backend, -1, 5)
  trace_test_prepare(learner, world, policy)
  let trace = CriticTrace::new(8)
  let metric = learner.update_policy_impl(
    policy,
    train_critic=true,
    trace=Some(trace),
  )
  @async.with_task_group() <| group => {
    let root = @fs.realpath(@fs.tmpdir(prefix="moonrobo-actual-critic-trace-"))
    group.add_defer(() => @fs.rmdir(root, recursive=true))
    let report = trace_write_records(root, trace)
    let (stored, _) = trace_read_json(root + "/actual-critic-trace/trace.json")
    assert_eq(stored, report)
    guard report is Object(fields) && fields["records"] is Array(records) else {
      fail("missing trace records")
    }
    assert_eq(records.length(), 251)
    for i, record in records {
      guard record is Object(entry) else { fail("bad trace record") }
      let blob : @stream.BlobDescriptor = @json.from_json(entry["blob"])
      @stream.verify_blob(root + "/actual-critic-trace", blob)
      let restored = []
      @stream.read_f64le(root + "/actual-critic-trace", blob, (_, part) => {
        restored.append(part)
      })
      trace_test_bits(restored, trace.records[i].values)
    }
    // Cross-check raw digest compatibility with the unchanged original writer,
    // covering its entire actor-1 inventory, not just one synthetic record.
    gate_snapshot(root, "actor-1", learner, trace_metric_values(metric))
    let (snapshot, _) = trace_read_json(root + "/actor-1/snapshot.json")
    let frozen : CriticTraceFrozen = @json.from_json(snapshot)
    assert_eq(
      trace_compare_frozen(trace_final_digest(learner, metric), frozen),
      [],
    )
    try trace_write_records(root, trace) catch {
      _ => ()
    } noraise {
      _ => fail("trace overwrite accepted")
    }
  }
}
