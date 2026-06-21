///|
pub fn policy_evaluations_path() -> String {
  "/api/policies/evaluations"
}

///|
pub fn policy_evaluation_path(evaluation_id : String) -> String {
  "\{policy_evaluations_path()}/\{evaluation_id}"
}

///|
fn policy_evaluation_id_from_path(path : String) -> String? {
  let prefix = policy_evaluations_path() + "/"
  if path.has_prefix(prefix) && path.length() > prefix.length() {
    Some(path[prefix.length():path.length()].to_owned())
  } else {
    None
  }
}

///|
pub(all) struct PolicyEvaluationListResponse {
  evaluation_count : Int
  latest_evaluation_id : String
  evaluations : Array[@policy.PolicyEvaluationReceipt]
} derive(Debug, Eq, ToJson, FromJson)

///|
fn decode_policy_evaluation_file(
  path : String,
) -> Result[@policy.PolicyEvaluationReceipt, HostApiResponse] {
  let text = match @runtime.read_policy_evaluation_json_file(path) {
    Ok(text) => text
    Err(issue) =>
      return Err(error_response(500, issue.code, issue.path, issue.message))
  }
  let json = @json.parse(text) catch {
    _ =>
      return Err(
        error_response(
          500, "parse-policy-eval", path, "failed to parse policy evaluation JSON",
        ),
      )
  }
  let evaluation : @policy.PolicyEvaluationReceipt = @json.from_json(json) catch {
    _ =>
      return Err(
        error_response(
          500, "decode-policy-eval", path, "failed to decode policy evaluation contract",
        ),
      )
  }
  Ok(evaluation)
}

///|
fn policy_evaluations_or_empty(
  root : String,
) -> Array[@policy.PolicyEvaluationReceipt] {
  let paths = match @runtime.list_policy_evaluation_paths(root) {
    Ok(paths) => paths
    Err(_) => return []
  }
  let evaluations : Array[@policy.PolicyEvaluationReceipt] = []
  for path in paths {
    match decode_policy_evaluation_file(path) {
      Ok(evaluation) => evaluations.push(evaluation)
      Err(_) => ()
    }
  }
  evaluations
}

///|
fn latest_policy_evaluation_id(
  evaluations : Array[@policy.PolicyEvaluationReceipt],
) -> String {
  if evaluations.is_empty() {
    "-"
  } else {
    evaluations[evaluations.length() - 1].evaluation_id
  }
}

///|
pub fn policy_evaluations_response(root : String) -> HostApiResponse {
  let paths = match @runtime.list_policy_evaluation_paths(root) {
    Ok(paths) => paths
    Err(issue) =>
      return error_response(500, issue.code, issue.path, issue.message)
  }
  let evaluations : Array[@policy.PolicyEvaluationReceipt] = []
  for path in paths {
    match decode_policy_evaluation_file(path) {
      Ok(evaluation) => evaluations.push(evaluation)
      Err(response) => return response
    }
  }
  json_response(
    200,
    {
      evaluation_count: evaluations.length(),
      latest_evaluation_id: latest_policy_evaluation_id(evaluations),
      evaluations,
    }.to_json(),
  )
}

///|
pub fn policy_evaluation_detail_response(
  root : String,
  path : String,
) -> HostApiResponse {
  let evaluation_id = match policy_evaluation_id_from_path(path) {
    Some(value) => value
    None =>
      return error_response(
        404, "not-found", path, "No Moonrobo host API route",
      )
  }
  let text = match @runtime.read_policy_evaluation_json(root, evaluation_id) {
    Ok(text) => text
    Err(issue) =>
      return error_response(400, issue.code, issue.path, issue.message)
  }
  let json = @json.parse(text) catch {
    _ =>
      return error_response(
        500, "parse-policy-eval", path, "failed to parse policy evaluation JSON",
      )
  }
  let _evaluation : @policy.PolicyEvaluationReceipt = @json.from_json(json) catch {
    _ =>
      return error_response(
        500, "decode-policy-eval", path, "failed to decode policy evaluation contract",
      )
  }
  json_response(200, json)
}
