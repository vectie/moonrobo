///|
fn digital_incident_evidence(
  id : String,
  version : String,
  text : String,
  provenance : String,
) -> Json {
  {
    "reference_id": id,
    "reference_version": version,
    "digest": @moonmoon_adapter.digital_digest(text),
    "provenance_ref": provenance,
  }
}

///|
/// Export the existing Bookkeeper ProductOutcomeSubmission wire contract.
/// A Robo review is evidence, never a Book acceptance or retention receipt.
pub fn digital_incident_export(
  request : @moonmoon_adapter.DigitalTrialImport,
  binding : @moonmoon_adapter.DigitalTrialBinding,
  events : Array[@moonmoon_adapter.DigitalTrialEvent],
) -> Json raise {
  if @moonmoon_adapter.decode_digital_trial(request) != binding {
    fail("Incident binding differs from original evidence")
  }
  guard events.last() is Some(review) &&
    review.kind == "review" &&
    review.trial_id == binding.trial_id &&
    !review.reviewer.trim().is_empty() &&
    !review.note.trim().is_empty() else {
    fail("Review the latest incident revision before export")
  }
  let has_loss = events.any(event => event.kind == "lost-ack")
  if !has_loss && binding.digital_result == "accepted" {
    fail(
      "There is no failed or acknowledgement-loss digital incident to export",
    )
  }
  let seconds = review.now_ms / 1000L
  if seconds < 0L || seconds > 2147483647L {
    fail("Review time is outside Book's integer timestamp contract")
  }
  let version = events.length().to_string()
  let provenance = "moonrobo:digital-trial:" + binding.trial_id + "@" + version
  let review_id = binding.trial_id + ":incident-review:" + review.event_id
  let result_id = binding.proof_id
  let trace_id = binding.attempt_id + ":history"
  let dossier_id = binding.trial_id + ":moonmoon-dossier"
  let trace : Json = {
    "authority": "digital-only",
    "binding": binding,
    "events": events,
  }
  let trace_text = trace.stringify(indent=2)
  let review_text = review.to_json().stringify(indent=2)
  let evidence = [
    digital_incident_evidence(
      result_id,
      binding.robot_revision,
      request.result_text,
      provenance,
    ),
    digital_incident_evidence(dossier_id, "1", request.dossier_text, provenance),
    digital_incident_evidence(trace_id, version, trace_text, provenance),
    digital_incident_evidence(review_id, version, review_text, provenance),
  ]
  let summary = "Reviewed inert digital incident for " +
    binding.robot_id +
    ": " +
    review.note +
    ". Original digital result: " +
    binding.digital_result +
    ". Physical readiness, telemetry and retry authority remain unqualified."
  let submission : Json = {
    "contract_version": "moonbook.bookkeeper.product_outcome_submission.v1",
    "submission": {
      "record_id": "moonrobo-digital-incident:" + binding.trial_id,
      "record_version": version,
      "record_digest": @moonmoon_adapter.digital_digest(trace_text),
    },
    "source_product": "moonrobo",
    "deliverable_title": "Reviewed digital incident " + binding.trial_id,
    "deliverable_summary": "Exact MoonMoon digital receipt and Robo inert acknowledgement history; not physical proof",
    "outcome_summary": summary,
    "owner_route": "/api/moonrobo/digital-trials/" + binding.trial_id,
    "evidence_refs": evidence,
    "decision_evidence_id": review_id,
    "observed_at": seconds.to_int(),
    "recorded_at": seconds.to_int(),
    "information_gap": {
      "present": has_loss,
      "severity": if has_loss {
        1
      } else {
        0
      },
      "summary": if has_loss {
        "An inert acknowledgement gap was observed; inspect the exact attempt history for its current reconciliation state"
      } else {
        "No additional information gap is asserted by this producer; Book review remains required"
      },
      "evidence_refs": [trace_id],
    },
    "recognition_gap": {
      "present": false,
      "severity": 0,
      "summary": "No recognition-gap finding is asserted by this bounded digital receipt; this is not a reviewed Book finding",
      "evidence_refs": [review_id],
    },
    "decisiveness_gap": {
      "present": false,
      "severity": 0,
      "summary": "No decisiveness-gap finding is asserted; no physical retry decision or authority is supplied",
      "evidence_refs": [review_id],
    },
    "capability_id": "digital-incident-lesson:" + binding.trial_id,
    "capability_version": version,
    "capability_change_digest": @moonmoon_adapter.digital_digest(review_text),
    "capability_summary": "Candidate guidance requiring Book review: " +
    review.note,
  }
  {
    "contract_id": "moonrobo.digital-incident-export.v1",
    "submission": submission,
    "evidence": [
      {
        "reference_id": result_id,
        "text": request.result_text,
        "digest": binding.result_digest,
      },
      {
        "reference_id": dossier_id,
        "text": request.dossier_text,
        "digest": @moonmoon_adapter.digital_digest(request.dossier_text),
      },
      {
        "reference_id": trace_id,
        "text": trace_text,
        "digest": @moonmoon_adapter.digital_digest(trace_text),
      },
      {
        "reference_id": review_id,
        "text": review_text,
        "digest": @moonmoon_adapter.digital_digest(review_text),
      },
    ],
    "retention_state": "pending-book-review",
    "book_receipt": (None : String?),
    "physical_execution_allowed": false,
    "limitations": [
      "Local reviewer name is an attribution, not an authenticated Book decision",
      "Import submission through Book's existing governed outcome flow; an accepted assessment and separately reviewed applicability are required before reusable lesson retention",
      "No matching durable Book receipt exists in this export", "No physical attempt, telemetry, device acknowledgement, current safety grant, or hardware readiness is established",
    ],
  }
}
