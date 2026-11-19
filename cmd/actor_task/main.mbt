///|
async fn main {
  let args = @env.args()
  match args[1:] {
    ["serve", catalog_path, bind] => {
      let config : @skills.Catalog = @json.from_json(
        @fs.read_file(catalog_path).json(),
      )
      let supervisor = @skills.Supervisor::new(config.catalog_id, config.skills)
      let service = @task.Service::new(supervisor, () => {
        @env.now().reinterpret_as_int64()
      })
      let server = @http.Server(@socket.Addr::parse(bind))
      defer server.close()
      println(
        "Task service at \{server.addr}; standalone catalog/status only, no actor or robot writer",
      )
      service.serve(server)
    }
    ["catalog", url] =>
      println(Json(@task.fetch_catalog(url)).stringify(indent=2))
    ["prompt", url, task] =>
      println(@task.planner_prompt(@task.fetch_catalog(url), task))
    ["submit", url, proposal_path, request_id, ttl] => {
      let advertisement = @task.fetch_catalog(url)
      let proposal = @task.parse_proposal(@fs.read_file(proposal_path).text())
      let request = @task.request(
        advertisement,
        proposal,
        request_id~,
        ttl_ms=@string.parse_int(ttl),
      )
      println(Json(@task.submit(url, request)).stringify(indent=2))
    }
    ["cancel", url, request_id] =>
      println(Json(@task.cancel(url, request_id)).stringify(indent=2))
    ["plan", url, llm, model, task, request_id, ttl] => {
      let headers : Map[String, String] = Map([])
      if @env.get_env_var("LUNAFLUX_API_KEY") is Some(key) {
        headers["Authorization"] = "Bearer " + key
      }
      println(
        Json(
          @planner.plan_and_submit(
            url,
            llm,
            model,
            task,
            request_id~,
            ttl_ms=@string.parse_int(ttl),
            headers~,
          ),
        ).stringify(indent=2),
      )
    }
    ["plan-images", url, llm, model, task, request_id, ttl, .. paths] => {
      guard !paths.is_empty() && paths.length() <= 8 else {
        fail("plan-images requires one to eight PNG/JPEG files")
      }
      let images = []
      for path in paths {
        images.push(read_planner_image(path, "view-\{images.length() + 1}"))
      }
      let headers : Map[String, String] = Map([])
      if @env.get_env_var("LUNAFLUX_API_KEY") is Some(key) {
        headers["Authorization"] = "Bearer " + key
      }
      println(
        Json(
          @planner.plan_and_submit(
            url,
            llm,
            model,
            task,
            request_id~,
            ttl_ms=@string.parse_int(ttl),
            images=ReadOnlyArray::from_array(images),
            headers~,
            timeout_ms=30000,
          ),
        ).stringify(indent=2),
      )
    }
    _ =>
      fail(
        "usage: actor_task serve CATALOG.json IP:PORT | catalog URL | prompt URL TASK | submit URL PROPOSAL.json REQUEST_ID TTL_MS | cancel URL REQUEST_ID | plan TASK_URL LLM_URL MODEL TASK REQUEST_ID TTL_MS | plan-images TASK_URL LLM_URL MODEL TASK REQUEST_ID TTL_MS IMAGE...",
      )
  }
}

///|
async fn read_planner_image(
  path : String,
  source : String,
) -> @planner.ImageObservation {
  let file = @fs.open(path, mode=ReadOnly)
  defer file.close()
  let size = file.size()
  guard size > 0L && size <= 8388608L else {
    fail("image file exceeds planner budget")
  }
  @planner.ImageObservation::from_encoded(
    file.read_exactly(size.to_int()),
    source~,
  )
}
