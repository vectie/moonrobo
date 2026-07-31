///|
pub(all) struct AdapterOperationContract {
  operation_id : String
  version : String
  authority_class : String
  input_contracts : Array[String]
  output_contracts : Array[String]
  claim_ceiling : String
  idempotent : Bool
  review_required : Bool
  physical_execution_allowed : Bool
  evidence_outputs : Array[String]
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct MoonflowAdapterRequest {
  request_id : String
  run_id : String
  book_id : String
  work_item_id : String
  declaration_id : String
  attempt_id : String
  idempotency_key : String
  product_id : String
  operation : String
  requested_authority : String
  acceptance_criteria : Array[String]
  input_contracts : Array[String]
  output_contracts : Array[String]
  required_claim : String
  input_digest : String
  input_artifacts : Array[String]
  timeout_ms : Int
  created_at : String
} derive(Debug, Eq, ToJson)

///|
pub(all) struct MoonflowAdapterResult {
  result_id : String
  request_id : String
  attempt_id : String
  idempotency_key : String
  product_id : String
  external_job_id : String
  status : String
  output_digest : String
  output_artifacts : Array[String]
  error_kind : String
  compensable : Bool
  recorded_at : String
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct AdapterAttemptRecord {
  contract_id : String
  adapter_id : String
  request_id : String
  attempt_id : String
  idempotency_key : String
  operation : String
  status : String
  request_ref : String
  operation_receipt_ref : String
  adapter_result_ref : String
  started_at : String
  updated_at : String
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct AdapterOperationReceipt {
  contract_id : String
  adapter_id : String
  operation_id : String
  operation_version : String
  request_id : String
  attempt_id : String
  idempotency_key : String
  status : String
  authority_class : String
  physical_execution_performed : Bool
  input_digest : String
  observed_input_digests : Array[String]
  evidence_refs : Array[String]
  output_contract : String
  output : Json
  error_kind : String
  message : String
  recorded_at : String
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct AdapterReconciliationReport {
  contract_id : String
  adapter_id : String
  request_id : String
  attempt_id : String
  decision : String
  retry_allowed : Bool
  evidence_refs : Array[String]
  result : MoonflowAdapterResult
  message : String
  recorded_at : String
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct AdapterOperationReadiness {
  operation_id : String
  ready : Bool
  status : String
  authority_class : String
  next_route : String
  blockers : Array[String]
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct AdapterReadiness {
  contract_id : String
  adapter_id : String
  healthy : Bool
  robobook_root : String
  robobook_ready : Bool
  physical_effects_exposed : Bool
  operations : Array[AdapterOperationReadiness]
  message : String
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct AdapterHealthAttestation {
  contract_id : String
  adapter_id : String
  product_id : String
  pack_id : String
  pack_version : String
  protocol : String
  status : String
  checked_at : String
  valid_until : String
  operation_refs : Array[String]
  evidence_ref : String
  evidence_digest : String
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct RoboBookRef {
  contract_id : String
  robobook_ref : String
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct GovernedCommandGoal {
  contract_id : String
  robot_id : String
  requested_by : @core.Requester
  goal : String
  now_ms : Int64
  remember : Bool
} derive(Debug, Eq, ToJson, FromJson)

///|
fn wire_object(value : Json, label : String) -> Map[String, Json] raise {
  match value {
    Object(fields) => fields
    _ => fail("\{label} must be a JSON object")
  }
}

///|
fn wire_string(
  fields : Map[String, Json],
  name : String,
  required? : Bool = true,
) -> String raise {
  match fields.get(name) {
    Some(String(value)) => value
    None if !required => ""
    _ => fail("\{name} must be a string")
  }
}

///|
fn wire_strings(
  fields : Map[String, Json],
  name : String,
) -> Array[String] raise {
  match fields.get(name) {
    None => []
    Some(Array(values)) =>
      values.map(value => {
        match value {
          String(text) => text
          _ => fail("\{name} must contain strings")
        }
      })
    _ => fail("\{name} must be an array")
  }
}

///|
fn wire_int(fields : Map[String, Json], name : String) -> Int raise {
  match fields.get(name) {
    Some(value) => @json.from_json(value)
    None => fail("\{name} is required")
  }
}

///|
pub fn decode_moonflow_adapter_request(
  value : Json,
) -> MoonflowAdapterRequest raise {
  let fields = wire_object(value, "MoonFlow adapter request")
  {
    request_id: wire_string(fields, "request_id"),
    run_id: wire_string(fields, "run_id"),
    book_id: wire_string(fields, "book_id"),
    work_item_id: wire_string(fields, "work_item_id"),
    declaration_id: wire_string(fields, "declaration_id"),
    attempt_id: wire_string(fields, "attempt_id"),
    idempotency_key: wire_string(fields, "idempotency_key"),
    product_id: wire_string(fields, "product_id"),
    operation: wire_string(fields, "operation"),
    requested_authority: wire_string(fields, "requested_authority"),
    acceptance_criteria: wire_strings(fields, "acceptance_criteria"),
    input_contracts: wire_strings(fields, "input_contracts"),
    output_contracts: wire_strings(fields, "output_contracts"),
    required_claim: wire_string(fields, "required_claim", required=false),
    input_digest: wire_string(fields, "input_digest"),
    input_artifacts: wire_strings(fields, "input_artifacts"),
    timeout_ms: wire_int(fields, "timeout_ms"),
    created_at: wire_string(fields, "created_at"),
  }
}

///|
fn add_required_issue(
  issues : Array[String],
  name : String,
  value : String,
) -> Unit {
  if value.trim().is_empty() {
    issues.push("\{name} is required")
  }
}

///|
fn safe_identity(value : String) -> Bool {
  !value.trim().is_empty() &&
  !value.contains("/") &&
  !value.contains("\\") &&
  value != "." &&
  value != ".."
}

///|
pub fn MoonflowAdapterRequest::quality_issues(
  self : MoonflowAdapterRequest,
) -> Array[String] {
  let issues : Array[String] = []
  add_required_issue(issues, "request_id", self.request_id)
  add_required_issue(issues, "run_id", self.run_id)
  add_required_issue(issues, "book_id", self.book_id)
  add_required_issue(issues, "work_item_id", self.work_item_id)
  add_required_issue(issues, "declaration_id", self.declaration_id)
  add_required_issue(issues, "attempt_id", self.attempt_id)
  add_required_issue(issues, "idempotency_key", self.idempotency_key)
  add_required_issue(issues, "operation", self.operation)
  add_required_issue(issues, "input_digest", self.input_digest)
  add_required_issue(issues, "created_at", self.created_at)
  if self.product_id != "moonrobo" {
    issues.push("product_id must be moonrobo")
  }
  if !safe_identity(self.attempt_id) {
    issues.push("attempt_id must be a safe path component")
  }
  if self.timeout_ms <= 0 {
    issues.push("timeout_ms must be positive")
  }
  match find_operation_contract(self.operation) {
    None => issues.push("operation is not exposed by the MoonRobo adapter")
    Some(contract) => {
      if self.requested_authority != contract.authority_class {
        issues.push("requested_authority does not match the operation contract")
      }
      for expected in contract.input_contracts {
        if !self.input_contracts.contains(expected) {
          issues.push("missing input contract: \{expected}")
        }
      }
      for expected in contract.output_contracts {
        if !self.output_contracts.contains(expected) {
          issues.push("missing output contract: \{expected}")
        }
      }
    }
  }
  issues
}

///|
pub fn valid_moonflow_adapter_request(request : MoonflowAdapterRequest) -> Bool {
  request.quality_issues().is_empty()
}

///|
pub fn same_attempt_identity(
  request : MoonflowAdapterRequest,
  result : MoonflowAdapterResult,
) -> Bool {
  request.request_id == result.request_id &&
  request.attempt_id == result.attempt_id &&
  request.idempotency_key == result.idempotency_key &&
  result.product_id == "moonrobo"
}
