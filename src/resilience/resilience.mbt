///|
pub(all) struct RecoveryCapability {
  capability_id : String
  subsystem : String
  max_severity : Int
  energy_cost_wh : Double
  duration_s : Int
  max_attempts : Int
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct FaultScenario {
  fault_id : String
  subsystem : String
  severity : Int
  onset_s : Int
  duration_s : Int
  observable : Bool
  recoverable : Bool
  recovery_energy_budget_wh : Double
  recovery_time_budget_s : Int
  requested_mission : String
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct RobotResiliencePlan {
  contract_id : String
  robot_id : String
  redundancies : Array[String]
  degradation_limits : Array[String]
  safe_modes : Array[String]
  recovery_capabilities : Array[RecoveryCapability]
  hardware_assumptions : Array[String]
  scenarios : Array[FaultScenario]
  recorded_at : String
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct RecoveryScenarioResult {
  fault_id : String
  states : Array[String]
  outcome : String
  recovery_capability_id : String
  attempts : Int
  evidence : Array[String]
  remaining_limitations : Array[String]
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct RobotResilienceQualification {
  contract_id : String
  robot_id : String
  accepted : Bool
  claim : String
  physical_readiness : Bool
  recovered_count : Int
  reduced_mission_count : Int
  safe_return_count : Int
  fail_closed_count : Int
  scenarios : Array[RecoveryScenarioResult]
  hardware_assumptions : Array[String]
  limitations : Array[String]
  recorded_at : String
} derive(Debug, Eq, ToJson, FromJson)

///|
fn recovery_for(
  plan : RobotResiliencePlan,
  fault : FaultScenario,
) -> RecoveryCapability? {
  for capability in plan.recovery_capabilities {
    if capability.subsystem == fault.subsystem &&
      fault.severity <= capability.max_severity &&
      capability.energy_cost_wh <= fault.recovery_energy_budget_wh &&
      capability.duration_s <= fault.recovery_time_budget_s &&
      capability.max_attempts > 0 {
      return Some(capability)
    }
  }
  None
}

///|
fn evaluate_scenario(
  plan : RobotResiliencePlan,
  fault : FaultScenario,
) -> RecoveryScenarioResult {
  let states : Array[String] = ["normal", "degraded"]
  let evidence : Array[String] = [
    "fault severity=\{fault.severity}",
    "fault onset_s=\{fault.onset_s}",
    "fault duration_s=\{fault.duration_s}",
    "recovery energy budget=\{fault.recovery_energy_budget_wh}",
    "recovery time budget=\{fault.recovery_time_budget_s}",
  ]
  let limitations : Array[String] = []
  if !fault.observable {
    limitations.push("fault is not observable with declared sensors")
    if !plan.safe_modes.is_empty() {
      states.push("safe-return")
      return {
        fault_id: fault.fault_id,
        states,
        outcome: "safe-return",
        recovery_capability_id: "",
        attempts: 0,
        evidence,
        remaining_limitations: limitations,
      }
    }
    states.push("fail-closed")
    return {
      fault_id: fault.fault_id,
      states,
      outcome: "fail-closed",
      recovery_capability_id: "",
      attempts: 0,
      evidence,
      remaining_limitations: limitations,
    }
  }
  states.push("diagnosis")
  match recovery_for(plan, fault) {
    Some(capability) if fault.recoverable => {
      states.push("recovery-attempt")
      if fault.severity * 2 <= capability.max_severity {
        states.push("recovered")
        {
          fault_id: fault.fault_id,
          states,
          outcome: "recovered",
          recovery_capability_id: capability.capability_id,
          attempts: 1,
          evidence,
          remaining_limitations: limitations,
        }
      } else {
        states.push("reduced-mission")
        limitations.push(
          "fault severity consumes enough margin to require reduced mission",
        )
        {
          fault_id: fault.fault_id,
          states,
          outcome: "reduced-mission",
          recovery_capability_id: capability.capability_id,
          attempts: 1,
          evidence,
          remaining_limitations: limitations,
        }
      }
    }
    _ => {
      limitations.push(
        "fault exceeds recovery capability or declared recovery budget",
      )
      if !plan.safe_modes.is_empty() {
        states.push("safe-return")
        {
          fault_id: fault.fault_id,
          states,
          outcome: "safe-return",
          recovery_capability_id: "",
          attempts: 0,
          evidence,
          remaining_limitations: limitations,
        }
      } else {
        states.push("fail-closed")
        {
          fault_id: fault.fault_id,
          states,
          outcome: "fail-closed",
          recovery_capability_id: "",
          attempts: 0,
          evidence,
          remaining_limitations: limitations,
        }
      }
    }
  }
}

///|
pub fn qualify_resilience_plan(
  plan : RobotResiliencePlan,
) -> Result[RobotResilienceQualification, String] {
  if plan.contract_id != "moonrobo.resilience-plan.v1" {
    return Err("unsupported MoonRobo resilience plan contract")
  }
  if plan.robot_id.trim().is_empty() || plan.recorded_at.trim().is_empty() {
    return Err("robot and record identity are required")
  }
  if plan.redundancies.is_empty() ||
    plan.degradation_limits.is_empty() ||
    plan.safe_modes.is_empty() ||
    plan.recovery_capabilities.is_empty() ||
    plan.hardware_assumptions.is_empty() ||
    plan.scenarios.is_empty() {
    return Err(
      "resilience plan requires redundancy, limits, safe modes, recovery, hardware assumptions, and scenarios",
    )
  }
  for fault in plan.scenarios {
    if fault.severity < 1 ||
      fault.severity > 10 ||
      fault.duration_s < 0 ||
      fault.recovery_energy_budget_wh < 0.0 ||
      fault.recovery_time_budget_s < 0 {
      return Err("fault severity and budgets are invalid: \{fault.fault_id}")
    }
  }
  let results = plan.scenarios.map(fault => evaluate_scenario(plan, fault))
  let recovered = results
    .filter(result => result.outcome == "recovered")
    .length()
  let reduced = results
    .filter(result => result.outcome == "reduced-mission")
    .length()
  let safe = results.filter(result => result.outcome == "safe-return").length()
  let failed = results
    .filter(result => result.outcome == "fail-closed")
    .length()
  let accepted = recovered + reduced > 0 && safe + failed > 0
  Ok({
    contract_id: "moonrobo.resilience-qualification.v1",
    robot_id: plan.robot_id,
    accepted,
    claim: if accepted {
      "simulation-ready"
    } else {
      "structure-valid"
    },
    physical_readiness: false,
    recovered_count: recovered,
    reduced_mission_count: reduced,
    safe_return_count: safe,
    fail_closed_count: failed,
    scenarios: results,
    hardware_assumptions: plan.hardware_assumptions,
    limitations: [
      "Recovery results are deterministic design evidence, not calibrated simulation.",
      "Hardware assumptions require independent testbed and engineering qualification.",
      "No physical deployment authority is granted.",
    ],
    recorded_at: plan.recorded_at,
  })
}
