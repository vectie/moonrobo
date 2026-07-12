///|
fn object(value : Json, label : String) -> Map[String, Json] raise {
  match value {
    Object(fields) => fields
    _ => fail("MoonRobo Flow attestor requires \{label} to be an object")
  }
}

///|
fn string_field(fields : Map[String, Json], name : String) -> String raise {
  match fields.get(name) {
    Some(String(value)) if !value.trim().is_empty() => value
    _ => fail("MoonRobo Flow attestor requires \{name}")
  }
}

///|
fn safe_ref(reference : String) -> Bool {
  let value = reference.trim().replace(old="\\", new="/")
  !value.is_empty() &&
  !value.has_prefix("/") &&
  !value.split("/").any(part => part.is_empty() || part == "..")
}

///|
fn scoped_path(workspace : String, reference : String) -> String raise {
  if !safe_ref(reference) {
    fail("MoonRobo Flow artifact must be workspace-relative")
  }
  @pathx.join(@pathx.normalize(workspace), reference)
}

///|
async fn read_json(path : String) -> Json {
  @json.parse(@fsx.read_file(path))
}

///|
async fn write_json(path : String, value : Json) -> Unit {
  @fsx.make_directory(@pathx.dirname(path), recursive=true, exists_ok=true)
  @fsx.write_to_file(path, value.stringify(indent=2) + "\n", create=0o644)
}

///|
fn validate_safety_predicate_coverage(design : Json) -> Unit raise {
  let design_fields = object(design, "robot design")
  let constraints = object(
    design_fields.get("constraints").unwrap_or(Json::null()),
    "robot design constraints",
  )
  if constraints.contains("motion_requires") {
    fail(
      "MoonRobo constraints must encode motion safety as safety_predicates, not free-form motion_requires",
    )
  }
  let predicates = match constraints.get("safety_predicates") {
    Some(Array(values)) if values.length() >= 2 => values
    _ => fail("MoonRobo constraints require at least two safety_predicates")
  }
  let validation = object(
    design_fields.get("validation").unwrap_or(Json::null()),
    "robot design validation",
  )
  let scenarios = match validation.get("scenarios") {
    Some(Array(values)) => values
    _ => fail("MoonRobo robot design requires validation scenarios")
  }
  let predicate_ids : Array[String] = []
  let adverse_scenario_ids : Array[String] = []
  for predicate_value in predicates {
    let predicate = object(predicate_value, "safety predicate")
    let predicate_id = string_field(predicate, "predicate_id")
    let state_key = string_field(predicate, "state_key")
    let adverse_scenario_id = string_field(predicate, "adverse_scenario_id")
    let safe_value = match predicate.get("safe_value") {
      Some(True) => true
      Some(False) => false
      _ => fail("MoonRobo safety predicate safe_value must be boolean")
    }
    if predicate_ids.contains(predicate_id) {
      fail("MoonRobo safety predicate ids must be unique")
    }
    if adverse_scenario_ids.contains(adverse_scenario_id) {
      fail("MoonRobo safety predicates require distinct adverse scenarios")
    }
    predicate_ids.push(predicate_id)
    adverse_scenario_ids.push(adverse_scenario_id)
    let mut covered = false
    for scenario_value in scenarios {
      let scenario = object(scenario_value, "robot scenario")
      if string_field(scenario, "id") == adverse_scenario_id {
        let kind = string_field(scenario, "kind")
        if kind != "negative" && kind != "degraded" {
          fail("MoonRobo safety predicate must reference an adverse scenario")
        }
        let initial_state = object(
          scenario.get("initial_state").unwrap_or(Json::null()),
          "adverse scenario initial_state",
        )
        let expected_unsafe = Json::boolean(!safe_value)
        if initial_state.get(state_key) != Some(expected_unsafe) {
          fail(
            "MoonRobo adverse scenario must invert safety predicate state: \{predicate_id}",
          )
        }
        covered = true
      }
    }
    if !covered {
      fail(
        "MoonRobo safety predicate references missing adverse scenario: \{predicate_id}",
      )
    }
  }
}

///|
fn robot_design_from_draft(draft : Json) -> Json raise {
  let fields = object(draft, "digital design draft")
  if string_field(fields, "contract_id") != "moonrobo.digital-design.v1" {
    fail("MoonRobo build draft has the wrong contract")
  }
  if string_field(fields, "product_id") != "moonrobo" {
    fail("MoonRobo build draft has the wrong product identity")
  }
  let design : Map[String, Json] = {}
  design["contract_id"] = "moonsuite.robot-design.v1"
  for
    name in [
      "design_id", "revision", "mission", "task_loop", "mechanisms", "validation",
      "constraints",
    ] {
    match fields.get(name) {
      Some(value) => design[name] = value
      None => fail("MoonRobo build draft requires \{name}")
    }
  }
  for
    name in [
      "requirement_traceability", "hazards", "margins", "unsupported_physical_assumptions",
      "uncertainties_and_contradictions", "sources", "trial_evidence", "artifact_claim",
      "claim_ceiling", "physical_readiness",
    ] {
    match fields.get(name) {
      Some(value) => design[name] = value
      None => ()
    }
  }
  let value = Json::object(design)
  validate_safety_predicate_coverage(value)
  match @design_builder.profile_from_design(value) {
    Ok(_) => value
    Err(issue) => fail("MoonRobo rejected digital design: \{issue.message}")
  }
}

///|
async fn find_digital_design(
  workspace : String,
  request_fields : Map[String, Json],
) -> Json {
  guard request_fields.get("input_artifacts") is Some(Array(inputs)) else {
    fail("MoonRobo validation request requires input_artifacts")
  }
  for input in inputs {
    match input {
      String(reference) if safe_ref(reference) => {
        let value = read_json(scoped_path(workspace, reference)) catch {
          _ => continue
        }
        match value {
          Object(fields) =>
            if fields.get("contract_id") ==
              Some(Json::string("moonrobo.digital-design.v1")) {
              return value
            }
          _ => ()
        }
      }
      _ => ()
    }
  }
  fail("MoonRobo validation could not find its accepted digital design input")
}

///|
fn require_non_empty_array(
  fields : Map[String, Json],
  name : String,
) -> Json raise {
  match fields.get(name) {
    Some(Array(values)) if !values.is_empty() => values.to_json()
    _ => fail("MoonRobo validation draft requires non-empty \{name}")
  }
}

///|
fn resolve_scenario_value(
  state : Map[String, Json],
  input : Json,
) -> Json raise {
  let fields = object(input, "scenario step input")
  match fields.get("state") {
    Some(String(name)) if !name.trim().is_empty() =>
      state
      .get(name)
      .unwrap_or_else(() => {
        fail("MoonRobo scenario references missing state: \{name}")
      })
    Some(_) => fail("MoonRobo scenario state reference must be a string")
    None =>
      fields
      .get("literal")
      .unwrap_or_else(() => {
        fail("MoonRobo scenario input requires state or literal")
      })
  }
}

///|
fn scenario_number(value : Json, label : String) -> Double raise {
  match value {
    Number(number, ..) => number
    _ => fail("MoonRobo scenario requires numeric \{label}")
  }
}

///|
fn scenario_boolean(value : Json, label : String) -> Bool raise {
  match value {
    True => true
    False => false
    _ => fail("MoonRobo scenario requires boolean \{label}")
  }
}

///|
fn execute_scenario_operation(
  operation : String,
  inputs : Array[Json],
) -> Json raise {
  if operation == "select" {
    if inputs.length() != 3 {
      fail("MoonRobo scenario select requires three inputs")
    }
    return if scenario_boolean(inputs[0], "select condition") {
      inputs[1]
    } else {
      inputs[2]
    }
  }
  if inputs.length() != 2 {
    fail("MoonRobo scenario operation requires two inputs")
  }
  let left = inputs[0]
  let right = inputs[1]
  match operation {
    "add" =>
      Json::number(
        scenario_number(left, "left input") +
        scenario_number(right, "right input"),
      )
    "subtract" =>
      Json::number(
        scenario_number(left, "left input") -
        scenario_number(right, "right input"),
      )
    "multiply" =>
      Json::number(
        scenario_number(left, "left input") *
        scenario_number(right, "right input"),
      )
    "less_or_equal" =>
      Json::boolean(
        scenario_number(left, "left input") <=
        scenario_number(right, "right input"),
      )
    "greater_or_equal" =>
      Json::boolean(
        scenario_number(left, "left input") >=
        scenario_number(right, "right input"),
      )
    "equal" => Json::boolean(left == right)
    "boolean_and" =>
      Json::boolean(
        scenario_boolean(left, "left input") &&
        scenario_boolean(right, "right input"),
      )
    "boolean_or" =>
      Json::boolean(
        scenario_boolean(left, "left input") ||
        scenario_boolean(right, "right input"),
      )
    _ => fail("MoonRobo scenario operation is not allowed: \{operation}")
  }
}

///|
fn state_snapshot(state : Map[String, Json]) -> Json raise {
  @json.parse(Json::object(state).stringify())
}

///|
fn execute_design_scenarios(design : Json) -> Json raise {
  let design_fields = object(design, "accepted robot design")
  let validation = object(
    design_fields.get("validation").unwrap_or(Json::null()),
    "robot design validation",
  )
  let scenarios = match validation.get("scenarios") {
    Some(Array(values)) if values.length() >= 3 => values
    _ => fail("MoonRobo native execution requires at least three scenarios")
  }
  let executions : Array[Json] = []
  let mut nominal_count = 0
  let mut adverse_count = 0
  for scenario_value in scenarios {
    let scenario = object(scenario_value, "robot scenario")
    let scenario_id = string_field(scenario, "id")
    let kind = string_field(scenario, "kind")
    if kind == "nominal" {
      nominal_count += 1
    } else if kind == "negative" || kind == "degraded" {
      adverse_count += 1
    } else {
      fail("MoonRobo scenario kind must be nominal, negative, or degraded")
    }
    let state = object(
      scenario.get("initial_state").unwrap_or(Json::null()),
      "scenario initial_state",
    )
    if state.is_empty() {
      fail("MoonRobo scenario initial_state must be non-empty")
    }
    let steps = match scenario.get("steps") {
      Some(Array(values)) if !values.is_empty() => values
      _ => fail("MoonRobo scenario requires non-empty steps")
    }
    let history : Array[Json] = [
      {
        "sequence": 0,
        "event": "initial-state",
        "state": state_snapshot(state),
      },
    ]
    let step_results : Array[Json] = []
    for step_value in steps {
      let step = object(step_value, "scenario step")
      let step_id = string_field(step, "step_id")
      let operation = string_field(step, "operation")
      let output = string_field(step, "output")
      let input_specs = match step.get("inputs") {
        Some(Array(values)) if !values.is_empty() => values
        _ => fail("MoonRobo scenario step requires inputs")
      }
      let resolved = input_specs.map(input => {
        resolve_scenario_value(state, input)
      })
      let expected = step
        .get("expected")
        .unwrap_or_else(() => fail("MoonRobo scenario step requires expected"))
      let actual = execute_scenario_operation(operation, resolved)
      if actual != expected {
        fail("MoonRobo scenario step failed: \{scenario_id}/\{step_id}")
      }
      state[output] = actual
      let snapshot = state_snapshot(state)
      step_results.push({
        "step_id": step_id,
        "operation": operation,
        "input_specs": input_specs.to_json(),
        "resolved_inputs": resolved.to_json(),
        "output": output,
        "expected": expected,
        "actual": actual,
        "comparison": "exact-json-equality",
        "status": "passed",
      })
      history.push({
        "sequence": history.length(),
        "event": step_id,
        "state": snapshot,
      })
    }
    executions.push({
      "scenario_id": scenario_id,
      "kind": kind,
      "expected_outcome": string_field(scenario, "expected"),
      "status": "passed",
      "executed_by": "native MoonRobo scenario executor",
      "step_results": step_results.to_json(),
      "state_history": history.to_json(),
    })
  }
  if nominal_count == 0 || adverse_count == 0 {
    fail(
      "MoonRobo scenarios require nominal and negative or degraded execution",
    )
  }
  {
    "contract_id": "moonrobo.scenario-execution.v1",
    "executor": "native MoonRobo scenario executor",
    "scenario_count": executions.length(),
    "nominal_count": nominal_count,
    "adverse_count": adverse_count,
    "all_passed": true,
    "executions": executions.to_json(),
  }
}

///|
pub async fn attest(
  workspace : String,
  request_ref : String,
  result_ref : String,
  attestation_ref : String,
  attestor_id : String,
  draft_ref : String,
  final_ref : String,
) -> Unit {
  let request = read_json(scoped_path(workspace, request_ref))
  let request_fields = object(request, "request")
  let result = read_json(scoped_path(workspace, result_ref))
  let result_fields = object(result, "draft result")
  let draft = read_json(scoped_path(workspace, draft_ref))
  let operation = string_field(request_fields, "operation")
  let run_id = string_field(request_fields, "run_id")
  let work_item_id = string_field(request_fields, "work_item_id")
  let recorded_at = string_field(request_fields, "created_at")
  let final_artifact : Json = match operation {
    "build-digital-robot" => {
      let robot_design = robot_design_from_draft(draft)
      let robobook_ref = ".moonsuite/products/moonrobo/runs/" +
        run_id +
        "/" +
        work_item_id +
        "/robobook"
      let robobook_root = scoped_path(workspace, robobook_ref)
      let build = match
        @design_builder.build_robobook(
          robot_design.stringify(),
          scoped_path(workspace, draft_ref),
          robobook_root,
          recorded_at,
          source_artifact_ref=draft_ref,
        ) {
        Ok(value) => value
        Err(issue) => fail("MoonRobo native build failed: \{issue.message}")
      }
      (
        {
          "contract_id": "moonrobo.digital-design.v1",
          "product_id": "moonrobo",
          "operation": operation,
          "robot_design": robot_design,
          "robobook_root": robobook_ref,
          "generated_paths": build.generated_paths.to_json(),
          "build_receipt_ref": robobook_ref + "/design/build-receipt.json",
          "physical_readiness": false,
          "claim_ceiling": "digital-artifact",
        } : Json)
    }
    "validate-requirements" => {
      let design = find_digital_design(workspace, request_fields)
      let design_fields = object(design, "accepted digital design")
      let robot_design = design_fields
        .get("robot_design")
        .unwrap_or_else(() => {
          fail("MoonRobo accepted digital design requires robot_design")
        })
      let scenario_execution = execute_design_scenarios(robot_design)
      let robobook_ref = string_field(design_fields, "robobook_root")
      let native_validation = match
        @design_builder.validate_robobook(
          scoped_path(workspace, robobook_ref),
          recorded_at,
        ) {
        Ok(value) => value
        Err(issue) =>
          fail("MoonRobo native validation failed: \{issue.message}")
      }
      let draft_fields = object(draft, "validation draft")
      if string_field(draft_fields, "contract_id") !=
        "moonrobo.validation-evidence.v1" ||
        string_field(draft_fields, "product_id") != "moonrobo" {
        fail("MoonRobo validation draft has the wrong identity")
      }
      (
        {
          "contract_id": "moonrobo.validation-evidence.v1",
          "product_id": "moonrobo",
          "operation": operation,
          "robobook_root": robobook_ref,
          "native_validation": native_validation,
          "scenario_execution": scenario_execution,
          "constraint_results": require_non_empty_array(
            draft_fields, "constraint_results",
          ),
          "negative_cases": require_non_empty_array(
            draft_fields, "negative_cases",
          ),
          "failure_traces": require_non_empty_array(
            draft_fields, "failure_traces",
          ),
          "aggregate_scores_can_hide_failure": false,
          "physical_readiness": false,
          "claim_ceiling": "simulation-evidence",
        } : Json)
    }
    _ => fail("MoonRobo does not own Flow operation \{operation}")
  }
  write_json(scoped_path(workspace, final_ref), final_artifact)
  write_json(scoped_path(workspace, attestation_ref), {
    "contract_id": "moonflow.product-attestation.v1",
    "attestor_id": attestor_id,
    "product_id": "moonrobo",
    "request_id": string_field(request_fields, "request_id"),
    "result_id": string_field(result_fields, "result_id"),
    "output_digest": string_field(result_fields, "output_digest"),
    "accepted": true,
    "native_final_artifact": final_ref,
    "operation": operation,
  })
}
