///|
pub(all) struct MoonroboLiveExerciseResponse {
  exercise_id : String
  exercise_path : String
  persisted : Bool
  status : String
  closure : MoonroboLiveExerciseClosureSummary
  validation : Json
  gateway_command : MoonroboGatewayCommandResponse
  proof_session : PlatformProofSessionResponse
  readiness : MoonroboLiveReadinessResponse
  memory : MoonBookMemoryResponse
  next_route : String
  message : String
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct MoonroboLiveExerciseClosureSummary {
  closed : Bool
  status : String
  requested_validation_sample_count : Int
  command_accepted : Bool
  command_blocked_count : Int
  proof_ready : Bool
  proof_attempted_count : Int
  feedback_closed : Bool
  memory_persisted : Bool
  missing_count : Int
  missing : Array[String]
  next_route : String
  message : String
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct MoonroboLiveExerciseListResponse {
  exercise_count : Int
  exercises : Array[MoonroboLiveExerciseResponse]
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct MoonroboLiveExerciseClosureResponse {
  exercise_count : Int
  has_exercise : Bool
  exercise_id : String
  exercise_path : String
  closure : MoonroboLiveExerciseClosureSummary
  next_route : String
  message : String
} derive(Debug, Eq, ToJson, FromJson)

///|
pub fn moonrobo_live_exercise_closure_path() -> String {
  "/api/moonrobo/live-closure"
}

///|
pub fn moonrobo_live_exercises_path() -> String {
  "/api/moonrobo/live-exercises"
}

///|
pub fn moonrobo_live_exercise_detail_path(exercise_id : String) -> String {
  "/api/moonrobo/live-exercises/\{exercise_id}"
}

///|
fn live_exercise_safe_id(value : String) -> String {
  value
  .replace(old="/", new="-")
  .replace(old=":", new="-")
  .replace(old=" ", new="-")
}

///|
fn live_exercise_dir(root : String) -> String {
  @runtime.moonrobo_live_exercises_dir(root)
}

///|
fn live_exercise_path_for(root : String, exercise_id : String) -> String {
  live_exercise_dir(root) + "/\{exercise_id}.json"
}

///|
fn live_exercise_id_from_detail_path(path : String) -> String? {
  let prefix = moonrobo_live_exercises_path() + "/"
  if path.has_prefix(prefix) && path.length() > prefix.length() {
    Some(path[prefix.length():path.length()].to_owned())
  } else {
    None
  }
}

///|
fn list_live_exercise_paths(
  root : String,
) -> Result[Array[String], HostApiResponse] {
  let dir = live_exercise_dir(root)
  if !@fsx.path_exists(dir) {
    return Ok([])
  }
  let names = @fsx.read_dir(dir) catch {
    _ =>
      return Err(
        error_response(
          500, "read-live-exercises", dir, "failed to read MoonRobo live exercise directory",
        ),
      )
  }
  names.sort()
  let paths : Array[String] = []
  for name in names {
    if name.has_suffix(".json") {
      paths.push(dir + "/\{name}")
    }
  }
  Ok(paths)
}

///|
fn decode_live_exercise_file(
  path : String,
  text : String,
) -> Result[MoonroboLiveExerciseResponse, HostApiResponse] {
  let json = @json.parse(text) catch {
    _ =>
      return Err(
        error_response(
          500, "parse-live-exercise-artifact", path, "failed to parse MoonRobo live exercise artifact",
        ),
      )
  }
  let exercise : MoonroboLiveExerciseResponse = @json.from_json(json) catch {
    _ =>
      return Err(
        error_response(
          500, "decode-live-exercise-artifact", path, "failed to decode MoonRobo live exercise artifact",
        ),
      )
  }
  Ok(exercise)
}

///|
fn read_live_exercise_file(
  path : String,
) -> Result[MoonroboLiveExerciseResponse, HostApiResponse] {
  let text = @fsx.read_file_to_string(path) catch {
    _ =>
      return Err(
        error_response(
          404, "read-live-exercise", path, "failed to read MoonRobo live exercise artifact",
        ),
      )
  }
  decode_live_exercise_file(path, text)
}

///|
fn decode_response_json(
  response : HostApiResponse,
  code : String,
  path : String,
) -> Result[Json, HostApiResponse] {
  let json = @json.parse(response.body) catch {
    _ =>
      return Err(
        error_response(
          500, code, path, "failed to parse downstream live exercise response",
        ),
      )
  }
  Ok(json)
}

///|
fn decode_live_readiness_response(
  response : HostApiResponse,
) -> Result[MoonroboLiveReadinessResponse, HostApiResponse] {
  let json = match
    decode_response_json(
      response,
      "parse-live-exercise-readiness",
      moonrobo_live_readiness_path(),
    ) {
    Ok(json) => json
    Err(response) => return Err(response)
  }
  let readiness : MoonroboLiveReadinessResponse = @json.from_json(json) catch {
    _ =>
      return Err(
        error_response(
          500,
          "decode-live-exercise-readiness",
          moonrobo_live_readiness_path(),
          "failed to decode downstream MoonRobo live readiness response",
        ),
      )
  }
  Ok(readiness)
}

///|
fn live_exercise_status(
  command : MoonroboGatewayCommandResponse,
  proof : PlatformProofSessionResponse,
  readiness : MoonroboLiveReadinessResponse,
) -> String {
  if readiness.proof_session_feedback_closed || readiness.status == "verified" {
    "verified"
  } else if proof.ready {
    "proof-ready"
  } else if !command.command.accepted || proof.status == "blocked" {
    "blocked"
  } else {
    "pending-proof"
  }
}

///|
fn live_exercise_message(
  status : String,
  command : MoonroboGatewayCommandResponse,
  proof : PlatformProofSessionResponse,
) -> String {
  match status {
    "verified" =>
      "MoonRobo live exercise closed the loop with validation, gateway command, proof-session, and physical feedback."
    "proof-ready" =>
      "MoonRobo live exercise reached loop proof; bind physical feedback to close the final gate."
    "blocked" =>
      "MoonRobo live exercise stopped with command accepted \{command.command.accepted} and proof status \{proof.status}."
    _ =>
      "MoonRobo live exercise persisted validation, gateway command, and proof-session evidence for the next proof step."
  }
}

///|
fn live_exercise_closure_message(
  status : String,
  missing : Array[String],
) -> String {
  if missing.is_empty() {
    "Live exercise closure is complete; validation, routine, proof, feedback, and memory are present."
  } else {
    let missing_text = missing.join(", ")
    "Live exercise closure is \{status}; missing \{missing.length()} gate(s): \{missing_text}."
  }
}

///|
fn missing_without_gate(
  missing : Array[String],
  gate : String,
) -> Array[String] {
  let refreshed : Array[String] = []
  for item in missing {
    if item != gate {
      refreshed.push(item)
    }
  }
  refreshed
}

///|
fn refreshed_live_exercise_missing(
  closure : MoonroboLiveExerciseClosureSummary,
  readiness : MoonroboLiveReadinessResponse,
) -> Array[String] {
  let mut missing = closure.missing
  if readiness.ready_for_live_sdk {
    missing = missing_without_gate(missing, "runtime-validation")
  }
  if readiness.can_submit_gateway_command {
    missing = missing_without_gate(missing, "gateway-command-readiness")
  }
  if readiness.loop_proof.ready {
    missing = missing_without_gate(missing, "loop-proof")
  }
  if readiness.proof_session_feedback_closed {
    missing = missing_without_gate(missing, "physical-feedback")
  }
  missing
}

///|
fn refreshed_live_exercise_closure(
  exercise : MoonroboLiveExerciseResponse,
  readiness : MoonroboLiveReadinessResponse,
  status : String,
  next_route : String,
) -> MoonroboLiveExerciseClosureSummary {
  let missing = refreshed_live_exercise_missing(exercise.closure, readiness)
  {
    ..exercise.closure,
    closed: missing.is_empty() && status == "verified",
    status,
    feedback_closed: readiness.proof_session_feedback_closed,
    missing_count: missing.length(),
    missing,
    next_route,
    message: live_exercise_closure_message(status, missing),
  }
}

///|
fn refreshed_live_exercise_for_read(
  root : String,
  exercise : MoonroboLiveExerciseResponse,
) -> MoonroboLiveExerciseResponse {
  let readiness_response = moonrobo_live_readiness_response(root)
  let readiness = if readiness_response.status >= 200 &&
    readiness_response.status < 300 {
    match decode_live_readiness_response(readiness_response) {
      Ok(value) => value
      Err(_) => exercise.readiness
    }
  } else {
    exercise.readiness
  }
  let status = live_exercise_status(
    exercise.gateway_command,
    exercise.proof_session,
    readiness,
  )
  let next_route = if status == "verified" {
    robo_ask_path()
  } else {
    readiness.next_route
  }
  let closure = refreshed_live_exercise_closure(
    exercise, readiness, status, next_route,
  )
  {
    ..exercise,
    status,
    closure,
    readiness,
    next_route,
    message: live_exercise_message(
      status,
      exercise.gateway_command,
      exercise.proof_session,
    ),
  }
}

///|
pub fn moonrobo_live_exercises_response(root : String) -> HostApiResponse {
  let paths = match list_live_exercise_paths(root) {
    Ok(paths) => paths
    Err(response) => return response
  }
  let exercises : Array[MoonroboLiveExerciseResponse] = []
  for path in paths {
    match read_live_exercise_file(path) {
      Ok(exercise) =>
        exercises.push(refreshed_live_exercise_for_read(root, exercise))
      Err(response) => return response
    }
  }
  json_response(
    200,
    MoonroboLiveExerciseListResponse::{
      exercise_count: exercises.length(),
      exercises,
    }.to_json(),
  )
}

///|
fn missing_live_exercise_closure() -> MoonroboLiveExerciseClosureSummary {
  {
    closed: false,
    status: "missing",
    requested_validation_sample_count: 0,
    command_accepted: false,
    command_blocked_count: 0,
    proof_ready: false,
    proof_attempted_count: 0,
    feedback_closed: false,
    memory_persisted: false,
    missing_count: 1,
    missing: ["moonclaw-routine-turn"],
    next_route: moonclaw_context_path(),
    message: "No live exercise audit has been recorded; MoonClaw should read context and choose the next explicit route.",
  }
}

///|
pub fn moonrobo_live_exercise_closure_response(
  root : String,
) -> HostApiResponse {
  let paths = match list_live_exercise_paths(root) {
    Ok(paths) => paths
    Err(response) => return response
  }
  if paths.is_empty() {
    let closure = missing_live_exercise_closure()
    return json_response(
      200,
      MoonroboLiveExerciseClosureResponse::{
        exercise_count: 0,
        has_exercise: false,
        exercise_id: "",
        exercise_path: "",
        closure,
        next_route: closure.next_route,
        message: closure.message,
      }.to_json(),
    )
  }
  let exercise = match read_live_exercise_file(paths[paths.length() - 1]) {
    Ok(exercise) => refreshed_live_exercise_for_read(root, exercise)
    Err(response) => return response
  }
  json_response(
    200,
    MoonroboLiveExerciseClosureResponse::{
      exercise_count: paths.length(),
      has_exercise: true,
      exercise_id: exercise.exercise_id,
      exercise_path: exercise.exercise_path,
      closure: exercise.closure,
      next_route: exercise.closure.next_route,
      message: exercise.closure.message,
    }.to_json(),
  )
}

///|
pub fn moonrobo_live_exercise_detail_response(
  root : String,
  path : String,
) -> HostApiResponse {
  let exercise_id = match live_exercise_id_from_detail_path(path) {
    Some(value) => value
    None =>
      return error_response(
        404, "not-found", path, "No MoonRobo live exercise detail route",
      )
  }
  let file_path = live_exercise_path_for(
    root,
    live_exercise_safe_id(exercise_id),
  )
  match read_live_exercise_file(file_path) {
    Ok(exercise) =>
      json_response(
        200,
        refreshed_live_exercise_for_read(root, exercise).to_json(),
      )
    Err(response) => response
  }
}
