///|
pub fn adapter_id() -> String {
  "moonrobo-local-v1"
}

///|
pub fn adapter_protocol() -> String {
  "moonflow.adapter.v2"
}

///|
pub fn pack_version() -> String {
  "0.2.0"
}

///|
pub fn operation_contracts() -> Array[AdapterOperationContract] {
  [
    {
      operation_id: "robot.integrate-digital-model",
      version: "1.0.0",
      authority_class: "workspace-mutation",
      input_contracts: ["moonsuite.robot-design.v1"],
      output_contracts: ["moonrobo.digital-model-integration-receipt.v1"],
      claim_ceiling: "digital-artifact",
      idempotent: true,
      review_required: true,
      physical_execution_allowed: false,
      evidence_outputs: [
        "design/build-receipt.json", "design/validation-receipt.json", ".moonsuite/products/moonrobo/adapter-attempts",
      ],
    },
    {
      operation_id: "robot.readiness.inspect",
      version: "1.0.0",
      authority_class: "observe",
      input_contracts: ["moonrobo.robobook-ref.v1"],
      output_contracts: ["moonrobo.readiness-observation.v1"],
      claim_ceiling: "observation",
      idempotent: true,
      review_required: false,
      physical_execution_allowed: false,
      evidence_outputs: [".moonsuite/products/moonrobo/adapter-attempts"],
    },
    {
      operation_id: "robot.command.submit-governed",
      version: "1.0.0",
      authority_class: "workspace-mutation",
      input_contracts: ["moonrobo.robot-command-goal.v1"],
      output_contracts: ["moonrobo.governed-command-submission.v1"],
      claim_ceiling: "execution-result",
      idempotent: true,
      review_required: false,
      physical_execution_allowed: false,
      evidence_outputs: [
        ".moonsuite/products/moonrobo/gateway-commands", ".moonsuite/products/moonrobo/adapter-attempts",
      ],
    },
  ]
}

///|
pub fn find_operation_contract(
  operation_id : String,
) -> AdapterOperationContract? {
  for contract in operation_contracts() {
    if contract.operation_id == operation_id {
      return Some(contract)
    }
  }
  None
}

///|
fn unique_strings(values : Array[String]) -> Array[String] {
  let output : Array[String] = []
  for value in values {
    if !output.contains(value) {
      output.push(value)
    }
  }
  output
}

///|
fn capability_authorities() -> Array[String] {
  unique_strings(
    operation_contracts().map(contract => contract.authority_class),
  )
}

///|
fn capability_input_contracts() -> Array[String] {
  let values : Array[String] = []
  for contract in operation_contracts() {
    values.append(contract.input_contracts)
  }
  unique_strings(values)
}

///|
fn capability_output_contracts() -> Array[String] {
  let values : Array[String] = ["moonflow.adapter-result.v1"]
  for contract in operation_contracts() {
    values.append(contract.output_contracts)
  }
  unique_strings(values)
}

///|
/// Describe the MoonRobo-owned adapter in MoonFlow's exact capability wire
/// contract. The capability deliberately excludes `physical-effect`: generic
/// runtimes may submit governed work, but only MoonRobo's reviewed safety lane
/// can eventually dispatch a bridge command.
pub fn moonflow_adapter_capability_json_with_health(healthy : Bool) -> Json {
  {
    "adapter_id": adapter_id(),
    "product_id": "moonrobo",
    "protocol": adapter_protocol(),
    "operations": operation_contracts().map(contract => contract.operation_id),
    "authority_classes": capability_authorities(),
    "input_contracts": capability_input_contracts(),
    "output_contracts": capability_output_contracts(),
    "claim_ceiling": "digital-artifact",
    "healthy": healthy,
    "supports_cancel": false,
    "supports_reconcile": true,
  }
}

///|
pub fn moonflow_adapter_capability_json() -> Json {
  moonflow_adapter_capability_json_with_health(true)
}

///|
pub fn operation_refs() -> Array[String] {
  operation_contracts().map(contract => {
    "moonrobo/\{contract.operation_id}@\{pack_version()}"
  })
}

///|
pub fn adapter_declaration_json() -> Json {
  {
    "contract_id": "moonflow.adapter-declaration.v1",
    "adapter_id": adapter_id(),
    "product_id": "moonrobo",
    "pack_id": "moonrobo",
    "pack_version": pack_version(),
    "protocol": adapter_protocol(),
    "operations": operation_contracts().map(contract => {
      let operation : Json = {
        "operation_id": contract.operation_id,
        "claim_ceiling": contract.claim_ceiling,
        "supports_cancel": false,
        "supports_reconcile": true,
      }
      operation
    }),
  }
}
