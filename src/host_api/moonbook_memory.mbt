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
) -> Result[@moonbook.MoonBookMemoryPack, HostApiResponse] {
  let book = match @runtime.load_robotbook(root) {
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
  let queue = match project_agent_work_queue(root, generated_at_ms) {
    Ok(queue) => queue
    Err(response) => return Err(response)
  }
  Ok(@moonbook.project(resident, reviews, queue, generated_at_ms))
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
pub fn moonbook_remember_response(root : String) -> HostApiResponse {
  let pack = match moonbook_memory_pack(root, 0L) {
    Ok(pack) => pack
    Err(response) => return response
  }
  let memory_path = match
    @runtime.write_moonbook_memory_json(
      root,
      pack.pack_id,
      @moonbook.memory_pack_json(pack),
    ) {
    Ok(path) => path
    Err(issue) =>
      return error_response(500, issue.code, issue.path, issue.message)
  }
  json_response(200, { persisted: true, memory_path, pack }.to_json())
}
