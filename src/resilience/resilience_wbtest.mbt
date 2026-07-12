///|
fn resilience_plan() -> RobotResiliencePlan {
  {
    contract_id: "moonrobo.resilience-plan.v1",
    robot_id: "lunar-work-robot",
    redundancies: [
      "dual wheel-current sensing", "independent safe-return route",
    ],
    degradation_limits: [
      "traction severity <= 7", "power reserve >= 15 percent",
    ],
    safe_modes: ["stop excavation and return on verified safe route"],
    recovery_capabilities: [
      {
        capability_id: "traction-replan",
        subsystem: "traction",
        max_severity: 8,
        energy_cost_wh: 40.0,
        duration_s: 120,
        max_attempts: 2,
      },
    ],
    hardware_assumptions: [
      "wheel-current sensors retain accuracy within declared temperature range",
      "safe-return route remains locally observable",
    ],
    scenarios: [
      {
        fault_id: "traction-mild",
        subsystem: "traction",
        severity: 3,
        onset_s: 30,
        duration_s: 40,
        observable: true,
        recoverable: true,
        recovery_energy_budget_wh: 80.0,
        recovery_time_budget_s: 180,
        requested_mission: "full-haul",
      },
      {
        fault_id: "traction-major",
        subsystem: "traction",
        severity: 7,
        onset_s: 60,
        duration_s: 180,
        observable: true,
        recoverable: true,
        recovery_energy_budget_wh: 80.0,
        recovery_time_budget_s: 180,
        requested_mission: "full-haul",
      },
      {
        fault_id: "traction-extreme",
        subsystem: "traction",
        severity: 10,
        onset_s: 90,
        duration_s: 300,
        observable: true,
        recoverable: false,
        recovery_energy_budget_wh: 20.0,
        recovery_time_budget_s: 60,
        requested_mission: "full-haul",
      },
    ],
    recorded_at: "2026-07-12T17:00:00+08:00",
  }
}

///|
test "resilience qualification recovers, degrades, and returns safely" {
  let result = qualify_resilience_plan(resilience_plan())
  guard result is Ok(qualification) else { fail("expected qualification") }
  assert_true(qualification.accepted)
  assert_eq(qualification.recovered_count, 1)
  assert_eq(qualification.reduced_mission_count, 1)
  assert_eq(qualification.safe_return_count, 1)
  assert_false(qualification.physical_readiness)
  assert_eq(qualification.claim, "simulation-ready")
  assert_true(
    qualification.scenarios[1].states ==
    ["normal", "degraded", "diagnosis", "recovery-attempt", "reduced-mission"],
  )
}

///|
test "unobservable fault fails closed when no safe mode exists" {
  let plan = { ..resilience_plan(), safe_modes: [] }
  assert_true(qualify_resilience_plan(plan) is Err(_))
  let qualified = resilience_plan()
  qualified.scenarios[0] = {
    ..qualified.scenarios[0],
    observable: false,
    recoverable: false,
  }
  let result = qualify_resilience_plan(qualified)
  guard result is Ok(report) else { fail("expected report") }
  assert_eq(report.scenarios[0].outcome, "safe-return")
  assert_true(
    report.scenarios[0].remaining_limitations.contains(
      "fault is not observable with declared sensors",
    ),
  )
}
