///|
fn usage() -> String {
  (
    #|MoonRobo MoonFlow adapter
    #|
    #|  moonrobo-adapter capability
    #|  moonrobo-adapter declaration
    #|  moonrobo-adapter readiness <workspace-root> <robobook-ref>
    #|  moonrobo-adapter health <workspace-root> <robobook-ref> <checked-at> <valid-until>
    #|  moonrobo-adapter source-bundle <pack.json> <workspace-root> <robobook-ref> <compiled-at> <valid-until>
    #|  moonrobo-adapter invoke <workspace-root> <robobook-ref> <request.json>
    #|  moonrobo-adapter reconcile <workspace-root> <robobook-ref> <request.json>
    #|  moonrobo-adapter reconcile-report <workspace-root> <robobook-ref> <request.json>
    #|
  )
}

///|
fn arg(args : Array[String], index : Int) -> String? {
  args.get(index)
}

///|
fn command_index(args : Array[String]) -> Int {
  match args.get(0) {
    Some(
      "capability"
      | "declaration"
      | "readiness"
      | "health"
      | "source-bundle"
      | "invoke"
      | "reconcile"
      | "reconcile-report"
      | "help"
    ) => 0
    _ => 1
  }
}

///|
fn print_issue(issue : @adapter_runtime.AdapterRuntimeIssue) -> Unit {
  let payload : Json = {
    "contract_id": "moonrobo.adapter-cli-error.v1",
    "error": issue.to_json(),
  }
  println(payload.stringify(indent=2))
}

///|
fn load_request(
  path : String,
) -> Result[
  @suite_adapter.MoonflowAdapterRequest,
  @adapter_runtime.AdapterRuntimeIssue,
] {
  let text = @fsx.read_file_to_string(path) catch {
    _ =>
      return Err({
        code: "read-adapter-request",
        path,
        message: "failed to read MoonFlow adapter request JSON",
      })
  }
  let json = @json.parse(text) catch {
    _ =>
      return Err({
        code: "parse-adapter-request",
        path,
        message: "failed to parse MoonFlow adapter request JSON",
      })
  }
  try @suite_adapter.decode_moonflow_adapter_request(json) catch {
    error =>
      Err({
        code: "decode-adapter-request",
        path,
        message: "failed to decode MoonFlow adapter request: \{error}",
      })
  } noraise {
    request => Ok(request)
  }
}

///|
fn require_execution_args(
  args : Array[String],
  index : Int,
) -> Result[(String, String, String), @adapter_runtime.AdapterRuntimeIssue] {
  match (arg(args, index + 1), arg(args, index + 2), arg(args, index + 3)) {
    (Some(workspace), Some(robobook), Some(request)) =>
      Ok((workspace, robobook, request))
    _ => Err({ code: "missing-cli-arguments", path: "", message: usage() })
  }
}

///|
fn main {
  let args = @env.args()
  let index = command_index(args)
  let command = arg(args, index).unwrap_or("capability")
  match command {
    "capability" =>
      println(
        @suite_adapter.moonflow_adapter_capability_json().stringify(indent=2),
      )
    "declaration" =>
      println(@suite_adapter.adapter_declaration_json().stringify(indent=2))
    "readiness" =>
      match (arg(args, index + 1), arg(args, index + 2)) {
        (Some(workspace), Some(robobook)) =>
          println(
            @adapter_runtime.readiness(workspace, robobook)
            .to_json()
            .stringify(indent=2),
          )
        _ => {
          println(usage())
          @sys.exit(2)
        }
      }
    "invoke" | "reconcile" | "reconcile-report" =>
      match require_execution_args(args, index) {
        Err(error) => {
          print_issue(error)
          @sys.exit(2)
        }
        Ok((workspace, robobook, request_path)) =>
          match load_request(request_path) {
            Err(error) => {
              print_issue(error)
              @sys.exit(2)
            }
            Ok(request) =>
              if command == "invoke" {
                match @adapter_runtime.invoke(workspace, robobook, request) {
                  Ok(result) => println(result.to_json().stringify(indent=2))
                  Err(error) => {
                    print_issue(error)
                    @sys.exit(3)
                  }
                }
              } else {
                match @adapter_runtime.reconcile(workspace, robobook, request) {
                  Ok(report) =>
                    if command == "reconcile" {
                      println(report.result.to_json().stringify(indent=2))
                    } else {
                      println(report.to_json().stringify(indent=2))
                    }
                  Err(error) => {
                    print_issue(error)
                    @sys.exit(3)
                  }
                }
              }
          }
      }
    "health" =>
      match
        (
          arg(args, index + 1),
          arg(args, index + 2),
          arg(args, index + 3),
          arg(args, index + 4),
        ) {
        (Some(workspace), Some(robobook), Some(checked_at), Some(valid_until)) =>
          match
            @adapter_runtime.health_attestation(
              workspace, robobook, checked_at, valid_until,
            ) {
            Ok(health) => println(health.to_json().stringify(indent=2))
            Err(error) => {
              print_issue(error)
              @sys.exit(3)
            }
          }
        _ => {
          println(usage())
          @sys.exit(2)
        }
      }
    "source-bundle" =>
      match
        (
          arg(args, index + 1),
          arg(args, index + 2),
          arg(args, index + 3),
          arg(args, index + 4),
          arg(args, index + 5),
        ) {
        (
          Some(pack_path),
          Some(workspace),
          Some(robobook),
          Some(compiled_at),
          Some(valid_until),
        ) => {
          let pack_text = @fsx.read_file_to_string(pack_path) catch {
            _ => {
              print_issue({
                code: "read-pack-manifest",
                path: pack_path,
                message: "failed to read MoonRobo pack manifest",
              })
              @sys.exit(2)
              ""
            }
          }
          let pack = @json.parse(pack_text) catch {
            _ => {
              print_issue({
                code: "parse-pack-manifest",
                path: pack_path,
                message: "failed to parse MoonRobo pack manifest",
              })
              @sys.exit(2)
              {}
            }
          }
          match
            @adapter_runtime.capability_source_bundle(
              pack, workspace, robobook, compiled_at, valid_until,
            ) {
            Ok(bundle) => println(bundle.stringify(indent=2))
            Err(error) => {
              print_issue(error)
              @sys.exit(3)
            }
          }
        }
        _ => {
          println(usage())
          @sys.exit(2)
        }
      }
    _ => println(usage())
  }
}
