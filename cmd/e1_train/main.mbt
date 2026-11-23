///|
fn option(args : Array[String], name : String) -> String? raise {
  let indices = []
  for i, value in args {
    if value == name {
      indices.push(i)
    }
  }
  guard indices.length() <= 1 else { fail("duplicate option: " + name) }
  match indices.get(0) {
    None => None
    Some(i) => {
      guard args.get(i + 1) is Some(value) && !value.has_prefix("--") else {
        fail("missing option value: " + name)
      }
      Some(value)
    }
  }
}

///|
fn required(args : Array[String], name : String) -> String raise {
  guard option(args, name) is Some(value) else { fail("required: " + name) }
  value
}

///|
async fn main {
  let args = @env.args()
  guard args.length() >= 2 else {
    fail(
      "usage: e1-train <prepare|prepare-bones-supplement|prepare-qualified|prepare-locomotion|prepare-moving-locomotion|validate-model|config|train|export|export-lunakine|export-lunakine-reference|compare-lunakine|shadow-lunakine|shadow-portable|serve-shadow-lunakine|serve-shadow-portable|evaluate|evaluate-lunakine|evaluate-portable|benchmark|benchmark-panel|compare-panel|orientation-panel|orientation-controls|arm-ik-study|trace-panel|inspect|retarget|retarget-legacy> [--option VALUE]",
    )
  }
  let command = args[1]
  let allowed = [
    "--lab-assets", "--output", "--joints", "--profile", "--dataset", "--tensor-library",
    "--library", "--config", "--iterations", "--device", "--resume", "--checkpoint",
    "--actor", "--split", "--clip-indices", "--g1-scene", "--g1-csv", "--fps", "--model-validation",
    "--g1-directory", "--diagnostic", "--evaluate-every", "--training-dataset", "--initialize-from",
    "--panel", "--comparison-actor", "--panel-bind", "--selection", "--record-poses",
    "--record-workflow", "--recorded", "--arm-orientation", "--record-references",
    "--geometry", "--cases", "--controls", "--bones-directory", "--bundle", "--ascend-library",
    "--model", "--task-bind", "--clip-id",
  ]
  for i = 2; i < args.length(); i = i + 2 {
    guard allowed.contains(args[i]) && args.get(i + 1) is Some(_) else {
      fail("unknown or incomplete E1 argument: " + args[i])
    }
  }
  let arms : @e1.ArmOrientation = match option(args, "--arm-orientation") {
    None | Some("original") => Original
    Some("shoulders") => Shoulders
    Some("elbows") => Elbows
    Some("both") => ShouldersAndElbows
    Some("arms-only") => ArmsOnly
    Some("arms-guarded") => ArmsGuarded
    _ =>
      fail(
        "--arm-orientation expects original, shoulders, elbows, both, arms-only or arms-guarded",
      )
  }
  let result = match command {
    "policy-tracking-study" =>
      @e1.policy_tracking_study(
        required(args, "--dataset"),
        required(args, "--library"),
        required(args, "--cases"),
        required(args, "--recorded"),
        required(args, "--output"),
      )
    "prepare-reembodied" =>
      @e1.prepare_reembodied(
        required(args, "--training-dataset"),
        required(args, "--dataset"),
        required(args, "--lab-assets"),
        required(args, "--library"),
        required(args, "--g1-directory"),
        required(args, "--bones-directory"),
        required(args, "--g1-scene"),
        required(args, "--model-validation"),
        required(args, "--output"),
      )
    "prepare-arm-finetune" =>
      @e1.prepare_arm_finetune(
        required(args, "--training-dataset"),
        required(args, "--library"),
        required(args, "--g1-directory"),
        required(args, "--bones-directory"),
        required(args, "--g1-scene"),
        required(args, "--output"),
      )
    "arm-ik-study" =>
      @e1.arm_ik_study(
        required(args, "--training-dataset"),
        required(args, "--library"),
        required(args, "--cases"),
        required(args, "--recorded"),
        required(args, "--geometry"),
        required(args, "--panel"),
        required(args, "--output"),
      )
    "orientation-controls" =>
      @e1.orientation_controls(
        required(args, "--training-dataset"),
        required(args, "--library"),
        required(args, "--geometry"),
        required(args, "--recorded"),
        required(args, "--cases"),
        required(args, "--controls"),
        required(args, "--output"),
      )
    "orientation-panel" =>
      @e1.orientation_panel(
        required(args, "--training-dataset"),
        required(args, "--library"),
        required(args, "--g1-scene"),
        required(args, "--g1-directory"),
        required(args, "--panel"),
        required(args, "--recorded"),
        required(args, "--output"),
      )
    "prepare-bones-supplement" =>
      @e1.prepare_bones_supplement(
        required(args, "--dataset"),
        required(args, "--library"),
        required(args, "--g1-directory"),
        required(args, "--g1-scene"),
        required(args, "--selection"),
        required(args, "--panel"),
        required(args, "--output"),
      )
    "benchmark-panel" | "compare-panel" | "trace-panel" | "heldout-panel" =>
      @e1.benchmark_panel(
        required(args, "--training-dataset"),
        required(args, "--tensor-library"),
        required(args, "--library"),
        required(args, "--g1-scene"),
        required(args, "--g1-directory"),
        required(args, "--panel"),
        required(args, "--actor"),
        required(args, "--output"),
        g1_checkpoint?=if command == "compare-panel" {
          Some(required(args, "--checkpoint"))
        } else {
          None
        },
        arms~,
        external_holdout=command == "heldout-panel",
        record_references=match option(args, "--record-references") {
          None | Some("false") => false
          Some("true") => true
          _ => fail("--record-references must be true or false")
        },
        record_workflow=match option(args, "--record-workflow") {
          None | Some("false") => false
          Some("true") => true
          _ => fail("--record-workflow must be true or false")
        },
        record_poses=match option(args, "--record-poses") {
          None | Some("false") => false
          Some("true") => true
          _ => fail("--record-poses must be true or false")
        },
        comparison_actor?=option(args, "--comparison-actor"),
        legacy_zero_bind=match
          option(args, "--panel-bind").unwrap_or("anatomical") {
          "anatomical" => false
          "legacy-zero" => true
          _ => fail("--panel-bind must be anatomical or legacy-zero")
        },
        trace_indices?=if command == "trace-panel" {
          Some(@json.from_json(@json.parse(required(args, "--clip-indices"))))
        } else {
          None
        },
      )
    "prepare-qualified" | "prepare-locomotion" | "prepare-moving-locomotion" =>
      @e1.prepare_qualified(
        required(args, "--dataset"),
        if command == "prepare-qualified" {
          required(args, "--lab-assets")
        } else {
          ""
        },
        required(args, "--library"),
        required(args, "--model-validation"),
        required(args, "--g1-directory"),
        required(args, "--g1-scene"),
        required(args, "--output"),
        locomotion=command != "prepare-qualified",
        moving=command == "prepare-moving-locomotion",
      )
    "validate-model" =>
      @e1.validate_model(
        required(args, "--lab-assets"),
        required(args, "--library"),
        required(args, "--dataset"),
        required(args, "--output"),
      ) catch {
        @sim.PhysicsError::Invalid(message) => fail(message)
        error => raise error
      }
    "prepare" =>
      @e1.prepare(
        required(args, "--lab-assets"),
        required(args, "--output"),
        joints=@string.parse_int(option(args, "--joints").unwrap_or("23")),
      )
    "config" => {
      let config = match option(args, "--profile").unwrap_or("smoke") {
        "smoke" => @e1.Config::smoke()
        "training" => @e1.Config::training()
        "method-gate" => @e1.Config::method_gate()
        _ => fail("config profile must be smoke, method-gate or training")
      }
      let value = Json(config)
      @fs.write_file(
        required(args, "--output"),
        @utf8.encode(value.stringify(indent=2)),
        create_mode=CreateNew,
      )
      value
    }
    "inspect" => Json(@e1.open_dataset(required(args, "--dataset")))
    "retarget" | "retarget-legacy" =>
      @e1.retarget_file(
        required(args, "--dataset"),
        required(args, "--library"),
        required(args, "--g1-scene"),
        required(args, "--g1-csv"),
        @string.parse_double(required(args, "--fps")),
        required(args, "--output"),
        arms~,
        legacy_positional=command == "retarget-legacy",
      )
    "train" => {
      let config : @e1.Config = @json.from_json(
        @json.parse(
          @utf8.decode(@e1.read_bounded(required(args, "--config"), 1048576L)),
        ),
      )
      @e1.train(
        required(args, "--dataset"),
        required(args, "--tensor-library"),
        required(args, "--library"),
        config,
        required(args, "--output"),
        iterations=@string.parse_int(required(args, "--iterations")),
        device=@string.parse_int(option(args, "--device").unwrap_or("-1")),
        resume=option(args, "--resume"),
        initialize_from?=option(args, "--initialize-from"),
        diagnostic=option(args, "--diagnostic").unwrap_or("false") == "true",
        evaluate_every=@string.parse_int(
          option(args, "--evaluate-every").unwrap_or("500"),
        ),
      )
    }
    "serve-shadow-lunakine" | "serve-shadow-portable" => {
      let actor = if command == "serve-shadow-lunakine" {
        @e1.load_lunakine_actor(
          required(args, "--bundle"),
          required(args, "--ascend-library"),
          required(args, "--model"),
        )
      } else {
        @e1.load_portable_reference(required(args, "--bundle"))
      }
      @e1.serve_actor_shadow(
        actor,
        required(args, "--recorded"),
        required(args, "--task-bind"),
      )
      Json::null()
    }
    "shadow-lunakine" | "shadow-portable" => {
      let actor = if command == "shadow-lunakine" {
        @e1.load_lunakine_actor(
          required(args, "--bundle"),
          required(args, "--ascend-library"),
          required(args, "--model"),
        )
      } else {
        @e1.load_portable_reference(required(args, "--bundle"))
      }
      @e1.replay_deployed_actor(
        actor,
        required(args, "--recorded"),
        required(args, "--output"),
      )
    }
    "evaluate-lunakine" | "evaluate-portable" => {
      let actor = if command == "evaluate-lunakine" {
        @e1.load_lunakine_actor(
          required(args, "--bundle"),
          required(args, "--ascend-library"),
          required(args, "--model"),
        )
      } else {
        @e1.load_portable_reference(required(args, "--bundle"))
      }
      @e1.evaluate_deployed_actor(
        actor,
        required(args, "--dataset"),
        required(args, "--library"),
        required(args, "--output"),
        backend=if command == "evaluate-lunakine" {
          "lunakine-ascend"
        } else {
          "portable-reference"
        },
        split=option(args, "--split").unwrap_or("validation"),
        clip_indices?=option(args, "--clip-indices").map(s => {
          @json.from_json(@json.parse(s))
        }),
      )
    }
    "compare-lunakine" =>
      @e1.compare_lunakine(
        required(args, "--actor"),
        required(args, "--tensor-library"),
        required(args, "--bundle"),
        required(args, "--output"),
      )
    "export-lunakine-reference" =>
      @e1.export_lunakine_reference(
        required(args, "--dataset"),
        required(args, "--bundle"),
        required(args, "--clip-id"),
        required(args, "--output"),
        split=option(args, "--split").unwrap_or("validation"),
      )
    "export-lunakine" =>
      @e1.export_lunakine(
        required(args, "--actor"),
        required(args, "--tensor-library"),
        required(args, "--output"),
      )
    "export" =>
      @e1.export_actor(
        required(args, "--checkpoint"),
        required(args, "--tensor-library"),
        required(args, "--output"),
      )
    "evaluate" | "benchmark" =>
      @e1.evaluate(
        required(args, "--actor"),
        required(args, "--dataset"),
        required(args, "--tensor-library"),
        required(args, "--library"),
        required(args, "--output"),
        split=option(args, "--split").unwrap_or("validation"),
        training_dataset?=if command == "benchmark" {
          Some(required(args, "--training-dataset"))
        } else {
          None
        },
        clip_indices=match option(args, "--clip-indices") {
          None => None
          Some(value) => Some(@json.from_json(@json.parse(value)))
        },
      )
    _ => fail("unknown E1 command: " + command)
  }
  println(result.stringify())
}
