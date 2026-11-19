///|
/// Uses LunaFlux's outer OpenAI-compatible chat boundary. No model/device
/// implementation or robot SDK is imported by this coordinator adapter.
pub async fn propose(
  endpoint : String,
  model : String,
  advertisement : @task.Advertisement,
  user_task : String,
  headers~ : Map[String, String] = Map([]),
  timeout_ms~ : Int32 = 10000,
  images~ : ReadOnlyArray[ImageObservation] = [],
) -> @skills.Proposal {
  @async.with_timeout(timeout_ms, () => {
    let body : Json = {
      "model": Json(model),
      "stream": false,
      "temperature": 0,
      "max_tokens": 256,
      "messages": [
        {
          "role": "system",
          "content": Json(
            @task.planner_prompt(
              advertisement, "Select a catalog skill for the following user message.",
            ),
          ),
        },
        { "role": "user", "content": user_content(user_task, images[:]) },
      ],
    }
    let bytes = @utf8.encode(body.stringify())
    guard bytes.length() <= (if images.is_empty() { 1048576 } else { 16777216 }) else {
      fail("planner request exceeds LunaFlux HTTP body budget")
    }
    let request_headers : Map[String, String] = Map([])
    for name, value in headers {
      match name.to_lower() {
        "content-length" | "content-type" | "transfer-encoding" => ()
        _ => request_headers[name] = value
      }
    }
    request_headers["Content-Type"] = "application/json"
    request_headers["Content-Length"] = bytes.length().to_string()
    // Request-specific length must go through extra_headers: the convenience
    // post helper treats headers as client defaults and strips Content-Length.
    guard endpoint.find("://") is Some(scheme_end) else {
      fail("invalid LunaFlux endpoint")
    }
    let path_start = match endpoint[scheme_end + 3:].find("/") {
      Some(offset) => scheme_end + 3 + offset
      None => endpoint.length()
    }
    let client = @http.Client(endpoint[:path_start].to_owned())
    defer client.close()
    let response = client.post(
      endpoint[path_start:].to_owned() + "/v1/chat/completions",
      bytes,
      extra_headers=request_headers,
    )
    guard response.code == 200 else {
      fail("LunaFlux planner HTTP \{response.code}")
    }
    guard client.read_all().json()
      is {
        "choices": Array(
          [
            {
              "finish_reason": String("stop"),
              "message": { "content": String(content), .. },
              ..
            },
          ]
        ),
        ..
      } else {
      fail(
        "planner needs one completed text choice; truncated or tool output is not a skill proposal",
      )
    }
    @task.parse_proposal(content)
  })
}

///|
/// Time spent generating a plan does not consume its execution TTL. A changed
/// local control context invalidates the proposal rather than silently rebasing.
pub async fn plan_and_submit(
  task_endpoint : String,
  llm_endpoint : String,
  model : String,
  user_task : String,
  request_id~ : String,
  ttl_ms~ : Int32,
  headers~ : Map[String, String] = Map([]),
  images~ : ReadOnlyArray[ImageObservation] = [],
  timeout_ms~ : Int32 = 10000,
) -> @skills.Execution {
  let before = @task.fetch_catalog(task_endpoint)
  let proposal = propose(
    llm_endpoint,
    model,
    before,
    user_task,
    headers~,
    images~,
    timeout_ms~,
  )
  let after = @task.fetch_catalog(task_endpoint)
  guard before.catalog.catalog_id == after.catalog.catalog_id &&
    before.catalog.context_version == after.catalog.context_version else {
    fail(
      "control context changed while the LLM was planning; request a new plan",
    )
  }
  @task.submit(
    task_endpoint,
    @task.request(after, proposal, request_id~, ttl_ms~),
  )
}
