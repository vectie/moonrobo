///|
pub(all) struct Advertisement {
  now_ms : Int64
  catalog : @skills.Catalog
} derive(ToJson, FromJson)

///|
pub extend Advertisement with ToJson::{to_json}

///|
pub extend Advertisement with @json.FromJson::{from_json}

///|
pub async fn fetch_catalog(url : String) -> Advertisement {
  let (response, body) = @http.get(url + "/v1/catalog")
  guard response.code == 200 else { fail("task catalog HTTP \{response.code}") }
  @json.from_json(body.json())
}

///|
/// The coordinator supplies identity and timing. The LLM supplies only Proposal.
pub fn request(
  advertisement : Advertisement,
  proposal : @skills.Proposal,
  request_id~ : String,
  ttl_ms~ : Int32,
) -> @skills.Request raise {
  guard ttl_ms > 0 &&
    advertisement.now_ms >= 0L &&
    advertisement.now_ms <= 9223372036854775807L - ttl_ms.to_int64() &&
    advertisement.catalog.last_sequence < 9223372036854775807L else {
    fail("invalid task expiry or sequence")
  }
  {
    request_id,
    sequence: advertisement.catalog.last_sequence + 1L,
    catalog_id: advertisement.catalog.catalog_id,
    context_version: advertisement.catalog.context_version,
    expires_at_ms: advertisement.now_ms + ttl_ms.to_int64(),
    proposal,
  }
}

///|
pub async fn submit(
  url : String,
  request : @skills.Request,
) -> @skills.Execution {
  let (response, body) = @http.post(url + "/v1/skills", Json(request))
  guard response.code == 200 else {
    fail("task request HTTP \{response.code}: \{body.text()}")
  }
  @json.from_json(body.json())
}

///|
pub async fn cancel(url : String, request_id : String) -> @skills.Execution {
  let (response, body) = @http.post(
    url + "/v1/cancel",
    Json({ "request_id": request_id }),
  )
  guard response.code == 200 else {
    fail("task cancellation HTTP \{response.code}")
  }
  @json.from_json(body.json())
}

///|
/// This prompt is model-independent. Sampling/LLM transport remains in LunaFlux
/// and its task coordinator. No model output grants robot control authority.
pub fn planner_prompt(advertisement : Advertisement, task : String) -> String {
  "Select one skill from the supplied catalog for the user's task. Return only a JSON object with exactly skill_id and parameters. Use an existing skill_id and only the parameters and ranges listed for that skill. Do not invent a reference or joint command. If no skill fits, return {\"skill_id\":\"\",\"parameters\":{}}; the coordinator must ask for a new plan.\nCatalog:\n" +
  Json(advertisement.catalog.skills).stringify() +
  "\nUser task:\n" +
  task
}

///|
pub fn parse_proposal(content : String) -> @skills.Proposal raise {
  let json = @json.parse(content)
  guard json is Object(fields) &&
    fields.length() == 2 &&
    fields.contains("skill_id") &&
    fields.contains("parameters") else {
    fail("planner must return only skill_id and parameters")
  }
  @json.from_json(json)
}
