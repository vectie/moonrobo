///|
pub(all) struct AdapterRuntimeIssue {
  code : String
  path : String
  message : String
} derive(Debug, Eq, ToJson, FromJson)

///|
fn issue(code : String, path : String, message : String) -> AdapterRuntimeIssue {
  { code, path, message, }
}

///|
fn trim_trailing_slash(path : String) -> String {
  let mut value = path
  while value.length() > 1 && value.has_suffix("/") {
    value = value[:value.length() - 1].to_owned()
  }
  value
}

///|
fn valid_relative_ref(value : String) -> Bool {
  let normalized = value.trim().replace(old="\\", new="/")
  !normalized.is_empty() &&
  !normalized.has_prefix("/") &&
  !normalized
  .split("/")
  .any(segment => segment == "" || segment == "." || segment == "..")
}

///|
fn resolve_ref(
  workspace_root : String,
  artifact_ref : String,
) -> Result[String, AdapterRuntimeIssue] {
  if !valid_relative_ref(artifact_ref) {
    return Err(
      issue(
        "unsafe-artifact-ref", artifact_ref, "MoonRobo adapter artifact references must be workspace-relative without traversal",
      ),
    )
  }
  Ok(trim_trailing_slash(workspace_root) + "/" + artifact_ref)
}

///|
fn ensure_dir(path : String) -> Result[Unit, AdapterRuntimeIssue] {
  if @fsx.path_exists(path) {
    return Ok(())
  }
  @fsx.create_dir(path) catch {
    _ =>
      return Err(
        issue(
          "create-directory", path, "failed to create MoonRobo adapter directory",
        ),
      )
  }
  Ok(())
}

///|
fn ensure_directory_tree(path : String) -> Result[Unit, AdapterRuntimeIssue] {
  let absolute = path.has_prefix("/")
  let mut current = if absolute { "" } else { "." }
  for component in path.split("/") {
    if component == "" || component == "." {
      continue
    }
    let owned = component.to_owned()
    current = if current == "" || current == "/" {
      "/" + owned
    } else {
      current + "/" + owned
    }
    match ensure_dir(current) {
      Ok(_) => ()
      Err(error) => return Err(error)
    }
  }
  Ok(())
}

///|
fn write_json(path : String, value : Json) -> Result[Unit, AdapterRuntimeIssue] {
  @fsx.write_string_to_file(path, value.stringify(indent=2) + "\n") catch {
    _ =>
      return Err(
        issue(
          "write-adapter-evidence", path, "failed to persist MoonRobo adapter evidence",
        ),
      )
  }
  Ok(())
}

///|
fn read_json(path : String) -> Result[Json, AdapterRuntimeIssue] {
  let text = @fsx.read_file_to_string(path) catch {
    _ =>
      return Err(
        issue(
          "read-adapter-evidence", path, "failed to read MoonRobo adapter evidence",
        ),
      )
  }
  Ok(
    @json.parse(text) catch {
      _ =>
        return Err(
          issue(
            "parse-adapter-evidence", path, "failed to parse MoonRobo adapter evidence",
          ),
        )
    },
  )
}

///|
fn[T : @json.FromJson] read_typed(
  path : String,
) -> Result[T, AdapterRuntimeIssue] {
  let value = match read_json(path) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  Ok(
    @json.from_json(value) catch {
      _ =>
        return Err(
          issue(
            "decode-adapter-evidence", path, "failed to decode MoonRobo adapter evidence",
          ),
        )
    },
  )
}

///|
fn attempt_root_ref(attempt_id : String) -> String {
  ".moonsuite/products/moonrobo/adapter-attempts/\{attempt_id}"
}

///|
fn request_ref(attempt_id : String) -> String {
  attempt_root_ref(attempt_id) + "/request.json"
}

///|
fn state_ref(attempt_id : String) -> String {
  attempt_root_ref(attempt_id) + "/attempt.json"
}

///|
fn operation_receipt_ref(attempt_id : String) -> String {
  attempt_root_ref(attempt_id) + "/operation-receipt.json"
}

///|
fn result_ref(attempt_id : String) -> String {
  attempt_root_ref(attempt_id) + "/adapter-result.json"
}

///|
fn reconciliation_ref(attempt_id : String) -> String {
  attempt_root_ref(attempt_id) + "/reconciliation.json"
}

///|
fn attempt_path(
  workspace_root : String,
  attempt_id : String,
) -> Result[String, AdapterRuntimeIssue] {
  resolve_ref(workspace_root, attempt_root_ref(attempt_id))
}

///|
fn evidence_path(
  workspace_root : String,
  evidence_ref : String,
) -> Result[String, AdapterRuntimeIssue] {
  resolve_ref(workspace_root, evidence_ref)
}

///|
fn ensure_attempt_dir(
  workspace_root : String,
  attempt_id : String,
) -> Result[String, AdapterRuntimeIssue] {
  let path = match attempt_path(workspace_root, attempt_id) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  match ensure_directory_tree(path) {
    Ok(_) => Ok(path)
    Err(error) => Err(error)
  }
}

///|
fn robobook_path(
  workspace_root : String,
  robobook_ref : String,
) -> Result[String, AdapterRuntimeIssue] {
  resolve_ref(workspace_root, robobook_ref)
}

///|
fn input_artifact(
  workspace_root : String,
  request : @suite_adapter.MoonflowAdapterRequest,
) -> Result[(String, String, String), AdapterRuntimeIssue] {
  guard request.input_artifacts is [artifact_ref, ..] else {
    return Err(
      issue(
        "missing-operation-input",
        request.operation,
        "operation requires one workspace-relative input artifact",
      ),
    )
  }
  let path = match resolve_ref(workspace_root, artifact_ref) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let text = @fsx.read_file_to_string(path) catch {
    _ =>
      return Err(
        issue(
          "read-operation-input", path, "failed to read MoonRobo adapter input artifact",
        ),
      )
  }
  Ok((artifact_ref, path, text))
}

///|
fn operation_failure_receipt(
  request : @suite_adapter.MoonflowAdapterRequest,
  contract : @suite_adapter.AdapterOperationContract,
  error : AdapterRuntimeIssue,
) -> @suite_adapter.AdapterOperationReceipt {
  {
    contract_id: contract.output_contracts[0],
    adapter_id: @suite_adapter.adapter_id(),
    operation_id: contract.operation_id,
    operation_version: contract.version,
    request_id: request.request_id,
    attempt_id: request.attempt_id,
    idempotency_key: request.idempotency_key,
    status: "failed",
    authority_class: contract.authority_class,
    physical_execution_performed: false,
    input_digest: request.input_digest,
    observed_input_digests: [],
    evidence_refs: [],
    output_contract: contract.output_contracts[0],
    output: { "issue": error },
    error_kind: error.code,
    message: error.message,
    recorded_at: request.created_at,
  }
}

///|
fn integration_receipt(
  workspace_root : String,
  robobook_ref : String,
  request : @suite_adapter.MoonflowAdapterRequest,
  contract : @suite_adapter.AdapterOperationContract,
) -> Result[@suite_adapter.AdapterOperationReceipt, AdapterRuntimeIssue] {
  let (artifact_ref, source_path, design_text) = match
    input_artifact(workspace_root, request) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let target_root = match robobook_path(workspace_root, robobook_ref) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let persisted_design_path = target_root + "/design/robot-design.json"
  if @fsx.path_exists(persisted_design_path) {
    let persisted = @fsx.read_file_to_string(persisted_design_path) catch {
      _ =>
        return Err(
          issue(
            "read-existing-design", persisted_design_path, "failed to inspect the existing RoboBook design",
          ),
        )
    }
    let incoming_json = @json.parse(design_text) catch {
      _ =>
        return Err(
          issue(
            "parse-design", source_path, "failed to parse the robot design input",
          ),
        )
    }
    let persisted_json = @json.parse(persisted) catch {
      _ =>
        return Err(
          issue(
            "parse-existing-design", persisted_design_path, "failed to parse the existing RoboBook design",
          ),
        )
    }
    if incoming_json != persisted_json {
      return Err(
        issue(
          "robobook-target-conflict", robobook_ref, "target RoboBook already contains a different robot design",
        ),
      )
    }
  } else {
    match
      @design_builder.build_robobook(
        design_text,
        source_path,
        target_root,
        request.created_at,
        source_artifact_ref=artifact_ref,
      ) {
      Ok(_) => ()
      Err(error) => return Err(issue(error.code, error.field, error.message))
    }
  }
  let validation = match
    @design_builder.validate_robobook(target_root, request.created_at) {
    Ok(value) => value
    Err(error) => return Err(issue(error.code, error.field, error.message))
  }
  let build_ref = robobook_ref + "/design/build-receipt.json"
  let validation_ref = robobook_ref + "/design/validation-receipt.json"
  let model_ref = robobook_ref + "/model/robot.urdf"
  Ok({
    contract_id: contract.output_contracts[0],
    adapter_id: @suite_adapter.adapter_id(),
    operation_id: contract.operation_id,
    operation_version: contract.version,
    request_id: request.request_id,
    attempt_id: request.attempt_id,
    idempotency_key: request.idempotency_key,
    status: "succeeded",
    authority_class: contract.authority_class,
    physical_execution_performed: false,
    input_digest: request.input_digest,
    observed_input_digests: [@moondata_core.text_checksum(design_text)],
    evidence_refs: [build_ref, validation_ref, model_ref],
    output_contract: contract.output_contracts[0],
    output: {
      "accepted": true,
      "robobook_ref": robobook_ref,
      "build_receipt_ref": build_ref,
      "validation_receipt_ref": validation_ref,
      "model_ref": model_ref,
      "validation": validation,
      "claim_ceiling": "digital-artifact",
      "physical_ready": false,
    },
    error_kind: "",
    message: "MoonRobo integrated and independently validated the digital-only robot design.",
    recorded_at: request.created_at,
  })
}

///|
fn readiness_receipt(
  workspace_root : String,
  robobook_ref : String,
  request : @suite_adapter.MoonflowAdapterRequest,
  contract : @suite_adapter.AdapterOperationContract,
) -> Result[@suite_adapter.AdapterOperationReceipt, AdapterRuntimeIssue] {
  let (_, input_path, input_text) = match
    input_artifact(workspace_root, request) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let input_json = @json.parse(input_text) catch {
    _ =>
      return Err(
        issue(
          "parse-robobook-ref", input_path, "failed to parse moonrobo.robobook-ref.v1",
        ),
      )
  }
  let input : @suite_adapter.RoboBookRef = @json.from_json(input_json) catch {
    _ =>
      return Err(
        issue(
          "decode-robobook-ref", input_path, "failed to decode moonrobo.robobook-ref.v1",
        ),
      )
  }
  if input.contract_id != "moonrobo.robobook-ref.v1" ||
    input.robobook_ref != robobook_ref {
    return Err(
      issue(
        "robobook-ref-mismatch", input_path, "typed RoboBook reference must match the host-selected target",
      ),
    )
  }
  let root = match robobook_path(workspace_root, robobook_ref) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let response = @host_api.platform_readiness_response(root)
  let output = @json.parse(response.body) catch {
    _ =>
      return Err(
        issue(
          "parse-readiness-response", robobook_ref, "MoonRobo readiness returned invalid JSON",
        ),
      )
  }
  if response.status < 200 || response.status >= 300 {
    return Err(
      issue(
        "readiness-unavailable",
        robobook_ref,
        "MoonRobo readiness inspection failed with HTTP \{response.status}",
      ),
    )
  }
  Ok({
    contract_id: contract.output_contracts[0],
    adapter_id: @suite_adapter.adapter_id(),
    operation_id: contract.operation_id,
    operation_version: contract.version,
    request_id: request.request_id,
    attempt_id: request.attempt_id,
    idempotency_key: request.idempotency_key,
    status: "succeeded",
    authority_class: contract.authority_class,
    physical_execution_performed: false,
    input_digest: request.input_digest,
    observed_input_digests: [@moondata_core.text_checksum(input_text)],
    evidence_refs: [],
    output_contract: contract.output_contracts[0],
    output,
    error_kind: "",
    message: "MoonRobo recorded a point-in-time readiness observation; blocked readiness is still a successful observation.",
    recorded_at: request.created_at,
  })
}

///|
fn decode_governed_goal(
  text : String,
  path : String,
) -> Result[@suite_adapter.GovernedCommandGoal, AdapterRuntimeIssue] {
  let json = @json.parse(text) catch {
    _ =>
      return Err(
        issue(
          "parse-command-goal", path, "failed to parse governed robot command goal",
        ),
      )
  }
  let goal : @suite_adapter.GovernedCommandGoal = @json.from_json(json) catch {
    _ =>
      return Err(
        issue(
          "decode-command-goal", path, "failed to decode moonrobo.robot-command-goal.v1",
        ),
      )
  }
  if goal.contract_id != "moonrobo.robot-command-goal.v1" {
    return Err(
      issue(
        "unsupported-command-contract", path, "expected moonrobo.robot-command-goal.v1",
      ),
    )
  }
  if goal.goal.trim().is_empty() {
    return Err(
      issue(
        "empty-command-goal", path, "governed robot command goal must be concrete",
      ),
    )
  }
  if goal.requested_by.id.trim().is_empty() ||
    goal.requested_by.kind.trim().is_empty() {
    return Err(
      issue(
        "invalid-command-requester", path, "governed robot command requires a named requester",
      ),
    )
  }
  Ok(goal)
}

///|
fn command_receipt(
  workspace_root : String,
  robobook_ref : String,
  request : @suite_adapter.MoonflowAdapterRequest,
  contract : @suite_adapter.AdapterOperationContract,
) -> Result[@suite_adapter.AdapterOperationReceipt, AdapterRuntimeIssue] {
  let (artifact_ref, artifact_path, text) = match
    input_artifact(workspace_root, request) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let goal = match decode_governed_goal(text, artifact_path) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let root = match robobook_path(workspace_root, robobook_ref) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let command_id = "moonflow-\{request.attempt_id}"
  let body : Json = {
    "command_id": command_id,
    "robot_id": goal.robot_id,
    "requested_by": goal.requested_by,
    "goal": goal.goal,
    "now_ms": goal.now_ms,
    "remember": goal.remember,
  }
  let response = @host_api.route_with_body(
    root,
    "POST",
    @host_api.moonrobo_gateway_command_path(),
    body.stringify(),
  )
  let response_json = @json.parse(response.body) catch {
    _ =>
      return Err(
        issue(
          "parse-command-response",
          @host_api.moonrobo_gateway_command_path(),
          "MoonRobo command ingress returned invalid JSON",
        ),
      )
  }
  let command_ref = ".moonsuite/products/moonrobo/gateway-commands/\{command_id}.json"
  let accepted = response.status >= 200 && response.status < 300
  Ok({
    contract_id: contract.output_contracts[0],
    adapter_id: @suite_adapter.adapter_id(),
    operation_id: contract.operation_id,
    operation_version: contract.version,
    request_id: request.request_id,
    attempt_id: request.attempt_id,
    idempotency_key: request.idempotency_key,
    status: if accepted {
      "succeeded"
    } else {
      "failed"
    },
    authority_class: contract.authority_class,
    physical_execution_performed: false,
    input_digest: request.input_digest,
    observed_input_digests: [@moondata_core.text_checksum(text)],
    evidence_refs: [artifact_ref, command_ref],
    output_contract: contract.output_contracts[0],
    output: {
      "accepted": accepted,
      "http_status": response.status,
      "command_ref": command_ref,
      "ingress": response_json,
      "physical_execution_performed": false,
      "next_boundary": "MoonRobo safety/review/readiness gates",
    },
    error_kind: if accepted {
      ""
    } else {
      "command-ingress-blocked"
    },
    message: if accepted {
      "MoonRobo accepted the generic-runtime command as durable governed work; no physical execution occurred."
    } else {
      "MoonRobo refused or blocked the governed command before physical execution."
    },
    recorded_at: request.created_at,
  })
}

///|
fn execute_operation(
  workspace_root : String,
  robobook_ref : String,
  request : @suite_adapter.MoonflowAdapterRequest,
  contract : @suite_adapter.AdapterOperationContract,
) -> Result[@suite_adapter.AdapterOperationReceipt, AdapterRuntimeIssue] {
  match request.operation {
    "robot.integrate-digital-model" =>
      integration_receipt(workspace_root, robobook_ref, request, contract)
    "robot.readiness.inspect" =>
      readiness_receipt(workspace_root, robobook_ref, request, contract)
    "robot.command.submit-governed" =>
      command_receipt(workspace_root, robobook_ref, request, contract)
    operation =>
      Err(
        issue(
          "unsupported-operation", operation, "MoonRobo adapter does not expose this operation",
        ),
      )
  }
}

///|
fn adapter_result_from_receipt(
  request : @suite_adapter.MoonflowAdapterRequest,
  receipt : @suite_adapter.AdapterOperationReceipt,
) -> @suite_adapter.MoonflowAdapterResult {
  let receipt_ref = operation_receipt_ref(request.attempt_id)
  let artifacts = receipt.evidence_refs.copy()
  if !artifacts.contains(receipt_ref) {
    artifacts.push(receipt_ref)
  }
  {
    result_id: "moonrobo-result-\{request.attempt_id}-\{receipt.status}",
    request_id: request.request_id,
    attempt_id: request.attempt_id,
    idempotency_key: request.idempotency_key,
    product_id: "moonrobo",
    external_job_id: "moonrobo-local-\{request.attempt_id}",
    status: receipt.status,
    output_digest: if receipt.status == "succeeded" {
      @moondata_core.text_checksum(receipt.to_json().stringify())
    } else {
      ""
    },
    output_artifacts: artifacts,
    error_kind: receipt.error_kind,
    compensable: false,
    recorded_at: receipt.recorded_at,
  }
}

///|
fn running_record(
  request : @suite_adapter.MoonflowAdapterRequest,
) -> @suite_adapter.AdapterAttemptRecord {
  {
    contract_id: "moonrobo.adapter-attempt.v1",
    adapter_id: @suite_adapter.adapter_id(),
    request_id: request.request_id,
    attempt_id: request.attempt_id,
    idempotency_key: request.idempotency_key,
    operation: request.operation,
    status: "running",
    request_ref: request_ref(request.attempt_id),
    operation_receipt_ref: operation_receipt_ref(request.attempt_id),
    adapter_result_ref: result_ref(request.attempt_id),
    started_at: request.created_at,
    updated_at: request.created_at,
  }
}

///|
fn persist_terminal(
  workspace_root : String,
  request : @suite_adapter.MoonflowAdapterRequest,
  receipt : @suite_adapter.AdapterOperationReceipt,
) -> Result[@suite_adapter.MoonflowAdapterResult, AdapterRuntimeIssue] {
  match ensure_attempt_dir(workspace_root, request.attempt_id) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  let receipt_path = match
    evidence_path(workspace_root, operation_receipt_ref(request.attempt_id)) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  match write_json(receipt_path, receipt.to_json()) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  let result = adapter_result_from_receipt(request, receipt)
  let result_path = match
    evidence_path(workspace_root, result_ref(request.attempt_id)) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  match write_json(result_path, result.to_json()) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  let state = {
    ..running_record(request),
    status: result.status,
    updated_at: result.recorded_at,
  }
  let state_path = match
    evidence_path(workspace_root, state_ref(request.attempt_id)) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  match write_json(state_path, state.to_json()) {
    Ok(_) => Ok(result)
    Err(error) => Err(error)
  }
}

///|
fn existing_result(
  workspace_root : String,
  request : @suite_adapter.MoonflowAdapterRequest,
) -> Result[@suite_adapter.MoonflowAdapterResult?, AdapterRuntimeIssue] {
  let path = match
    evidence_path(workspace_root, result_ref(request.attempt_id)) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if !@fsx.path_exists(path) {
    return Ok(None)
  }
  let result : @suite_adapter.MoonflowAdapterResult = match read_typed(path) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if !@suite_adapter.same_attempt_identity(request, result) {
    return Err(
      issue(
        "attempt-identity-conflict", path, "persisted adapter result does not match request, attempt, and idempotency identity",
      ),
    )
  }
  Ok(Some(result))
}

///|
pub fn invoke(
  workspace_root : String,
  robobook_ref : String,
  request : @suite_adapter.MoonflowAdapterRequest,
) -> Result[@suite_adapter.MoonflowAdapterResult, AdapterRuntimeIssue] {
  let issues = request.quality_issues()
  if !issues.is_empty() {
    return Err(
      issue("invalid-adapter-request", request.operation, issues.join("; ")),
    )
  }
  if !valid_relative_ref(robobook_ref) {
    return Err(
      issue(
        "unsafe-robobook-ref", robobook_ref, "RoboBook reference must be workspace-relative without traversal",
      ),
    )
  }
  match existing_result(workspace_root, request) {
    Ok(Some(result)) => return Ok(result)
    Ok(None) => ()
    Err(error) => return Err(error)
  }
  let state_path = match
    evidence_path(workspace_root, state_ref(request.attempt_id)) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if @fsx.path_exists(state_path) {
    return Err(
      issue(
        "attempt-outcome-unknown", state_path, "adapter attempt already started without a terminal result; reconcile before any retry",
      ),
    )
  }
  match ensure_attempt_dir(workspace_root, request.attempt_id) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  let request_path = match
    evidence_path(workspace_root, request_ref(request.attempt_id)) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  match write_json(request_path, request.to_json()) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  match write_json(state_path, running_record(request).to_json()) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  let contract = match
    @suite_adapter.find_operation_contract(request.operation) {
    Some(value) => value
    None =>
      return Err(
        issue(
          "unsupported-operation",
          request.operation,
          "MoonRobo adapter operation is not declared",
        ),
      )
  }
  let receipt = match
    execute_operation(workspace_root, robobook_ref, request, contract) {
    Ok(value) => value
    Err(error) => operation_failure_receipt(request, contract, error)
  }
  persist_terminal(workspace_root, request, receipt)
}

///|
fn unknown_result(
  request : @suite_adapter.MoonflowAdapterRequest,
) -> @suite_adapter.MoonflowAdapterResult {
  {
    result_id: "moonrobo-result-\{request.attempt_id}-unknown",
    request_id: request.request_id,
    attempt_id: request.attempt_id,
    idempotency_key: request.idempotency_key,
    product_id: "moonrobo",
    external_job_id: "moonrobo-local-\{request.attempt_id}",
    status: "unknown",
    output_digest: "",
    output_artifacts: [],
    error_kind: "unknown-outcome",
    compensable: false,
    recorded_at: request.created_at,
  }
}

///|
fn reconciliation_report(
  request : @suite_adapter.MoonflowAdapterRequest,
  decision : String,
  retry_allowed : Bool,
  evidence_refs : Array[String],
  result : @suite_adapter.MoonflowAdapterResult,
  message : String,
) -> @suite_adapter.AdapterReconciliationReport {
  {
    contract_id: "moonrobo.adapter-reconciliation.v1",
    adapter_id: @suite_adapter.adapter_id(),
    request_id: request.request_id,
    attempt_id: request.attempt_id,
    decision,
    retry_allowed,
    evidence_refs,
    result,
    message,
    recorded_at: request.created_at,
  }
}

///|
fn persist_reconciliation(
  workspace_root : String,
  request : @suite_adapter.MoonflowAdapterRequest,
  report : @suite_adapter.AdapterReconciliationReport,
) -> Result[@suite_adapter.AdapterReconciliationReport, AdapterRuntimeIssue] {
  match ensure_attempt_dir(workspace_root, request.attempt_id) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  let path = match
    evidence_path(workspace_root, reconciliation_ref(request.attempt_id)) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  match write_json(path, report.to_json()) {
    Ok(_) => Ok(report)
    Err(error) => Err(error)
  }
}

///|
fn receipt_from_persisted_operation(
  workspace_root : String,
  request : @suite_adapter.MoonflowAdapterRequest,
) -> Result[@suite_adapter.AdapterOperationReceipt?, AdapterRuntimeIssue] {
  let path = match
    evidence_path(workspace_root, operation_receipt_ref(request.attempt_id)) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if !@fsx.path_exists(path) {
    return Ok(None)
  }
  let receipt : @suite_adapter.AdapterOperationReceipt = match
    read_typed(path) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if receipt.request_id != request.request_id ||
    receipt.attempt_id != request.attempt_id ||
    receipt.idempotency_key != request.idempotency_key {
    return Err(
      issue(
        "operation-receipt-identity-conflict", path, "persisted operation receipt does not match the MoonFlow attempt identity",
      ),
    )
  }
  Ok(Some(receipt))
}

///|
fn reconcile_integration(
  workspace_root : String,
  robobook_ref : String,
  request : @suite_adapter.MoonflowAdapterRequest,
  contract : @suite_adapter.AdapterOperationContract,
) -> Result[@suite_adapter.AdapterOperationReceipt?, AdapterRuntimeIssue] {
  let root = match robobook_path(workspace_root, robobook_ref) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let build_path = root + "/design/build-receipt.json"
  if !@fsx.path_exists(build_path) {
    return Ok(None)
  }
  let (artifact_ref, source_path, incoming) = match
    input_artifact(workspace_root, request) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let persisted_path = root + "/design/robot-design.json"
  if !@fsx.path_exists(persisted_path) {
    return Ok(None)
  }
  let persisted = @fsx.read_file_to_string(persisted_path) catch {
    _ =>
      return Err(
        issue(
          "read-existing-design", persisted_path, "failed to inspect the partially integrated design",
        ),
      )
  }
  let incoming_json = @json.parse(incoming) catch {
    _ =>
      return Err(
        issue("parse-design", source_path, "failed to parse robot design"),
      )
  }
  let persisted_json = @json.parse(persisted) catch {
    _ =>
      return Err(
        issue(
          "parse-existing-design", persisted_path, "failed to parse persisted robot design",
        ),
      )
  }
  if incoming_json != persisted_json {
    return Err(
      issue(
        "reconciliation-identity-conflict", persisted_path, "persisted robot design does not match the attempt input",
      ),
    )
  }
  let validation = match
    @design_builder.validate_robobook(root, request.created_at) {
    Ok(value) => value
    Err(error) => return Err(issue(error.code, error.field, error.message))
  }
  let build_ref = robobook_ref + "/design/build-receipt.json"
  let validation_ref = robobook_ref + "/design/validation-receipt.json"
  let model_ref = robobook_ref + "/model/robot.urdf"
  Ok(
    Some({
      contract_id: contract.output_contracts[0],
      adapter_id: @suite_adapter.adapter_id(),
      operation_id: contract.operation_id,
      operation_version: contract.version,
      request_id: request.request_id,
      attempt_id: request.attempt_id,
      idempotency_key: request.idempotency_key,
      status: "succeeded",
      authority_class: contract.authority_class,
      physical_execution_performed: false,
      input_digest: request.input_digest,
      observed_input_digests: [@moondata_core.text_checksum(incoming)],
      evidence_refs: [artifact_ref, build_ref, validation_ref, model_ref],
      output_contract: contract.output_contracts[0],
      output: {
        "accepted": true,
        "recovered_by_reconciliation": true,
        "robobook_ref": robobook_ref,
        "validation": validation,
        "physical_ready": false,
      },
      error_kind: "",
      message: "Reconciliation proved that the exact digital design was integrated and validated.",
      recorded_at: request.created_at,
    }),
  )
}

///|
fn command_accepted(value : Json) -> Bool? {
  match value {
    { "command": Object(command), .. } =>
      match command.get("accepted") {
        Some(True) => Some(true)
        Some(False) => Some(false)
        _ => None
      }
    _ => None
  }
}

///|
fn reconcile_command(
  workspace_root : String,
  robobook_ref : String,
  request : @suite_adapter.MoonflowAdapterRequest,
  contract : @suite_adapter.AdapterOperationContract,
) -> Result[@suite_adapter.AdapterOperationReceipt?, AdapterRuntimeIssue] {
  let command_ref = ".moonsuite/products/moonrobo/gateway-commands/moonflow-\{request.attempt_id}.json"
  let command_path = match resolve_ref(workspace_root, command_ref) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if !@fsx.path_exists(command_path) {
    return Ok(None)
  }
  let command = match read_json(command_path) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let accepted = match command_accepted(command) {
    Some(value) => value
    None =>
      return Err(
        issue(
          "decode-command-evidence", command_path, "gateway command evidence does not contain an accepted decision",
        ),
      )
  }
  Ok(
    Some({
      contract_id: contract.output_contracts[0],
      adapter_id: @suite_adapter.adapter_id(),
      operation_id: contract.operation_id,
      operation_version: contract.version,
      request_id: request.request_id,
      attempt_id: request.attempt_id,
      idempotency_key: request.idempotency_key,
      status: if accepted {
        "succeeded"
      } else {
        "failed"
      },
      authority_class: contract.authority_class,
      physical_execution_performed: false,
      input_digest: request.input_digest,
      observed_input_digests: [],
      evidence_refs: [command_ref],
      output_contract: contract.output_contracts[0],
      output: {
        "accepted": accepted,
        "recovered_by_reconciliation": true,
        "command_ref": command_ref,
        "ingress": command,
        "physical_execution_performed": false,
      },
      error_kind: if accepted {
        ""
      } else {
        "command-ingress-blocked"
      },
      message: "Reconciliation recovered the durable MoonRobo gateway-command decision.",
      recorded_at: request.created_at,
    }),
  )
}

///|
fn partial_integration_exists(
  workspace_root : String,
  robobook_ref : String,
) -> Result[Bool, AdapterRuntimeIssue] {
  let root = match robobook_path(workspace_root, robobook_ref) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  Ok(
    @fsx.path_exists(root + "/robot.json") ||
    @fsx.path_exists(root + "/design/robot-design.json") ||
    @fsx.path_exists(root + "/model/robot.urdf"),
  )
}

///|
pub fn reconcile(
  workspace_root : String,
  robobook_ref : String,
  request : @suite_adapter.MoonflowAdapterRequest,
) -> Result[@suite_adapter.AdapterReconciliationReport, AdapterRuntimeIssue] {
  let issues = request.quality_issues()
  if !issues.is_empty() {
    return Err(
      issue("invalid-adapter-request", request.operation, issues.join("; ")),
    )
  }
  match existing_result(workspace_root, request) {
    Ok(Some(result)) if result.status != "unknown" =>
      return persist_reconciliation(
        workspace_root,
        request,
        reconciliation_report(
          request,
          "terminal-recorded",
          false,
          result.output_artifacts,
          result,
          "The exact adapter attempt already has a terminal MoonFlow result.",
        ),
      )
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  match receipt_from_persisted_operation(workspace_root, request) {
    Ok(Some(receipt)) => {
      let result = match persist_terminal(workspace_root, request, receipt) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      return persist_reconciliation(
        workspace_root,
        request,
        reconciliation_report(
          request,
          if result.status == "succeeded" {
            "recovered-succeeded"
          } else {
            "recovered-failed"
          },
          false,
          result.output_artifacts,
          result,
          "Reconciliation recovered a terminal result from the immutable operation receipt.",
        ),
      )
    }
    Ok(None) => ()
    Err(error) => return Err(error)
  }
  let contract = match
    @suite_adapter.find_operation_contract(request.operation) {
    Some(value) => value
    None =>
      return Err(
        issue(
          "unsupported-operation",
          request.operation,
          "MoonRobo adapter operation is not declared",
        ),
      )
  }
  let recovered = match request.operation {
    "robot.integrate-digital-model" =>
      reconcile_integration(workspace_root, robobook_ref, request, contract)
    "robot.command.submit-governed" =>
      reconcile_command(workspace_root, robobook_ref, request, contract)
    "robot.readiness.inspect" => Ok(None)
    _ => Ok(None)
  }
  match recovered {
    Err(error) => return Err(error)
    Ok(Some(receipt)) => {
      let result = match persist_terminal(workspace_root, request, receipt) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      return persist_reconciliation(
        workspace_root,
        request,
        reconciliation_report(
          request,
          if result.status == "succeeded" {
            "recovered-succeeded"
          } else {
            "recovered-failed"
          },
          false,
          result.output_artifacts,
          result,
          "Reconciliation recovered the operation from product-owned durable evidence.",
        ),
      )
    }
    Ok(None) => ()
  }
  let partial = if request.operation == "robot.integrate-digital-model" {
    match partial_integration_exists(workspace_root, robobook_ref) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
  } else {
    false
  }
  if partial {
    match ensure_attempt_dir(workspace_root, request.attempt_id) {
      Ok(_) => ()
      Err(error) => return Err(error)
    }
    let result = unknown_result(request)
    let result_path = match
      evidence_path(workspace_root, result_ref(request.attempt_id)) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    match write_json(result_path, result.to_json()) {
      Ok(_) => ()
      Err(error) => return Err(error)
    }
    return persist_reconciliation(
      workspace_root,
      request,
      reconciliation_report(
        request,
        "unknown",
        false,
        [],
        result,
        "Partial digital-model artifacts exist without a matching receipt; preserve evidence and require operator investigation.",
      ),
    )
  }
  let not_applied = operation_failure_receipt(
    request,
    contract,
    issue(
      "reconciled-not-applied",
      request.operation,
      "no product-owned effect or receipt exists for this exact attempt",
    ),
  )
  let result = match persist_terminal(workspace_root, request, not_applied) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  persist_reconciliation(
    workspace_root,
    request,
    reconciliation_report(
      request,
      "not-applied",
      true,
      result.output_artifacts,
      result,
      "Reconciliation proved that this attempt was not applied; MoonFlow may create a new attempt under its retry policy.",
    ),
  )
}

///|
pub fn readiness(
  workspace_root : String,
  robobook_ref : String,
) -> @suite_adapter.AdapterReadiness {
  let root = match robobook_path(workspace_root, robobook_ref) {
    Ok(value) => value
    Err(_) => ""
  }
  let book = if root == "" {
    None
  } else {
    match @runtime.load_robobook(root) {
      Ok(value) => Some(value)
      Err(_) => None
    }
  }
  let robobook_ready = match book {
    Some(value) => value.status.ready
    None => false
  }
  let blockers = if robobook_ready {
    []
  } else {
    ["RoboBook profile and required paths are not ready"]
  }
  {
    contract_id: "moonrobo.adapter-readiness.v1",
    adapter_id: @suite_adapter.adapter_id(),
    healthy: valid_relative_ref(robobook_ref) &&
    !workspace_root.trim().is_empty(),
    robobook_root: robobook_ref,
    robobook_ready,
    physical_effects_exposed: false,
    operations: [
      {
        operation_id: "robot.integrate-digital-model",
        ready: valid_relative_ref(robobook_ref),
        status: if valid_relative_ref(robobook_ref) {
          "ready"
        } else {
          "blocked"
        },
        authority_class: "workspace-mutation",
        next_route: "moonrobo-adapter invoke",
        blockers: if valid_relative_ref(robobook_ref) {
          []
        } else {
          ["RoboBook reference is invalid"]
        },
      },
      {
        operation_id: "robot.readiness.inspect",
        ready: robobook_ready,
        status: if robobook_ready {
          "ready"
        } else {
          "blocked"
        },
        authority_class: "observe",
        next_route: "/api/moonrobo/readiness",
        blockers,
      },
      {
        operation_id: "robot.command.submit-governed",
        ready: robobook_ready,
        status: if robobook_ready {
          "ready"
        } else {
          "blocked"
        },
        authority_class: "workspace-mutation",
        next_route: @host_api.moonrobo_gateway_command_path(),
        blockers,
      },
    ],
    message: if robobook_ready {
      "MoonRobo adapter can inspect and submit governed work. Physical execution remains behind separate safety, review, readiness, and bridge gates."
    } else {
      "Digital-model integration is available; existing-RoboBook operations remain blocked until the target loads successfully."
    },
  }
}
