///|
fn required(options : Map[String, String], name : String) -> String raise {
  guard options.get(name) is Some(value) else { fail("required " + name) }
  value
}

///|
fn resolve_library(options : Map[String, String]) -> String raise {
  let selected = match options.get("--library") {
    Some(path) => Some(path)
    None => @env.get_env_var("MOONROBO_MUJOCO_LIBRARY")
  }
  guard selected is Some(path) && path != "" && !path.contains("\u{0}") else {
    fail(
      "native reference entry requires MOONROBO_MUJOCO_LIBRARY; no Python discovery or fallback",
    )
  }
  path
}

///|
async fn main {
  let args = @env.args()
  guard args.length() >= 3 else { fail("REPO ORIGINAL_ENTRY [original flags]") }
  let root = args[1]
  let parts = args[2].split("/").to_array()
  let entry = parts[parts.length() - 1].to_owned()
  let options : Map[String, String] = {}
  let flags : Array[String] = []
  for i = 3; i < args.length(); {
    if args[i] == "--export" {
      flags.push(args[i])
      continue i + 1
    } else {
      guard i + 1 < args.length() && args[i].has_prefix("--") else {
        fail("invalid original option: " + args[i])
      }
      guard !options.contains(args[i]) else {
        fail("duplicate option " + args[i])
      }
      options[args[i]] = args[i + 1]
      continue i + 2
    }
  }
  let source = root + "/src/learning_reference/"
  validate_options(entry, options, flags)
  let library = () => resolve_library(options)
  let study = () => required(options, "--study")
  let output = () => required(options, "--output")
  let scene = () => required(options, "--scene")
  if options.get("--output") is Some(folder) && !flags.contains("--export") {
    archive_sources(root, folder)
  }
  match entry {
    "aligned_export.py" => {
      let report = @artifacts.load_json(required(options, "--report"))
      println(
        @adapters.export_torch_replay(
          required(options, "--checkpoint"),
          required(options, "--checkpoint-sha256"),
          required(options, "--motion-dir"),
          library(),
          scene(),
          expected_identity=@reference.json_field(report, "identity"),
          expected_config=@reference.json_field(report, "config"),
        ).stringify(),
      )
    }
    "reference_learning_probe.py" =>
      println(
        @reference.run_imagination_probe(
          study(),
          options.get("--method").unwrap_or("model-based"),
          @string.parse_int(options.get("--offset").unwrap_or("0")),
        ).stringify(),
      )
    "reference_root_decomposition.py" =>
      println(
        @roots.run_decomposition(
          study(),
          root + "/src/learning_reference_roots/decomposition.mbt",
        ).stringify(),
      )
    "reference_initialization.py" => {
      let feedback = required(options, "--feedback")
      println(
        @reference.run_initialization_study(
          required(options, "--config"),
          required(options, "--quality"),
          required(options, "--references"),
          feedback,
          @reference.load_initialization_feedback(feedback),
          @physics.Runtime::open(library(), scene()),
          output(),
          source + "reference_initialization_study.mbt",
        ).stringify(),
      )
    }
    "reference_learning_study.py" =>
      println(
        @reference.run_learning_study(
          required(options, "--config"),
          required(options, "--quality"),
          required(options, "--references"),
          required(options, "--actor"),
          @physics.Runtime::open(library(), scene()),
          output(),
          source + "reference_learning_study.mbt",
          reuse_study?=options.get("--reuse-study"),
        ).stringify(),
      )
    "reference_last_cycle.py" => {
      let runtime = @physics.Runtime::open(library(), scene())
      let result = if @env.get_env_var("MOONROBO_TORCH_RNG_ADAPTER")
        is Some(adapter) {
        @reference.run_last_cycle(
          required(options, "--source"),
          output(),
          runtime,
          source + "reference_last_cycle_study.mbt",
          legacy_indices=(seed, requests) => {
            let generator = @torch_rng.Generator::open(adapter, seed)
            requests.map(request => generator.indices(request.0, request.1))
          },
        )
      } else {
        @reference.run_last_cycle(
          required(options, "--source"),
          output(),
          runtime,
          source + "reference_last_cycle_study.mbt",
        )
      }
      println(result.stringify())
    }
    "reference_final_route_training.py" =>
      @routes.run_final_route(
        required(options, "--source"),
        library(),
        scene(),
        output(),
      )
    "reference_gradient_route.py" =>
      @routes.run_gradient_route(
        required(options, "--source"),
        library(),
        scene(),
        output(),
      )
    "reference_tail_directions.py" =>
      @routes.run_tail_directions(
        required(options, "--models"),
        library(),
        scene(),
        output(),
      )
    "reference_root_integration.py" =>
      println(
        @roots.run_integration(
          required(options, "--source"),
          library(),
          scene(),
          output(),
          root + "/src/learning_reference_roots/integration.mbt",
        ).stringify(),
      )
    "reference_root_export.py" =>
      @roots.export_stream(study(), library(), scene(), row => {
        println(row.stringify())
      })
    "reference_action_response.py" =>
      if flags.contains("--export") {
        @directions.export_action_response(output(), scene(), library(), row => {
          println(row.stringify())
        })
      } else {
        @directions.run_action_response(
          required(options, "--source"),
          output(),
          scene(),
          library(),
        )
      }
    "reference_feedback_response.py" =>
      @directions.run_feedback_response(
        required(options, "--source"),
        output(),
        scene(),
        library(),
      )
    "reference_feedback_response_export.py" =>
      @directions.export_feedback_response(study(), scene(), library(), row => {
        println(row.stringify())
      })
    "reference_initialization_export.py" =>
      @reference.export_initialization_stream(
        study(),
        required(options, "--references"),
        @physics.Runtime::open(library(), scene()),
        row => println(row.stringify()),
      )
    "reference_learning_export.py"
    | "reference_learning_export-final-verify.py" => {
      let runtime = @physics.Runtime::open(library(), scene())
      let report = @artifacts.load_json(study() + "/report.json")
      let final_route_verified = @reference.json_text(
          @reference.json_field(
            @reference.json_field(report, "config"),
            "format",
          ),
        ) ==
        "moonrobo.g1-reference-final-route-training-charter.v1"
      if final_route_verified {
        ignore(@routes.verify_actor_update_states(study(), library(), scene()))
      }
      if @env.get_env_var("MOONROBO_TORCH_RNG_ADAPTER") is Some(adapter) {
        @reference.export_learning_stream(
          study(),
          runtime,
          row => println(row.stringify()),
          final_route_verified~,
          legacy_normals=(seed, count, width) => {
            let generator = @torch_rng.Generator::open(adapter, seed)
            Array::makei(count, _ => generator.normal(width))
          },
          legacy_indices=(seed, requests) => {
            let generator = @torch_rng.Generator::open(adapter, seed)
            requests.map(request => generator.indices(request.0, request.1))
          },
        )
      } else {
        @reference.export_learning_stream(
          study(),
          runtime,
          row => println(row.stringify()),
          final_route_verified~,
        )
      }
    }
    "reference_registry_export.py" =>
      println(
        @reference.export_initialization_registry(
          study(),
          required(options, "--references"),
          required(options, "--verification"),
          @physics.Runtime::open(library(), scene()),
          output(),
          source + "reference_registry_initialization.mbt",
        ).stringify(),
      )
    "reference_learning_registry_export.py" =>
      println(
        @reference.export_learning_registry(
          study(),
          required(options, "--verification"),
          @physics.Runtime::open(library(), scene()),
          required(options, "--method"),
          output(),
        ).stringify(),
      )
    "full_body_reference_study.py" =>
      println(
        @collection.run(
          library(),
          scene(),
          required(options, "--config"),
          required(options, "--collection"),
          required(options, "--teacher-study"),
          output(),
          teacher_provider_source=root +
            "/src/learning_balance/physics/teacher.mbt",
          teacher_kernel_source=root + "/src/learning_balance/teacher.mbt",
          provider_source=root + "/src/learning_balance/reference_study/run.mbt",
          reference_provider_source=root +
            "/src/learning_balance/physics/reference.mbt",
        ).stringify(),
      )
    _ => fail("unmapped historical entry: " + entry)
  }
  if options.get("--output") is Some(folder) &&
    !flags.contains("--export") &&
    @fs.exists(folder + "/report.json") {
    annotate_report(root, folder, entry)
  }
}
