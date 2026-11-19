///|
fn clear_learning_fixture(path : String) -> Unit raise {
  if @fsx.path_exists(path) {
    if @fsx.is_dir(path) {
      for name in @fsx.read_dir(path) {
        clear_learning_fixture(path + "/" + name)
      }
      @fsx.remove_dir(path)
    } else {
      @fsx.remove_file(path)
    }
  }
}

///|
fn learning_fixture(root : String, qualifies : Bool) -> String raise {
  clear_learning_fixture(root)
  @fsx.create_dir(root)
  let run = root + "/run"
  @fsx.create_dir(run)
  for name in ["policy", "fit", "collection"] {
    @fsx.create_dir(run + "/" + name)
  }
  let policy : Json = {
    "format": "moonrobo.g1-policy-fit.v1",
    "runs": [
      {
        "seed": 0,
        "selected_update": 100,
        "baseline": {
          "trials": 9,
          "falls": 9,
          "mean_survival_s": 1.24,
          "mean_joint_rmse_rad": 0.097,
        },
        "candidate": {
          "trials": 9,
          "falls": 9,
          "mean_survival_s": 1.48,
          "mean_joint_rmse_rad": 0.115,
        },
        "qualifies": qualifies.to_json(),
        "checkpoint": "actor.pt",
        "latest_checkpoint": "latest.pt",
      },
    ],
    "extra_producer_field": "retained in original report",
  }
  let dynamics : Json = {
    "format": "moonrobo.dynamics-fit.v1",
    "runs": [{ "seed": 0, "checkpoint": "dynamics.pt" }],
  }
  @fsx.write_string_to_file(run + "/policy/report.json", policy.stringify())
  @fsx.write_string_to_file(run + "/fit/report.json", dynamics.stringify())
  @fsx.write_string_to_file(
    run + "/collection/dataset.json",
    "{\"fixture\":true}",
  )
  @fsx.write_string_to_file(
    run + "/policy/physics-seed-0.json",
    "{\"falls\":9}",
  )
  for path in ["policy/actor.pt", "policy/latest.pt", "fit/dynamics.pt"] {
    @fsx.write_bytes_to_file(run + "/" + path, b"\xff\x00\x80weights")
  }
  run
}

///|
fn reference_fixture_sha(path : String) -> String {
  @blob.local_file_checksum(path).unwrap().split(":").to_array()[1].to_owned()
}

///|
test "reference RL seals paired records and real cycle models without a standalone fit report" {
  let root = "target/learning-reference-rl-registration-test"
  let run = learning_fixture(root, false)
  clear_learning_fixture(run + "/fit")
  for
    folder in [
      "physics", "evidence", "evidence/checkpoints", "evidence/checkpoints/replay-prefix",
      "evidence/checkpoints/replay-prefix/seed-0", "collection/reference", "collection/reference/clips",
      "provider-sources",
    ] {
    @fsx.create_dir(run + "/" + folder)
  }
  let report = @json.parse(
    @fsx.read_file_to_string(run + "/policy/report.json"),
  )
  guard report is Object(fields) else { fail("policy") }
  fields["format"] = "moonrobo.g1-reference-learning-fit.v1"
  @fsx.write_string_to_file(run + "/policy/report.json", report.stringify())
  let files : Array[Json] = []
  let add = fn(path : String, kind : String, episode : String) -> Unit {
    files.push({
      "file": Json(path),
      "sha256": Json(reference_fixture_sha(run + "/" + path)),
      "kind": Json(kind),
      "episode_id": Json(episode),
    })
  }
  for
    (path, kind, episode) in [
      ("physics/episode.npz", "learning-reference-physics", "episode"),
      ("collection/reference/clips/clip.npz", "learning-reference-clip", ""),
      (
        "collection/reference/source-physics.jsonl.gz", "learning-reference-source-physics",
        "",
      ),
      ("policy/actor-zero-output.pt", "learning-reference-baseline", ""),
      ("policy/reference-charter.json", "learning-reference-charter", ""),
      ("collection/reference-quality.json", "learning-reference-quality", ""),
      (
        "evidence/checkpoints/replay-prefix/seed-0/actor-cycle-1.pt", "learning-reference-cycle-policy",
        "",
      ),
      (
        "evidence/checkpoints/replay-prefix/seed-0/dynamics-cycle-1.pt", "learning-dynamics-checkpoint",
        "",
      ),
      (
        "evidence/checkpoints/replay-prefix/seed-0/value-cycle-1.pt", "learning-reference-value",
        "",
      ),
    ] {
    @fsx.write_bytes_to_file(run + "/" + path, b"opaque numerical fixture")
    add(path, kind, episode)
  }
  for
    name in [
      "reference_learning_study.py", "reference_learning.py", "reference_task.py",
      "reference_actor.py",
    ] {
    @fsx.write_string_to_file(run + "/provider-sources/" + name, "# fixture")
    add("provider-sources/" + name, "learning-reference-provider", "")
  }
  let reference : Json = {
    "format": "moonrobo.g1-full-body-reference.v1",
    "source_physics_sha256": Json(
      reference_fixture_sha(
        run + "/collection/reference/source-physics.jsonl.gz",
      ),
    ),
    "clips": [
      {
        "file": "clips/clip.npz",
        "sha256": Json(
          reference_fixture_sha(run + "/collection/reference/clips/clip.npz"),
        ),
      },
    ],
  }
  @fsx.write_string_to_file(
    run + "/collection/reference/manifest.json",
    reference.stringify(),
  )
  add("collection/reference/manifest.json", "learning-reference-manifest", "")
  let code_sha = reference_fixture_sha(
    run + "/provider-sources/reference_learning_study.py",
  )
  let study : Json = {
    "format": "moonrobo.g1-reference-learning-comparison.v1",
    "reference_manifest_sha256": Json(
      reference_fixture_sha(run + "/collection/reference/manifest.json"),
    ),
    "physical_records": [
      {
        "episode_id": "episode",
        "sha256": Json(reference_fixture_sha(run + "/physics/episode.npz")),
      },
    ],
    "provider_sha256": Json(code_sha),
    "learning_provider_sha256": Json(code_sha),
    "task_provider_sha256": Json(code_sha),
    "actor_provider_sha256": Json(code_sha),
    "runs": [
      {
        "method": "replay-prefix",
        "seed": 0,
        "cycles": [
          {
            "cycle": 1,
            "checkpoint": {
              "sha256": Json(
                reference_fixture_sha(
                  run +
                  "/evidence/checkpoints/replay-prefix/seed-0/actor-cycle-1.pt",
                ),
              ),
            },
          },
        ],
      },
    ],
  }
  @fsx.write_string_to_file(
    run + "/policy/reference-study.json",
    study.stringify(),
  )
  add("policy/reference-study.json", "learning-reference-study", "")
  let verification : Json = {
    "source_report_sha256": Json(
      reference_fixture_sha(run + "/policy/reference-study.json"),
    ),
    "native_verification": { "all_records_validated": true, "episodes": 1 },
    "physical_execution_allowed": false,
  }
  @fsx.write_string_to_file(
    run + "/policy/reference-verification.json",
    verification.stringify(),
  )
  add(
    "policy/reference-verification.json", "learning-reference-verification", "",
  )
  @fsx.write_string_to_file(
    run + "/policy/reference-learning-evidence.json",
    (
      {
        "format": "moonrobo.g1-reference-learning-evidence.v1",
        "files": Json(files),
      } : Json).stringify(),
  )
  let store = root + "/moondata"
  @fsx.remove_file(
    run + "/evidence/checkpoints/replay-prefix/seed-0/dynamics-cycle-1.pt",
  )
  assert_true(
    @moondata_learning.import_run(store, run, "missing", 10L) is Err(_),
  )
  @fsx.write_bytes_to_file(
    run + "/evidence/checkpoints/replay-prefix/seed-0/dynamics-cycle-1.pt",
    b"opaque numerical fixture",
  )
  let imported = @moondata_learning.import_run(store, run, "rl", 10L).unwrap()
  assert_eq(
    imported.payloads
    .filter(p => p.data_ref.kind == "learning-dynamics-checkpoint")
    .length(),
    1,
  )
  assert_eq(
    imported.payloads
    .filter(p => p.data_ref.kind == "learning-reference-physics")
    .length(),
    1,
  )
  assert_false(imported.payloads.any(p => p.relative_path == "fit/report.json"))
  clear_learning_fixture(run)
  assert_eq(@moondata_learning.inspect(store, "rl").unwrap(), imported)
  assert_false(imported.physical_execution_allowed)
}

///|
test "reference policies seal clips and complete physical records without a fake dynamics fit" {
  let root = "target/learning-reference-registration-test"
  let run = learning_fixture(root, false)
  clear_learning_fixture(run + "/fit")
  for
    folder in [
      "collection/reference", "collection/reference/clips", "physics", "physics/seed-0",
      "provider-sources",
    ] {
    @fsx.create_dir(run + "/" + folder)
  }
  let policy = @json.parse(
    @fsx.read_file_to_string(run + "/policy/report.json"),
  )
  guard policy is Object(fields) else { fail("expected report") }
  fields["format"] = "moonrobo.g1-reference-policy-fit.v1"
  @fsx.write_string_to_file(run + "/policy/report.json", policy.stringify())
  let bytes = b"\x00\xffopaque-numeric-fixture"
  for
    path in [
      "collection/reference/clips/stand.npz", "physics/seed-0/stand.npz", "collection/reference/source-physics.jsonl.gz",
      "collection/reference-feedback.pt", "policy/actor-zero-output.pt",
    ] {
    @fsx.write_bytes_to_file(run + "/" + path, bytes)
  }
  @fsx.write_string_to_file(run + "/collection/reference-quality.json", "{}")
  @fsx.write_string_to_file(run + "/policy/reference-charter.json", "{}")
  for
    name in [
      "reference_initialization.py", "reference_actor.py", "full_body_reference.py",
      "balance_features.py", "cpu_physics.py", "reference_initialization_export.py",
      "reference_registry_export.py",
    ] {
    @fsx.write_string_to_file(
      run + "/provider-sources/" + name,
      "# numerical fixture",
    )
  }
  let manifest : Json = {
    "format": "moonrobo.g1-full-body-reference.v1",
    "source_physics_sha256": Json(
      reference_fixture_sha(
        run + "/collection/reference/source-physics.jsonl.gz",
      ),
    ),
    "clips": [
      {
        "file": "clips/stand.npz",
        "sha256": Json(
          reference_fixture_sha(run + "/collection/reference/clips/stand.npz"),
        ),
      },
    ],
  }
  @fsx.write_string_to_file(
    run + "/collection/reference/manifest.json",
    manifest.stringify(),
  )
  let study : Json = {
    "format": "moonrobo.g1-reference-initialization.v1",
    "reference_manifest_sha256": Json(
      reference_fixture_sha(run + "/collection/reference/manifest.json"),
    ),
    "quality_sha256": Json(
      reference_fixture_sha(run + "/collection/reference-quality.json"),
    ),
    "feedback_checkpoint_sha256": Json(
      reference_fixture_sha(run + "/collection/reference-feedback.pt"),
    ),
    "provider_sha256": Json(
      reference_fixture_sha(
        run + "/provider-sources/reference_initialization.py",
      ),
    ),
    "actor_provider_sha256": Json(
      reference_fixture_sha(run + "/provider-sources/reference_actor.py"),
    ),
    "harness_sha256": Json(
      reference_fixture_sha(run + "/provider-sources/full_body_reference.py"),
    ),
    "evaluations": [
      {
        "records": [
          {
            "file": "physics/seed-0/stand.npz",
            "sha256": Json(
              reference_fixture_sha(run + "/physics/seed-0/stand.npz"),
            ),
          },
        ],
      },
    ],
    "baseline": { "records": [] },
  }
  @fsx.write_string_to_file(
    run + "/policy/reference-study.json",
    study.stringify(),
  )
  let verification : Json = {
    "source_report_sha256": Json(
      reference_fixture_sha(run + "/policy/reference-study.json"),
    ),
    "native_verification": { "all_episodes_validated": true, "episodes": 1 },
    "physical_execution_allowed": false,
  }
  @fsx.write_string_to_file(
    run + "/policy/reference-verification.json",
    verification.stringify(),
  )
  @fsx.remove_file(run + "/physics/seed-0/stand.npz")
  let store = root + "/moondata"
  assert_true(
    @moondata_learning.import_run(store, run, "missing", 10L) is Err(_),
  )
  @fsx.write_bytes_to_file(run + "/physics/seed-0/stand.npz", bytes)
  let imported = @moondata_learning.import_run(store, run, "reference", 10L).unwrap()
  assert_false(imported.physical_execution_allowed)
  assert_false(imported.payloads.any(p => p.data_ref.kind.contains("dynamics")))
  assert_eq(
    imported.payloads
    .filter(p => p.data_ref.kind == "learning-reference-clip")
    .length(),
    1,
  )
  assert_eq(
    imported.payloads
    .filter(p => p.data_ref.kind == "learning-reference-physics")
    .length(),
    1,
  )
  assert_eq(
    @moondata_learning.import_run(store, run, "reference", 20L).unwrap(),
    imported,
  )
  @fsx.write_bytes_to_file(run + "/physics/seed-0/stand.npz", b"changed")
  assert_true(
    @moondata_learning.import_run(store, run, "reference", 20L) is Err(_),
  )
  clear_learning_fixture(run)
  assert_eq(@moondata_learning.inspect(store, "reference").unwrap(), imported)
  assert_eq(
    @validate.validate_root(store, generated_at_ms=30L).unwrap().status,
    "passed",
  )
}

///|
test "standalone temporal PPO keeps actual training logs without dynamics payloads" {
  let root = "target/learning-ppo-registration-test"
  let run = learning_fixture(root, false)
  clear_learning_fixture(run + "/fit")
  let policy = @json.parse(
    @fsx.read_file_to_string(run + "/policy/report.json"),
  )
  guard policy is Object(fields) else { fail("expected report") }
  fields.set("format", "moonrobo.g1-temporal-ppo-fit.v1")
  fields.set("learned_transition_model_used", false)
  @fsx.write_string_to_file(run + "/policy/report.json", policy.stringify())
  let bytes = b"\x1f\x8b\x08\x00\x00\x00\x00\x00\x00\x03\x03\x00\x00\x00\x00\x00\x00\x00\x00\x00"
  @fsx.write_bytes_to_file(run + "/policy/ppo-physics-seed-0.jsonl.gz", bytes)
  let data_root = root + "/moondata"
  let imported = @moondata_learning.import_run(data_root, run, "ppo", 10L).unwrap()
  assert_false(imported.physical_execution_allowed)
  assert_false(imported.candidates[0].producer_qualified)
  assert_false(imported.payloads.any(p => p.data_ref.kind.contains("dynamics")))
  let logs = imported.payloads.filter(p => {
    p.data_ref.kind == "learning-ppo-physics"
  })
  assert_eq(logs.length(), 1)
  assert_eq(logs[0].data_ref.checksum, @data.bytes_checksum(bytes))
  clear_learning_fixture(run)
  let stored = data_root +
    "/" +
    @data.moondata_payload_uri_relative_path(logs[0].data_ref.uri).unwrap()
  assert_eq(
    @blob.read_local_file_range(stored, 0L, bytes.length()).unwrap(),
    bytes,
  )
  assert_eq(@moondata_learning.inspect(data_root, "ppo").unwrap(), imported)
  assert_eq(
    @moondata_learning.read_physics(data_root, "ppo", 0).unwrap().report,
    ({ "falls": 9 } : Json),
  )
  assert_eq(
    @validate.validate_root(data_root, generated_at_ms=20L).unwrap().status,
    "passed",
  )
}

///|
test "supervised disturbance registration retains training and separate audit evidence" {
  let root = "target/learning-disturbance-registration-test"
  let run = learning_fixture(root, false)
  clear_learning_fixture(run + "/fit")
  let policy = @json.parse(
    @fsx.read_file_to_string(run + "/policy/report.json"),
  )
  guard policy is Object(fields) else { fail("expected report") }
  fields.set("format", "moonrobo.g1-temporal-disturbance-fit.v1")
  @fsx.write_string_to_file(run + "/policy/report.json", policy.stringify())
  let training = b"\x1f\x8btraining-with-separate-teacher-labels"
  let audit = b"\x1f\x8bnever-fitted-audit"
  @fsx.write_bytes_to_file(
    run + "/policy/disturbance-physics-seed-0.jsonl.gz",
    training,
  )
  @fsx.write_bytes_to_file(
    run + "/policy/disturbance-audit-seed-0.jsonl.gz",
    audit,
  )
  let data_root = root + "/moondata"
  let imported = @moondata_learning.import_run(
    data_root, run, "disturbance", 10L,
  ).unwrap()
  assert_false(imported.physical_execution_allowed)
  assert_false(imported.payloads.any(p => p.data_ref.kind.contains("dynamics")))
  clear_learning_fixture(run)
  for
    (kind, expected) in [
      ("learning-supervised-physics", training),
      ("learning-disturbance-audit", audit),
    ] {
    let logs = imported.payloads.filter(p => p.data_ref.kind == kind)
    assert_eq(logs.length(), 1)
    assert_eq(logs[0].data_ref.checksum, @data.bytes_checksum(expected))
    let stored = data_root +
      "/" +
      @data.moondata_payload_uri_relative_path(logs[0].data_ref.uri).unwrap()
    assert_eq(
      @blob.read_local_file_range(stored, 0L, expected.length()).unwrap(),
      expected,
    )
  }
  assert_eq(
    @moondata_learning.read_physics(data_root, "disturbance", 0).unwrap().report,
    ({ "falls": 9 } : Json),
  )
  assert_eq(
    @validate.validate_root(data_root, generated_at_ms=20L).unwrap().status,
    "passed",
  )
}

///|
test "learned balance preserves shared training labels and evaluation without dynamics" {
  let root = "target/learning-balance-registration-test"
  let run = learning_fixture(root, false)
  clear_learning_fixture(run + "/fit")
  let policy = @json.parse(
    @fsx.read_file_to_string(run + "/policy/report.json"),
  )
  guard policy is Object(fields) else { fail("expected report") }
  fields.set("format", "moonrobo.g1-learned-balance-fit.v1")
  fields.set("head_fit_count", 1)
  fields.set("seed_semantics", "frozen parent seed; one shared fitted head")
  @fsx.write_string_to_file(run + "/policy/report.json", policy.stringify())
  let training = b"\x1f\x8btrain-only-physics-and-separate-float32-teacher-labels"
  let evaluation = b"\x1f\x8bcanonical-and-independent-training-family-audit"
  let selection = b"\x1f\x8btrain-family-architecture-selection-not-fit-labels"
  @fsx.write_bytes_to_file(
    run + "/collection/balance-training.jsonl.gz",
    training,
  )
  @fsx.write_bytes_to_file(
    run + "/policy/balance-evaluation.jsonl.gz",
    evaluation,
  )
  @fsx.write_bytes_to_file(
    run + "/policy/balance-selection.jsonl.gz",
    selection,
  )
  @fsx.write_string_to_file(run + "/collection/training-sources.json", "[]")
  @fsx.write_string_to_file(
    run + "/policy/balance-study.json",
    "{\"release_qualified\":false}",
  )
  let data_root = root + "/moondata"
  let imported = @moondata_learning.import_run(data_root, run, "balance", 10L).unwrap()
  assert_false(imported.physical_execution_allowed)
  assert_false(imported.payloads.any(p => p.data_ref.kind.contains("dynamics")))
  clear_learning_fixture(run)
  for
    (kind, expected) in [
      ("learning-balance-training", training),
      ("learning-balance-evaluation", evaluation),
      ("learning-balance-selection", selection),
    ] {
    let payloads = imported.payloads.filter(p => p.data_ref.kind == kind)
    assert_eq(payloads.length(), 1)
    assert_eq(payloads[0].data_ref.checksum, @data.bytes_checksum(expected))
    let stored = data_root +
      "/" +
      @data.moondata_payload_uri_relative_path(payloads[0].data_ref.uri).unwrap()
    assert_eq(
      @blob.read_local_file_range(stored, 0L, expected.length()).unwrap(),
      expected,
    )
  }
  assert_eq(@moondata_learning.inspect(data_root, "balance").unwrap(), imported)
  assert_eq(
    @moondata_learning.read_physics(data_root, "balance", 0).unwrap().report,
    ({ "falls": 9 } : Json),
  )
  assert_eq(
    @validate.validate_root(data_root, generated_at_ms=20L).unwrap().status,
    "passed",
  )
}

///|
test "learned balance cannot register without its fitted training record" {
  let root = "target/learning-balance-missing-test"
  let run = learning_fixture(root, false)
  clear_learning_fixture(run + "/fit")
  let policy = @json.parse(
    @fsx.read_file_to_string(run + "/policy/report.json"),
  )
  guard policy is Object(fields) else { fail("expected report") }
  fields.set("format", "moonrobo.g1-learned-balance-fit.v1")
  @fsx.write_string_to_file(run + "/policy/report.json", policy.stringify())
  assert_true(
    @moondata_learning.import_run(root + "/moondata", run, "missing", 10L)
    is Err(_),
  )
  assert_true(
    @moondata_learning.inspect(root + "/moondata", "missing") is Err(_),
  )
}

///|
test "compressed transition datasets remain binary payloads after source removal" {
  let root = "target/learning-compressed-registration-test"
  let run = learning_fixture(root, false)
  @fsx.remove_file(run + "/collection/dataset.json")
  // A valid empty gzip stream exercises the byte store, not dataset parsing.
  let bytes = b"\x1f\x8b\x08\x00\x00\x00\x00\x00\x00\x03\x03\x00\x00\x00\x00\x00\x00\x00\x00\x00"
  @fsx.write_bytes_to_file(run + "/collection/dataset.json.gz", bytes)
  let data_root = root + "/moondata"
  let imported = @moondata_learning.import_run(
    data_root, run, "compressed", 10L,
  ).unwrap()
  let payloads = imported.payloads.filter(p => {
    p.data_ref.kind == "learning-transition-dataset"
  })
  assert_eq(payloads.length(), 1)
  assert_eq(payloads[0].relative_path, "collection/dataset.json.gz")
  assert_eq(payloads[0].data_ref.checksum, @data.bytes_checksum(bytes))
  clear_learning_fixture(run)
  let path = data_root +
    "/" +
    @data.moondata_payload_uri_relative_path(payloads[0].data_ref.uri).unwrap()
  assert_eq(
    @blob.read_local_file_range(path, 0L, bytes.length()).unwrap(),
    bytes,
  )
}

///|
test "experiment registration preserves binary evidence and immutable identities" {
  let root = "target/learning-registration-test"
  let run = learning_fixture(root, false)
  let critic_bytes = b"\x1f\x8b\x08\x00\x00\x00\x00\x00\x00\x03\x03\x00\x00\x00\x00\x00\x00\x00\x00\x00"
  @fsx.write_bytes_to_file(
    run + "/policy/critic-physics-seed-0.jsonl.gz",
    critic_bytes,
  )
  let latest_model_bytes = b"\x00\xfflatest-model"
  @fsx.write_bytes_to_file(
    run + "/fit/latest-dynamics-seed-0.pt",
    latest_model_bytes,
  )
  let data_root = root + "/moondata"
  let imported = @moondata_learning.import_run(data_root, run, "round-one", 10L).unwrap()
  assert_eq(imported.physical_execution_allowed, false)
  assert_eq(imported.evidence_class, "physics-simulation")
  assert_eq(imported.candidates[0].producer_qualified, false)
  assert_eq(imported.candidates[0].candidate.falls, 9)
  assert_true(imported.candidates[0].survival_delta_s > 0.23)
  let checkpoint = imported.candidates[0].checkpoint_ref
  let critic_payloads = imported.payloads.filter(payload => {
    payload.data_ref.kind == "learning-critic-physics"
  })
  assert_eq(critic_payloads.length(), 1)
  let latest_models = imported.payloads.filter(payload => {
    payload.data_ref.kind == "learning-latest-dynamics-checkpoint"
  })
  assert_eq(latest_models.length(), 1)
  assert_eq(
    latest_models[0].data_ref.checksum,
    @data.bytes_checksum(latest_model_bytes),
  )
  assert_eq(
    critic_payloads[0].data_ref.checksum,
    @data.bytes_checksum(critic_bytes),
  )
  assert_eq(checkpoint.checksum, @data.bytes_checksum(b"\xff\x00\x80weights"))
  let relative = @data.moondata_payload_uri_relative_path(checkpoint.uri).unwrap()
  assert_eq(
    @blob.read_local_file_range(data_root + "/" + relative, 0L, 10).unwrap(),
    b"\xff\x00\x80weights",
  )
  let again = @moondata_learning.import_run(data_root, run, "round-one", 20L).unwrap()
  assert_eq(again, imported)
  let physics = @moondata_learning.read_physics(data_root, "round-one", 0).unwrap()
  assert_eq(physics.report, ({ "falls": 9 } : Json))
  assert_eq(physics.physical_execution_allowed, false)
  assert_eq(physics.original_duration_s, None)
  assert_true(
    @moondata_learning.read_physics(data_root, "round-one", 99) is Err(_),
  )
  let second = @moondata_learning.import_run(data_root, run, "round-two", 30L).unwrap()
  assert_eq(second.candidates[0].checkpoint_ref.uri, checkpoint.uri)
  assert_eq(@moondata_learning.list(data_root).unwrap().length(), 2)
  let validation = @validate.validate_root(data_root, generated_at_ms=40L).unwrap()
  assert_eq(validation.status, "passed", msg=validation.to_json().stringify())
  @fsx.write_bytes_to_file(run + "/policy/actor.pt", b"changed")
  assert_true(
    @moondata_learning.import_run(data_root, run, "round-one", 50L) is Err(_),
  )
  // Read summaries and weights solely from MoonData after deleting the original run.
  clear_learning_fixture(run)
  let latest_model_path = data_root +
    "/" +
    @data.moondata_payload_uri_relative_path(latest_models[0].data_ref.uri).unwrap()
  assert_eq(
    @blob.read_local_file_range(
      latest_model_path,
      0L,
      latest_model_bytes.length(),
    ).unwrap(),
    latest_model_bytes,
  )
  let critic_path = data_root +
    "/" +
    @data.moondata_payload_uri_relative_path(critic_payloads[0].data_ref.uri).unwrap()
  assert_eq(
    @blob.read_local_file_range(critic_path, 0L, 20).unwrap(),
    critic_bytes,
  )
  assert_eq(
    @moondata_learning.read_physics(data_root, "round-one", 0).unwrap(),
    physics,
  )
  let physics_path = data_root +
    "/" +
    @data.moondata_payload_uri_relative_path(physics.data_ref.uri).unwrap()
  @fsx.write_string_to_file(physics_path, "{}")
  assert_true(
    @moondata_learning.read_physics(data_root, "round-one", 0) is Err(_),
  )
  assert_eq(
    @moondata_learning.inspect(data_root, "round-one").unwrap(),
    imported,
  )
  let source = @store.read_source(data_root, imported.source_id).unwrap()
  let summary = source.source_refs.filter(data_ref => {
      data_ref.kind == "learning-summary"
    })[0]
  let summary_path = data_root +
    "/" +
    @data.moondata_payload_uri_relative_path(summary.uri).unwrap()
  @fsx.write_string_to_file(summary_path, "{}")
  assert_true(@moondata_learning.inspect(data_root, "round-one") is Err(_))
}

///|
test "evaluation duration comes from sealed report after removing the run" {
  let root = "target/learning-duration-registration-test"
  let run = learning_fixture(root, false)
  let policy = @json.parse(
    @fsx.read_file_to_string(run + "/policy/report.json"),
  )
  guard policy is Object(fields) else { fail("expected fixture report") }
  fields.set("experiment", { "duration_s": 10 })
  @fsx.write_string_to_file(run + "/policy/report.json", policy.stringify())
  ignore(
    @moondata_learning.import_run(root + "/moondata", run, "ten-second", 10L).unwrap(),
  )
  clear_learning_fixture(run)
  let physics = @moondata_learning.read_physics(
    root + "/moondata",
    "ten-second",
    0,
  ).unwrap()
  assert_eq(physics.original_duration_s, Some(10.0))
  assert_eq(physics.physical_execution_allowed, false)
}

///|
test "contradictory qualification does not create an experiment source" {
  let root = "target/learning-registration-invalid-test"
  let run = learning_fixture(root, true)
  let data_root = root + "/moondata"
  assert_true(
    @moondata_learning.import_run(data_root, run, "invalid", 10L) is Err(_),
  )
  assert_true(
    !@fsx.path_exists(@store.source_path(data_root, "learning-invalid")),
  )
}

///|
test "registered extended failures remain readable after removing the original run" {
  let root = "target/learning-followup-registration-test"
  let run = learning_fixture(root, false)
  let data_root = root + "/moondata"
  let followup : Json = {
    "format": "moonrobo.g1-candidate-followup.v1",
    "physical_execution_allowed": false,
    "candidates": [],
  }
  let extended : Json = { "extended_falls": 9 }
  @fsx.write_string_to_file(
    run + "/policy/qualification-followup.json",
    followup.stringify(),
  )
  @fsx.create_dir(run + "/candidate-followup")
  @fsx.create_dir(run + "/candidate-followup/seed-0-fresh-ten-second")
  @fsx.write_string_to_file(
    run + "/candidate-followup/seed-0-fresh-ten-second/physics.json",
    extended.stringify(),
  )
  let registered = @moondata_learning.import_run(data_root, run, "scoped", 10L).unwrap()
  assert_true(
    registered.payloads.any(payload => {
      payload.data_ref.kind == "learning-qualification-followup"
    }),
  )
  let evidence = @moondata_learning.read_physics(
    data_root,
    "scoped",
    0,
    mode="fresh-ten-second",
  ).unwrap()
  assert_eq(evidence.report, extended)
  assert_eq(evidence.followup, Some(followup))
  assert_eq(evidence.evaluation_mode, Some("fresh-ten-second"))
  assert_eq(evidence.physical_execution_allowed, false)
  clear_learning_fixture(run)
  assert_eq(
    @moondata_learning.read_physics(
      data_root,
      "scoped",
      0,
      mode="fresh-ten-second",
    ).unwrap(),
    evidence,
  )
  assert_eq(
    @validate.validate_root(data_root, generated_at_ms=20L).unwrap().status,
    "passed",
  )
}
