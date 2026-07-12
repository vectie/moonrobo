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
  let value = Json::object(design)
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
