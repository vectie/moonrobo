///|
fn q12_request(
  trial_id : String,
  session_id : String,
) -> @moonmoon_adapter.DigitalTrialImport raise {
  let dossier_text = @fsx.read_file_to_string("fixtures/moonmoon-study.json")
  guard @json.parse(dossier_text) is { "dossier_json": String(text), .. } else {
    fail("fixture envelope")
  }
  guard @json.parse(text) is { "sources": Array(sources), .. } else {
    fail("fixture sources")
  }
  let result_ref = ".moonsuite/products/moonmoon/mission-sessions/" +
    session_id +
    "/mission-result.json"
  for source in sources {
    if source
      is { "artifact_ref": String(path), "text": String(result_text), .. } &&
      path == result_ref {
      return { trial_id, session_id, dossier_text, result_text, }
    }
  }
  fail("missing actual MoonMoon fixture")
}

///|
fn q12_root(
  label : String,
  request : @moonmoon_adapter.DigitalTrialImport,
) -> String raise {
  let root = "/tmp/moonrobo-q12-digital-trial-" + label
  ensure_dir(root)
  clear_json_files_deep(root)
  ensure_dir(root + "/model")
  ensure_dir(root + "/design")
  guard @json.parse(request.dossier_text)
    is { "dossier_json": String(text), .. } else {
    fail("fixture envelope")
  }
  guard @json.parse(text) is { "sources": Array(sources), .. } else {
    fail("fixture sources")
  }
  for source in sources {
    if source is { "artifact_ref": String(path), "text": String(bytes), .. } &&
      path.has_prefix("books/test-rover/") {
      let relative = path["books/test-rover/".length():].to_owned()
      if relative == "robot.json" ||
        relative == "model/robot.urdf" ||
        relative == "design/validation-receipt.json" {
        @fsx.write_string_to_file(root + "/" + relative, bytes)
      }
    }
  }
  root
}

///|
fn q12_view(
  response : @host_api.HostApiResponse,
) -> @runtime.DigitalTrialView raise {
  assert_eq(response.status, 200, msg=response.body)
  @json.from_json(@json.parse(response.body))
}

///|
fn q12_event(
  trial_id : String,
  revision : Int,
  kind : String,
  proof : String,
) -> @moonmoon_adapter.DigitalTrialEvent {
  {
    trial_id,
    expected_revision: revision,
    event_id: kind + "-" + revision.to_string(),
    kind,
    proof_text: proof,
    reviewer: "Local digital test reviewer",
    note: "Inspect exact digital evidence; keep unknowns and never infer physical retry authority",
    now_ms: (revision + 1).to_int64() * 1000L,
  }
}

///|
test "Q12 actual MoonMoon exports bind robot profile URDF and missing calibration honestly" {
  let request = q12_request("accepted", "q11-a")
  let root = q12_root("accepted", request)
  let view = q12_view(
    @host_api.route_with_body(
      root,
      "POST",
      "/api/moonrobo/digital-trials/import",
      request.to_json().stringify(),
    ),
  )
  assert_eq(
    view.record.binding.result_digest,
    "sha256:0f406a1bdb5a13810d812540aac9a101541be485144e951f88eb477a379b5acc",
  )
  assert_eq(view.digital_result_state, "digital-ready")
  assert_eq(view.state, "unknown")
  assert_eq(view.binding_state, "unknown")
  assert_eq(view.record.binding.calibration_source_digest, "")
  assert_true(!view.physical_execution_allowed && !view.automatic_retry_allowed)
  assert_true(view.unknowns.any(text => text.contains("calibration")))
  assert_eq(
    q12_view(
      @host_api.route(root, "GET", "/api/moonrobo/digital-trials/accepted"),
    ),
    view,
  )
  assert_eq(
    q12_view(
      @host_api.route_with_body(
        root,
        "POST",
        "/api/moonrobo/digital-trials/import",
        request.to_json().stringify(),
      ),
    ),
    view,
  )
}

///|
test "Q12 exported negative result remains blocked and unchanged" {
  let request = q12_request("blocked", "q11-b")
  assert_eq(
    request.result_text,
    @fsx.read_file_to_string("fixtures/moonmoon-blocked-result.json"),
  )
  let root = q12_root("blocked", request)
  let view = q12_view(
    @host_api.digital_trial_import_response(root, request.to_json().stringify()),
  )
  assert_eq(view.state, "blocked")
  assert_eq(view.digital_result_state, "blocked")
  assert_eq(
    view.record.binding.result_digest,
    "sha256:2b1285f698cb7747a687c07ce110547242d3165e229a364c999fa2a57888cca6",
  )
  assert_true(view.blockers.any(text => text.contains("energy")))
  assert_true(view.blockers.any(text => text.contains("absent")))
  assert_eq(view.record.import_request.result_text, request.result_text)
}

///|
test "Q12 wrong current profile URDF or missing evidence blocks or remains unknown" {
  let request = q12_request("target", "q11-a")
  let root = q12_root("target", request)
  let _ = q12_view(
    @host_api.digital_trial_import_response(root, request.to_json().stringify()),
  )
  @fsx.write_string_to_file(root + "/robot.json", "{\"id\":\"another-robot\"}")
  let wrong = q12_view(@host_api.digital_trial_response(root, "target"))
  assert_eq(wrong.binding_state, "blocked")
  assert_eq(wrong.state, "blocked")
  assert_true(wrong.blockers.any(text => text.contains("robot profile")))
  @fsx.remove_file(root + "/model/robot.urdf")
  let missing = q12_view(@host_api.digital_trial_response(root, "target"))
  assert_true(missing.unknowns.any(text => text.contains("URDF")))
  assert_true(!missing.physical_execution_allowed)
}

///|
test "Q12 exact bytes reject result tampering wrong selection and conflicting trial replay" {
  let request = q12_request("identity", "q11-a")
  let root = q12_root("identity", request)
  let _ = q12_view(
    @host_api.digital_trial_import_response(root, request.to_json().stringify()),
  )
  for
    bad in [
      { ..request, result_text: request.result_text + " ", },
      { ..request, session_id: "q11-b", },
      { ..request, trial_id: "../escape", },
      q12_request("identity", "q11-b"),
    ] {
    assert_eq(
      @host_api.digital_trial_import_response(root, bad.to_json().stringify()).status,
      409,
    )
  }
  assert_eq(
    q12_view(@host_api.digital_trial_response(root, "identity")).record.import_request,
    request,
  )
}

///|
test "Q12 inert lost acknowledgement remains unknown on reopen and exact proof reconciles same attempt" {
  let request = q12_request("ack", "q11-a")
  let root = q12_root("ack", request)
  let imported = q12_view(
    @host_api.digital_trial_import_response(root, request.to_json().stringify()),
  )
  let loss = q12_event("ack", 0, "lost-ack", "")
  let unknown = q12_view(
    @host_api.digital_trial_event_response(root, loss.to_json().stringify()),
  )
  assert_eq(unknown.acknowledgement_state, "unknown")
  assert_eq(unknown.state, "unknown")
  assert_true(!unknown.automatic_retry_allowed)
  assert_eq(q12_view(@host_api.digital_trial_response(root, "ack")), unknown)
  assert_eq(
    q12_view(
      @host_api.digital_trial_event_response(root, loss.to_json().stringify()),
    ),
    unknown,
  )
  let bad = q12_event(
    "ack",
    1,
    "reconcile",
    q12_request("other", "q11-b").result_text,
  )
  assert_eq(
    @host_api.digital_trial_event_response(root, bad.to_json().stringify()).status,
    409,
  )
  let reviewed = q12_view(
    @host_api.digital_trial_event_response(
      root,
      q12_event("ack", 1, "review", "").to_json().stringify(),
    ),
  )
  assert_eq(reviewed.acknowledgement_state, "unknown")
  let reconciled = q12_view(
    @host_api.digital_trial_event_response(
      root,
      q12_event("ack", 2, "reconcile", request.result_text)
      .to_json()
      .stringify(),
    ),
  )
  assert_eq(reconciled.acknowledgement_state, "confirmed")
  assert_eq(
    reconciled.record.binding.attempt_id,
    imported.record.binding.attempt_id,
  )
  assert_eq(reconciled.record.import_request.result_text, request.result_text)
  assert_true(
    !reconciled.physical_execution_allowed &&
    !reconciled.automatic_retry_allowed,
  )
}

///|
test "Q12 reviewed incident exports exact existing Book submission contract and pending retention" {
  let request = q12_request("incident", "q11-b")
  let root = q12_root("incident", request)
  let _ = q12_view(
    @host_api.digital_trial_import_response(root, request.to_json().stringify()),
  )
  let export_body = "{\"trial_id\":\"incident\"}"
  assert_eq(
    @host_api.digital_trial_export_response(root, export_body).status,
    409,
  )
  let reviewed = q12_view(
    @host_api.digital_trial_event_response(
      root,
      q12_event("incident", 0, "review", "").to_json().stringify(),
    ),
  )
  let exported = @host_api.route_with_body(
    root, "POST", "/api/moonrobo/digital-trials/export", export_body,
  )
  assert_eq(exported.status, 200, msg=exported.body)
  guard @json.parse(exported.body)
    is {
      "submission": {
        "contract_version": String(contract),
        "source_product": String(product),
        "evidence_refs": Array(refs),
        "decision_evidence_id": String(decision),
        ..
      },
      "evidence": Array(evidence),
      "retention_state": String(state),
      "book_receipt": Null,
      "physical_execution_allowed": False,
      ..
    } else {
    fail("Book export contract")
  }
  assert_eq(contract, "moonbook.bookkeeper.product_outcome_submission.v1")
  assert_eq(product, "moonrobo")
  assert_eq(state, "pending-book-review")
  assert_true(
    refs.any(ref => ref is { "reference_id": String(id), .. } && id == decision),
  )
  assert_true(
    evidence.any(item => {
      item is { "text": String(text), "digest": String(digest), .. } &&
      text == request.result_text &&
      digest == reviewed.record.binding.result_digest
    }),
  )
  assert_eq(
    q12_view(@host_api.digital_trial_response(root, "incident")),
    reviewed,
  )
  @fsx.write_string_to_file("/tmp/moonrobo-q12-book-export.json", exported.body)
}

///|
test "Q12 partial persisted event is unconfirmed without repairing or retrying" {
  let request = q12_request("partial", "q11-a")
  let root = q12_root("partial", request)
  let _ = q12_view(
    @host_api.digital_trial_import_response(root, request.to_json().stringify()),
  )
  let path = @runtime.moonrobo_proof_sessions_dir(root) +
    "/digital-trials/partial/event-1.json"
  @fsx.write_string_to_file(path, "{\"kind\":")
  assert_eq(@host_api.digital_trial_response(root, "partial").status, 409)
  assert_eq(
    @host_api.digital_trial_event_response(
      root,
      q12_event("partial", 0, "lost-ack", "").to_json().stringify(),
    ).status,
    409,
  )
  assert_eq(@fsx.read_file_to_string(path), "{\"kind\":")
}

///|
test "Q12 missing last acknowledgement event or interrupted head cannot become confirmed on reopen" {
  let request = q12_request("head", "q11-a")
  let root = q12_root("head", request)
  let _ = q12_view(
    @host_api.digital_trial_import_response(root, request.to_json().stringify()),
  )
  let event = q12_event("head", 0, "lost-ack", "")
  let _ = q12_view(
    @host_api.digital_trial_event_response(root, event.to_json().stringify()),
  )
  let dir = @runtime.moonrobo_proof_sessions_dir(root) + "/digital-trials/head"
  let original = @fsx.read_file_to_string(dir + "/event-1.json")
  @fsx.remove_file(dir + "/event-1.json")
  assert_eq(@host_api.digital_trial_response(root, "head").status, 409)
  @fsx.write_string_to_file(dir + "/event-1.json", original)
  assert_eq(
    q12_view(@host_api.digital_trial_response(root, "head")).acknowledgement_state,
    "unknown",
  )
  @fsx.write_string_to_file(dir + "/head.json", "{}")
  assert_eq(@host_api.digital_trial_response(root, "head").status, 409)
}

///|
test "Q12 stale or cross-trial events cannot review or reconcile another attempt" {
  let request = q12_request("stale", "q11-b")
  let root = q12_root("stale", request)
  let _ = q12_view(
    @host_api.digital_trial_import_response(root, request.to_json().stringify()),
  )
  let event = q12_event("stale", 0, "lost-ack", "")
  let unknown = q12_view(
    @host_api.digital_trial_event_response(root, event.to_json().stringify()),
  )
  for
    bad in [
      q12_event("stale", 0, "review", ""),
      q12_event("other", 1, "reconcile", request.result_text),
      { ..event, note: "Changed replay", },
    ] {
    assert_eq(
      @host_api.digital_trial_event_response(root, bad.to_json().stringify()).status,
      409,
    )
  }
  assert_eq(q12_view(@host_api.digital_trial_response(root, "stale")), unknown)
}

///|
test "Q12 self-consistently rehashed baseline grid cannot drift from the frozen design" {
  let request = q12_request("baseline-grid", "q11-a")
  let root = q12_root("baseline-grid", request)
  for
    field_name in [
      "cell_size_m", "whole_grid_status", "whole_grid_max_neighbor_grade_deg",
    ] {
    guard @json.parse(request.dossier_text) is Object(envelope) &&
      envelope["dossier_json"] is String(dossier_text) else {
      fail("envelope")
    }
    guard @json.parse(dossier_text) is Object(dossier) &&
      dossier["alternatives"] is Array(alternatives) &&
      alternatives[0] is Object(alternative) &&
      alternative["baseline_json"] is String(baseline_text) else {
      fail("baseline")
    }
    guard @json.parse(baseline_text) is Object(baseline) else {
      fail("baseline object")
    }
    baseline[field_name] = if field_name == "whole_grid_status" {
      "verified"
    } else {
      999
    }
    let changed_baseline = Json::object(baseline).stringify()
    alternative["baseline_json"] = changed_baseline.to_json()
    alternative["baseline_digest"] = @moonmoon_adapter.digital_digest(
      changed_baseline,
    ).to_json()
    let changed_dossier = Json::object(dossier).stringify()
    envelope["dossier_json"] = changed_dossier.to_json()
    envelope["dossier_digest"] = @moonmoon_adapter.digital_digest(
      changed_dossier,
    ).to_json()
    let changed = {
      ..request,
      dossier_text: Json::object(envelope).stringify(),
    }
    let response = @host_api.digital_trial_import_response(
      root,
      changed.to_json().stringify(),
    )
    assert_eq(response.status, 409)
    assert_true(response.body.contains("Baseline terrain/grid mismatch"))
  }
}
