///|
/// Describe MoonRobo's digital build and validation boundary for MoonFlow.
/// The adapter deliberately does not claim physical-effect authority.
pub fn moonflow_adapter_capability_json() -> Json {
  {
    "adapter_id": "moonrobo-v1",
    "product_id": "moonrobo",
    "protocol": "moonflow.adapter.v1",
    "operations": [
      "ingest-design-revision", "build-digital-robot", "run-simulated-control-loop",
      "collect-telemetry", "validate-requirements", "record-failure-trace", "reconcile-validation",
    ],
    "authority_classes": ["observe", "sandbox-execution", "workspace-mutation"],
    "supports_cancel": false,
    "supports_reconcile": true,
    "receipt_contracts": [
      "moonrobo.build-receipt.v1", "moonrobo.run-receipt.v1", "moonrobo.validation-receipt.v1",
      "moonrobo.failure-trace.v1",
    ],
    "readiness_ceiling": "simulation_ready",
    "physical_ready_forbidden": true,
    "mission_acceptance_forbidden": true,
  }
}
