///|
pub(all) struct MoonBookMemoryResponse {
  persisted : Bool
  memory_path : String
  pack : @moonbook.MoonBookMemoryPack
} derive(Debug, Eq, ToJson, FromJson)

///|
pub fn moonbook_memory_path() -> String {
  "/api/moonbook/memory"
}

///|
pub fn moonbook_remember_path() -> String {
  "/api/moonbook/remember"
}

///|
fn moonbook_memory_pack(
  root : String,
  generated_at_ms : Int64,
  extra_cards? : Array[@moonbook.MoonBookMemoryCard] = [],
) -> Result[@moonbook.MoonBookMemoryPack, HostApiResponse] {
  let book = match @runtime.load_robobook(root) {
    Ok(book) => book
    Err(issue) =>
      return Err(error_response(500, issue.code, issue.path, issue.message))
  }
  let reviews = reviews_or_empty(root)
  let resident = resident_projection(
    book,
    sidecar_status(book.profile, root),
    root,
  )
  let queue = match project_robot_platform_queue(root, generated_at_ms) {
    Ok(queue) => queue
    Err(response) => return Err(response)
  }
  let latest_runtime_health = match @runtime.read_latest_runtime_health(root) {
    Ok(record) => Some(record)
    Err(_) => None
  }
  let all_extra_cards : Array[@moonbook.MoonBookMemoryCard] = []
  for card in extra_cards {
    all_extra_cards.push(card)
  }
  match
    latest_live_exercise_memory_card(root, book, resident, generated_at_ms) {
    Some(memory) => all_extra_cards.push(memory)
    None => ()
  }
  match prove_loop_memory_card(root, resident, generated_at_ms) {
    Some(memory) => all_extra_cards.push(memory)
    None => ()
  }
  Ok(
    match latest_runtime_health {
      Some(record) =>
        @moonbook.project(
          resident,
          reviews,
          queue,
          generated_at_ms,
          latest_runtime_health=record,
          extra_cards=all_extra_cards,
        )
      None =>
        @moonbook.project(
          resident,
          reviews,
          queue,
          generated_at_ms,
          extra_cards=all_extra_cards,
        )
    },
  )
}

///|
fn live_exercise_closure_memory_summary(
  exercise : MoonroboLiveExerciseResponse,
) -> String {
  if exercise.closure.closed {
    "Live exercise \{exercise.exercise_id} closed; validation, MoonClaw routine, proof session, physical feedback, and MoonBook memory are present."
  } else {
    let missing_text = exercise.closure.missing.join(", ")
    "Live exercise \{exercise.exercise_id} is \{exercise.closure.status}; missing \{exercise.closure.missing_count} gate(s): \{missing_text}; next \{exercise.closure.next_route}."
  }
}

///|
fn latest_live_exercise_memory_card(
  root : String,
  book : @runtime.LoadedRoboBook,
  resident : @resident.ResidentRobotAgent,
  generated_at_ms : Int64,
) -> @moonbook.MoonBookMemoryCard? {
  match latest_live_exercise_for_product(root) {
    Some(exercise) =>
      Some(
        @moonbook.memory_card(
          book.profile.id,
          resident.resident_id,
          "live-exercise-closure",
          if exercise.closure.closed {
            64
          } else {
            95
          },
          "Latest live exercise closure",
          live_exercise_closure_memory_summary(exercise),
          exercise.exercise_path,
          if exercise.closure.next_route == "" {
            moonclaw_context_path()
          } else {
            exercise.closure.next_route
          },
          generated_at_ms,
        ),
      )
    None => None
  }
}

///|
pub fn moonbook_memory_response(root : String) -> HostApiResponse {
  match moonbook_memory_pack(root, 0L) {
    Ok(pack) =>
      json_response(200, { persisted: false, memory_path: "", pack }.to_json())
    Err(response) => response
  }
}

///|
pub fn persist_moonbook_memory(
  root : String,
  generated_at_ms : Int64,
) -> Result[MoonBookMemoryResponse, HostApiResponse] {
  persist_moonbook_memory_with_extra_cards(root, generated_at_ms, [])
}

///|
fn persist_moonbook_memory_with_extra_cards(
  root : String,
  generated_at_ms : Int64,
  extra_cards : Array[@moonbook.MoonBookMemoryCard],
) -> Result[MoonBookMemoryResponse, HostApiResponse] {
  let pack = match moonbook_memory_pack(root, generated_at_ms, extra_cards~) {
    Ok(pack) => pack
    Err(response) => return Err(response)
  }
  let memory_path = match
    @runtime.write_moonbook_memory_json(
      root,
      pack.pack_id,
      @moonbook.memory_pack_json(pack),
    ) {
    Ok(path) => path
    Err(issue) =>
      return Err(error_response(500, issue.code, issue.path, issue.message))
  }
  Ok({ persisted: true, memory_path, pack })
}

///|
pub fn moonbook_remember_response(root : String) -> HostApiResponse {
  match persist_moonbook_memory(root, 0L) {
    Ok(response) => json_response(200, response.to_json())
    Err(response) => response
  }
}
