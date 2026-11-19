///|
async fn main {
  let args = @env.args()
  if args.length() == 7 && args[1] == "last-cycle" {
    let runtime = @physics.Runtime::open(args[4], args[5])
    let result = if @env.get_env_var("MOONROBO_TORCH_RNG_ADAPTER")
      is Some(adapter) {
      @reference.run_last_cycle(args[2], args[3], runtime, args[6], legacy_indices=(
        seed,
        requests,
      ) => {
        let generator = @torch_rng.Generator::open(adapter, seed)
        requests.map(request => generator.indices(request.0, request.1))
      })
    } else {
      @reference.run_last_cycle(args[2], args[3], runtime, args[6])
    }
    println(result.stringify())
    return
  }
  if args.length() == 5 && args[1] == "probe" {
    let offset = @string.parse_int(args[4])
    println(
      @reference.run_imagination_probe(args[2], args[3], offset).stringify(),
    )
    return
  }
  if args.length() == 5 && args[1] == "learning-export" {
    let runtime = @physics.Runtime::open(args[3], args[4])
    let report = @artifacts.load_json(args[2] + "/report.json")
    let final_route_verified = @reference.json_text(
        @reference.json_field(@reference.json_field(report, "config"), "format"),
      ) ==
      "moonrobo.g1-reference-final-route-training-charter.v1"
    if final_route_verified {
      ignore(@routes.verify_actor_update_states(args[2], args[3], args[4]))
    }
    if @env.get_env_var("MOONROBO_TORCH_RNG_ADAPTER") is Some(adapter) {
      @reference.export_learning_stream(
        args[2],
        runtime,
        row => println(row.stringify()),
        legacy_normals=(seed, count, width) => {
          let generator = @torch_rng.Generator::open(adapter, seed)
          Array::makei(count, _ => generator.normal(width))
        },
        legacy_indices=(seed, requests) => {
          let generator = @torch_rng.Generator::open(adapter, seed)
          requests.map(request => generator.indices(request.0, request.1))
        },
        final_route_verified~,
      )
    } else {
      @reference.export_learning_stream(
        args[2],
        runtime,
        row => println(row.stringify()),
        final_route_verified~,
      )
    }
    return
  }
  if args.length() == 6 && args[1] == "initialization-export" {
    let runtime = @physics.Runtime::open(args[4], args[5])
    @reference.export_initialization_stream(args[2], args[3], runtime, row => {
      println(row.stringify())
    })
    return
  }
  guard args.length() == 4 && args[1] == "consistency" else {
    fail(
      "usage: moon run --target native cmd/reference_diagnostics -- consistency STUDY PROVIDER_SOURCE.mbt",
    )
  }
  println(@reference.run_model_consistency(args[2], args[3]).stringify())
}
