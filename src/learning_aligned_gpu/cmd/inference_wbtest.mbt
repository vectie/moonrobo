///|
test "native inference attestation accepts documented optional schemas only" {
  let digest : @gpu.SharedStateDigest = {
    format: "moonrobo.shared-learner-state.v1",
    sha256: "fixture",
    learner_config_sha256: "config",
    normalizers_sha256: "normalizers",
    optimizers: [],
    host_chunk_values: 65536,
  }
  assert_eq(optional_attestation({}), Json::null())
  assert_eq(
    optional_attestation({ "shared_state_digest": Json::null() }),
    Json::null(),
  )
  assert_eq(
    optional_attestation({ "shared_state_digest": Json(digest) }),
    Json(digest),
  )
  assert_eq(
    optional_attestation({ "shared_state_digest": [Json(digest)] }),
    Json(digest),
  )
  assert_true(
    (try? optional_attestation({ "shared_state_digest": [] })) is Err(_),
  )
  assert_true(
    (try? optional_attestation({ "shared_state_digest": true })) is Err(_),
  )
}

///|
test "linear native evaluation report preserves full catalog subset and replica semantics" {
  let first : @aligned.ClipEvaluation = {
    clip_id: "first",
    expected_steps: 3,
    rewards: [0.1, 0.1, 0.1],
    terminated: false,
    strict_rmse: None,
    termination_frame: None,
  }
  let second : @aligned.ClipEvaluation = {
    clip_id: "second",
    expected_steps: 4,
    rewards: [0.1],
    terminated: true,
    strict_rmse: None,
    termination_frame: Some(1),
  }
  let catalog = ["first", "second"]
  let full = @aligned.summarize_evaluations([second, first])
  assert_eq(
    inference_report(full, 2, [1, 0], {}, 2),
    full.report_json(catalog, {}, simulated_replica_count=2),
  )
  let subset = @aligned.summarize_evaluations([second])
  assert_eq(
    inference_report(subset, 2, [1], {}, 2),
    subset.report_json(catalog, {}, simulated_replica_count=2),
  )
  assert_true(
    (try? verify_identity_field(
      { "scene_sha256": "original" },
      "scene_sha256",
      "changed",
    ))
    is Err(_),
  )
}

///|
async test "native inference reports the loaded checkpoint or export and hashes exact metadata bytes" {
  let directory = @fs.tmpdir(prefix="moonrobo-inference-provenance-")
  defer @fs.rmdir(directory, recursive=true)
  let path = directory + "/actor.json"
  let alternative = directory + "/actor-spaced.json"
  @fs.write_file(path, b"{\"version\":1}\n", create_mode=CreateNew)
  @fs.write_file(alternative, b"{\"version\":1}", create_mode=CreateNew)
  let (metadata, metadata_sha256) = inference_hashed_json(path, 64L)
  let (same_metadata, other_sha256) = inference_hashed_json(alternative, 64L)
  assert_eq(metadata, same_metadata)
  assert_eq(metadata_sha256, file_hash(path))
  assert_true(metadata_sha256 != other_sha256)
  try inference_hashed_json(path, 2L) catch {
    _ => ()
  } noraise {
    _ => fail("oversize metadata must be rejected")
  }
  let checkpoint : InferenceArchive = {
    kind: "native_training_checkpoint",
    path: directory + "/generation-1/policy.pt",
    sha256: "checked-policy-digest",
    metadata_path: directory + "/generation-1/state.json",
    metadata_sha256: "checked-state-digest",
  }
  let actor : InferenceArchive = {
    kind: "native_actor_export",
    path: directory + "/actor.pt",
    sha256: "checked-export-digest",
    metadata_path: path,
    metadata_sha256,
  }
  assert_eq(checkpoint.report(), {
    "loaded_archive_kind": "native_training_checkpoint",
    "loaded_archive_path": Json(directory + "/generation-1/policy.pt"),
    "loaded_archive_sha256": "checked-policy-digest",
    "loaded_metadata_path": Json(directory + "/generation-1/state.json"),
    "loaded_metadata_sha256": "checked-state-digest",
  })
  assert_eq(actor.report(), {
    "loaded_archive_kind": "native_actor_export",
    "loaded_archive_path": Json(directory + "/actor.pt"),
    "loaded_archive_sha256": "checked-export-digest",
    "loaded_metadata_path": Json(path),
    "loaded_metadata_sha256": Json(metadata_sha256),
  })
}

///|
test "saved high utilization inference projects settings without rewriting source provenance" {
  for percent in [65, 80] {
    guard paper_capacity_config() is Object(fields) else {
      fail("object fixture")
    }
    fields["memory_admission_percent"] = Json(percent)
    fields["distributed"] = true
    let config = Json::object(fields)
    let source : InferenceSource = {
      format: "moonrobo.native-actor-source.v1",
      iteration: 10,
      identity: { "config": config, "unchanged": "source evidence" },
      motion_names: ["clip"],
      motion_sha256: ["hash"],
      source_fps: 30.0,
      checkpoint_receipt_sha256: "receipt",
      checkpoint_files: { "catalog.json": "catalog" },
      shared_state_digest: Json::null(),
    }
    let before = Json(source).stringify()
    let runtime_config = evaluation_runtime_config(config)
    let s = settings(runtime_config, ["aligned-gpu", "evaluate"])
    assert_true(s.memory_admission_percent is None)
    assert_true(s.distributed is None)
    assert_eq(s.environments, 4096)
    assert_eq(s.learner.wm_batch, 2048)
    assert_eq(s.learner.policy_batch, 4096)
    assert_eq(s.capacity_profile, @capacity.Paper4096)
    assert_eq(memory_admission_request(config), Some(percent))
    assert_eq(Json(source).stringify(), before)
    let exported_source : InferenceSource = @json.from_json(@json.parse(before))
    assert_eq(exported_source.identity, source.identity)
    // Both report paths preserve the explicit source request as provenance,
    // while the actual inference memory checks take no training-policy input.
    for mode in ["evaluate", "export"] {
      let base : Json = { "mode": mode, "training_executed": false }
      let report = inference_training_memory_report(base, Some(percent))
      guard report is Object(report_fields) else { fail("report fixture") }
      assert_eq(report_fields["training_memory_policy_not_applied"], Json(true))
      assert_eq(
        report_fields["source_training_memory_admission_percent"],
        Json(percent),
      )
      assert_eq(report_fields["training_executed"], Json(false))
      assert_eq(base, { "mode": mode, "training_executed": false })
    }
  }
  let legacy : Json = { "num_envs": 2 }
  assert_true(memory_admission_request(legacy) is None)
  assert_eq(inference_training_memory_report(legacy, None), legacy)
  assert_true(
    settings(evaluation_runtime_config(legacy), ["aligned-gpu", "evaluate"]).memory_admission_percent
    is None,
  )
}

///|
test "inference validates saved memory request before dropping the training-only field" {
  let config = paper_capacity_config()
  guard config is Object(fields) else { fail("object fixture") }
  for
    invalid in [
      Json(64),
      Json(81),
      Json(65.5),
      Json("80"),
      Json(true),
      Json::null(),
    ] {
    let bad = fields.copy()
    bad["memory_admission_percent"] = invalid
    try evaluation_runtime_config(Json::object(bad)) catch {
      _ => ()
    } noraise {
      _ => fail("invalid source memory request silently omitted")
    }
  }
  for invalid in [Json("initial"), Json("paper"), Json(true), Json::null()] {
    let bad = fields.copy()
    bad["memory_admission_percent"] = Json(80)
    bad["capacity_profile"] = invalid
    try evaluation_runtime_config(Json::object(bad)) catch {
      _ => ()
    } noraise {
      _ => fail("invalid source capacity silently omitted")
    }
  }
  try memory_admission_request({ "memory_admission_percent": 80 }) catch {
    _ => ()
  } noraise {
    _ => fail("explicit source memory policy accepted without paper capacity")
  }
}

///|
async test "inference config override must match complete original source for evaluation and CPU export" {
  let root = @fs.tmpdir(prefix="moonrobo-inference-source-config-")
  defer @fs.rmdir(root, recursive=true)
  guard paper_capacity_config() is Object(fields) else {
    fail("object fixture")
  }
  fields["memory_admission_percent"] = Json(80)
  let original = Json::object(fields)
  let identity : Json = { "config": original }
  let path = root + "/config.json"
  let before = identity.stringify()
  for mode in ["evaluate", "export"] {
    @fs.write_file(path, original.stringify(), create_mode=CreateOrTruncate)
    let args = ["aligned-gpu", mode, "--config", path]
    let (config, request) = inference_source_config(identity, args)
    assert_eq(config, original)
    assert_eq(request, Some(80))
    assert_eq(
      inference_source_config(identity, ["aligned-gpu", mode]),
      (original, Some(80)),
    )
    for change in ["remove-policy", "change-policy", "change-batch"] {
      let wrong = fields.copy()
      match change {
        "remove-policy" => wrong.remove("memory_admission_percent")
        "change-policy" => wrong["memory_admission_percent"] = Json(65)
        _ => wrong["num_envs"] = Json(128)
      }
      @fs.write_file(
        path,
        Json::object(wrong).stringify(),
        create_mode=TruncateExisting,
      )
      try inference_source_config(identity, args) catch {
        _ => ()
      } noraise {
        _ => fail("altered complete source config accepted by inference")
      }
    }
  }
  assert_eq(identity.stringify(), before)
  try
    inference_source_config(
      {
        "config": {
          "capacity_profile": "paper-4096",
          "memory_admission_percent": 80.5,
        },
      },
      [],
    )
  catch {
    _ => ()
  } noraise {
    _ => fail("CPU export would accept malformed source memory request")
  }
}
