///|
pub(all) struct MoonroboLiveExerciseRequest {
  exercise_id : String
  task_message : @task.RobotTaskMessageRequest
  validation_sample_count : Int
  routine_max_steps : Int
  proof_iterations : Int
  proof_max_steps : Int
  bootstrap : Bool
  stop_when_ready : Bool
  remember : Bool
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct MoonroboLiveExerciseResponse {
  exercise_id : String
  exercise_path : String
  persisted : Bool
  status : String
  closure : MoonroboLiveExerciseClosureSummary
  validation : Json
  routine : MoonClawRobotRoutineResponse
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
  routine_accepted : Bool
  routine_blocked_count : Int
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
pub fn moonrobo_live_exercise_path() -> String {
  "/api/moonrobo/live-exercise"
}

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
fn default_live_exercise_request() -> MoonroboLiveExerciseRequest {
  {
    exercise_id: "live-exercise",
    task_message: @task.task_message_request(
      "live-exercise",
      "",
      @core.operator_requester("live-exercise"),
      "walk forward when ready",
      0L,
    ),
    validation_sample_count: 3,
    routine_max_steps: 6,
    proof_iterations: 3,
    proof_max_steps: 8,
    bootstrap: true,
    stop_when_ready: true,
    remember: true,
  }
}

///|
fn bound_count(value : Int, low : Int, high : Int) -> Int {
  if value < low {
    low
  } else if value > high {
    high
  } else {
    value
  }
}

///|
fn bounded_live_exercise_request(
  request : MoonroboLiveExerciseRequest,
) -> MoonroboLiveExerciseRequest {
  {
    exercise_id: request.exercise_id,
    task_message: request.task_message,
    validation_sample_count: bound_count(request.validation_sample_count, 1, 12),
    routine_max_steps: bound_count(request.routine_max_steps, 1, 12),
    proof_iterations: bound_count(request.proof_iterations, 1, 8),
    proof_max_steps: bound_count(request.proof_max_steps, 1, 12),
    bootstrap: request.bootstrap,
    stop_when_ready: request.stop_when_ready,
    remember: request.remember,
  }
}

///|
fn decode_live_exercise_request(
  body : String,
) -> Result[MoonroboLiveExerciseRequest, HostApiResponse] {
  let submitted = body.trim().to_owned()
  if submitted == "" || submitted == "{}" {
    return Ok(default_live_exercise_request())
  }
  let json = @json.parse(submitted) catch {
    _ =>
      return Err(
        error_response(
          400,
          "parse-live-exercise",
          moonrobo_live_exercise_path(),
          "failed to parse Moonrobo live exercise JSON",
        ),
      )
  }
  let request : MoonroboLiveExerciseRequest = @json.from_json(json) catch {
    _ =>
      return Err(
        error_response(
          400,
          "decode-live-exercise",
          moonrobo_live_exercise_path(),
          "failed to decode Moonrobo live exercise contract",
        ),
      )
  }
  Ok(bounded_live_exercise_request(request))
}

///|
fn live_exercise_safe_id(value : String) -> String {
  value
  .replace(old="/", new="-")
  .replace(old=":", new="-")
  .replace(old=" ", new="-")
}

///|
fn live_exercise_id(request : MoonroboLiveExerciseRequest) -> String {
  if request.exercise_id != "" {
    live_exercise_safe_id(request.exercise_id)
  } else if request.task_message.message_id != "" {
    live_exercise_safe_id("live-exercise-\{request.task_message.message_id}")
  } else {
    "live-exercise-\{request.task_message.now_ms}"
  }
}

///|
fn live_exercise_dir(root : String) -> String {
  @runtime.robobook_path(root, "runs/live-exercises")
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
          500, "read-live-exercises", dir, "failed to read Moonrobo live exercise directory",
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
          500, "parse-live-exercise-artifact", path, "failed to parse Moonrobo live exercise artifact",
        ),
      )
  }
  let exercise : MoonroboLiveExerciseResponse = @json.from_json(json) catch {
    _ =>
      return Err(
        error_response(
          500, "decode-live-exercise-artifact", path, "failed to decode Moonrobo live exercise artifact",
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
          404, "read-live-exercise", path, "failed to read Moonrobo live exercise artifact",
        ),
      )
  }
  decode_live_exercise_file(path, text)
}

///|
fn ensure_live_exercise_dir(root : String) -> Result[String, HostApiResponse] {
  match @runtime.ensure_process_dirs(root) {
    Err(issue) =>
      return Err(error_response(500, issue.code, issue.path, issue.message))
    Ok(_) => ()
  }
  let dir = live_exercise_dir(root)
  if !@fsx.path_exists(dir) {
    @fsx.create_dir(dir) catch {
      _ =>
        return Err(
          error_response(
            500, "create-live-exercise-dir", dir, "failed to create Moonrobo live exercise directory",
          ),
        )
    }
  }
  Ok(dir)
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
fn decode_routine_response(
  response : HostApiResponse,
) -> Result[MoonClawRobotRoutineResponse, HostApiResponse] {
  let json = match
    decode_response_json(
      response,
      "parse-live-exercise-routine",
      moonclaw_robot_routine_path(),
    ) {
    Ok(json) => json
    Err(response) => return Err(response)
  }
  let routine : MoonClawRobotRoutineResponse = @json.from_json(json) catch {
    _ =>
      return Err(
        error_response(
          500,
          "decode-live-exercise-routine",
          moonclaw_robot_routine_path(),
          "failed to decode downstream MoonClaw robot routine response",
        ),
      )
  }
  Ok(routine)
}

///|
fn decode_proof_session_response(
  response : HostApiResponse,
) -> Result[PlatformProofSessionResponse, HostApiResponse] {
  let json = match
    decode_response_json(
      response,
      "parse-live-exercise-proof-session",
      platform_proof_session_path(),
    ) {
    Ok(json) => json
    Err(response) => return Err(response)
  }
  let proof : PlatformProofSessionResponse = @json.from_json(json) catch {
    _ =>
      return Err(
        error_response(
          500,
          "decode-live-exercise-proof-session",
          platform_proof_session_path(),
          "failed to decode downstream Moonrobo proof-session response",
        ),
      )
  }
  Ok(proof)
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
          "failed to decode downstream Moonrobo live readiness response",
        ),
      )
  }
  Ok(readiness)
}

///|
fn live_exercise_validation_body(
  request : MoonroboLiveExerciseRequest,
) -> String {
  @runtime.default_runtime_validation_session_request(
    sample_count=request.validation_sample_count,
  )
  .to_json()
  .stringify()
}

///|
fn live_exercise_routine_body(request : MoonroboLiveExerciseRequest) -> String {
  MoonClawRobotRoutineRequest::{
    task_message: request.task_message,
    max_steps: request.routine_max_steps,
    remember: request.remember,
  }
  .to_json()
  .stringify()
}

///|
fn live_exercise_proof_body(
  request : MoonroboLiveExerciseRequest,
  exercise_id : String,
) -> String {
  PlatformProofSessionRequest::{
    session_id: "proof-session-\{exercise_id}",
    task_message: request.task_message,
    iterations: request.proof_iterations,
    max_steps: request.proof_max_steps,
    bootstrap: request.bootstrap,
    stop_when_ready: request.stop_when_ready,
  }
  .to_json()
  .stringify()
}

///|
fn live_exercise_status(
  routine : MoonClawRobotRoutineResponse,
  proof : PlatformProofSessionResponse,
  readiness : MoonroboLiveReadinessResponse,
) -> String {
  if readiness.proof_session_feedback_closed || readiness.status == "verified" {
    "verified"
  } else if proof.ready {
    "proof-ready"
  } else if routine.blocked_count > 0 || proof.status == "blocked" {
    "blocked"
  } else {
    "pending-proof"
  }
}

///|
fn live_exercise_message(
  status : String,
  routine : MoonClawRobotRoutineResponse,
  proof : PlatformProofSessionResponse,
) -> String {
  match status {
    "verified" =>
      "Moonrobo live exercise closed the loop with validation, routine, proof-session, and physical feedback."
    "proof-ready" =>
      "Moonrobo live exercise reached loop proof; bind physical feedback to close the final gate."
    "blocked" =>
      "Moonrobo live exercise stopped with \{routine.blocked_count} routine blocker(s) and proof status \{proof.status}."
    _ =>
      "Moonrobo live exercise persisted validation, routine, and proof-session evidence for the next proof step."
  }
}

///|
fn live_exercise_closure_missing(
  request : MoonroboLiveExerciseRequest,
  routine : MoonClawRobotRoutineResponse,
  proof : PlatformProofSessionResponse,
  readiness : MoonroboLiveReadinessResponse,
  memory : MoonBookMemoryResponse,
) -> Array[String] {
  let missing : Array[String] = []
  if !readiness.ready_for_live_sdk {
    missing.push("runtime-validation")
  }
  if !readiness.can_run_robot_routine {
    missing.push("robot-routine-readiness")
  }
  if !routine.accepted {
    missing.push("robot-routine-accepted")
  }
  if routine.blocked_count > 0 {
    missing.push("robot-routine-unblocked")
  }
  if proof.attempted_count < request.proof_iterations {
    missing.push("proof-session-attempts")
  }
  if !proof.ready {
    missing.push("loop-proof")
  }
  if !readiness.proof_session_feedback_closed {
    missing.push("physical-feedback")
  }
  if !memory.persisted {
    missing.push("moonbook-memory")
  }
  missing
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
fn live_exercise_closure_summary(
  request : MoonroboLiveExerciseRequest,
  status : String,
  routine : MoonClawRobotRoutineResponse,
  proof : PlatformProofSessionResponse,
  readiness : MoonroboLiveReadinessResponse,
  memory : MoonBookMemoryResponse,
  next_route : String,
) -> MoonroboLiveExerciseClosureSummary {
  let missing = live_exercise_closure_missing(
    request, routine, proof, readiness, memory,
  )
  {
    closed: missing.is_empty() && status == "verified",
    status,
    requested_validation_sample_count: request.validation_sample_count,
    routine_accepted: routine.accepted,
    routine_blocked_count: routine.blocked_count,
    proof_ready: proof.ready,
    proof_attempted_count: proof.attempted_count,
    feedback_closed: readiness.proof_session_feedback_closed,
    memory_persisted: memory.persisted,
    missing_count: missing.length(),
    missing,
    next_route,
    message: live_exercise_closure_message(status, missing),
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
  if readiness.can_run_robot_routine {
    missing = missing_without_gate(missing, "robot-routine-readiness")
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
    exercise.routine,
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
      exercise.routine,
      exercise.proof_session,
    ),
  }
}

///|
fn live_exercise_memory_card(
  root : String,
  exercise_id : String,
  exercise_path : String,
  status : String,
  request : MoonroboLiveExerciseRequest,
) -> Result[@moonbook.MoonBookMemoryCard, HostApiResponse] {
  let book = match @runtime.load_robobook(root) {
    Ok(book) => book
    Err(issue) =>
      return Err(error_response(500, issue.code, issue.path, issue.message))
  }
  let resident = resident_projection(
    book,
    sidecar_status(book.profile, root),
    root,
  )
  Ok(
    @moonbook.memory_card(
      book.profile.id,
      resident.resident_id,
      "live-exercise",
      if status == "verified" {
        96
      } else {
        82
      },
      "Latest live exercise",
      "Exercise \{exercise_id} status \{status}; task \{request.task_message.message_id}; validation/routine/proof artifacts persisted.",
      exercise_path,
      moonrobo_live_exercise_path(),
      request.task_message.now_ms,
    ),
  )
}

///|
fn write_live_exercise_response(
  root : String,
  response : MoonroboLiveExerciseResponse,
) -> Result[String, HostApiResponse] {
  match ensure_live_exercise_dir(root) {
    Ok(_) => ()
    Err(response) => return Err(response)
  }
  @fsx.write_string_to_file(
    response.exercise_path,
    response.to_json().stringify(indent=2),
  ) catch {
    _ =>
      return Err(
        error_response(
          500,
          "write-live-exercise",
          response.exercise_path,
          "failed to persist Moonrobo live exercise artifact",
        ),
      )
  }
  Ok(response.exercise_path)
}

///|
pub fn moonrobo_live_exercise_response(
  root : String,
  body : String,
) -> HostApiResponse {
  let request = match decode_live_exercise_request(body) {
    Ok(request) => request
    Err(response) => return response
  }
  let exercise_id = live_exercise_id(request)
  let exercise_path = live_exercise_path_for(root, exercise_id)
  let validation_response = runtime_validation_session_response(
    root,
    live_exercise_validation_body(request),
  )
  if validation_response.status < 200 || validation_response.status >= 300 {
    return validation_response
  }
  let validation = match
    decode_response_json(
      validation_response,
      "parse-live-exercise-validation",
      runtime_validation_session_path(),
    ) {
    Ok(json) => json
    Err(response) => return response
  }
  let routine_response = moonclaw_robot_routine_response(
    root,
    live_exercise_routine_body(request),
  )
  if routine_response.status < 200 || routine_response.status >= 300 {
    return routine_response
  }
  let routine = match decode_routine_response(routine_response) {
    Ok(routine) => routine
    Err(response) => return response
  }
  let proof_response = platform_proof_session_response(
    root,
    live_exercise_proof_body(request, exercise_id),
  )
  if proof_response.status < 200 || proof_response.status >= 300 {
    return proof_response
  }
  let proof = match decode_proof_session_response(proof_response) {
    Ok(proof) => proof
    Err(response) => return response
  }
  let readiness_response = moonrobo_live_readiness_response(root)
  if readiness_response.status < 200 || readiness_response.status >= 300 {
    return readiness_response
  }
  let readiness = match decode_live_readiness_response(readiness_response) {
    Ok(readiness) => readiness
    Err(response) => return response
  }
  let status = live_exercise_status(routine, proof, readiness)
  let card = match
    live_exercise_memory_card(root, exercise_id, exercise_path, status, request) {
    Ok(card) => card
    Err(response) => return response
  }
  let memory = match
    persist_moonbook_memory_with_extra_cards(
      root,
      request.task_message.now_ms,
      [card],
    ) {
    Ok(memory) => memory
    Err(response) => return response
  }
  let next_route = if status == "verified" {
    robo_ask_path()
  } else {
    readiness.next_route
  }
  let closure = live_exercise_closure_summary(
    request, status, routine, proof, readiness, memory, next_route,
  )
  let response : MoonroboLiveExerciseResponse = {
    exercise_id,
    exercise_path,
    persisted: true,
    status,
    closure,
    validation,
    routine,
    proof_session: proof,
    readiness,
    memory,
    next_route,
    message: live_exercise_message(status, routine, proof),
  }
  match write_live_exercise_response(root, response) {
    Ok(_) => json_response(200, response.to_json())
    Err(error) => error
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
    routine_accepted: false,
    routine_blocked_count: 0,
    proof_ready: false,
    proof_attempted_count: 0,
    feedback_closed: false,
    memory_persisted: false,
    missing_count: 1,
    missing: ["live-exercise"],
    next_route: moonrobo_live_exercise_path(),
    message: "No live exercise closure has been recorded.",
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
        404, "not-found", path, "No Moonrobo live exercise detail route",
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
