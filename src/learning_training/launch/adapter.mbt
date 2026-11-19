///|
/// This is an explicit descriptor-to-native-API adapter. A retained .py name selects a reviewed implementation; no Python executable or dynamic fallback exists.
fn required(options : Map[String, String], key : String) -> String raise {
  guard options.get(key) is Some(value) else {
    fail("required native option: " + key)
  }
  value
}

///|
/// Existing original weight files remain readable; new runs write native .moon.json. Prefer the exact supplied file, then the counterpart suffix, never fabricate a checkpoint.
async fn resolve_checkpoint(path : String) -> String {
  if @fs.exists(path) {
    return path
  }
  let alternate = if path.has_suffix(".moon.json") {
    path[:path.length() - 10].to_owned() + ".pt"
  } else if path.has_suffix(".pt") {
    path[:path.length() - 3].to_owned() + ".moon.json"
  } else {
    return path
  }
  if @fs.exists(alternate) {
    alternate
  } else {
    path
  }
}

///|
fn library(options : Map[String, String]) -> String raise {
  match options.get("--library") {
    Some(value) => value
    None =>
      match @env.get_env_var("MOONROBO_MUJOCO_LIBRARY") {
        Some(value) if !value.is_empty() => value
        _ =>
          fail(
            "native MuJoCo requires --library or MOONROBO_MUJOCO_LIBRARY; no interpreter-based discovery",
          )
      }
  }
}

///|
pub async fn run(arguments : Array[String]) -> Unit {
  guard !arguments.is_empty() else {
    fail("native provider descriptor is required")
  }
  guard arguments[0] != "-m" else {
    fail(
      "automatic unittest execution is deferred; this launcher never runs Python or tests",
    )
  }
  if arguments[0] == "checkpoint-copy" {
    guard arguments.length() == 4 else {
      fail("checkpoint-copy SOURCE DESTINATION KIND")
    }
    println(
      copy_checkpoint(arguments[1], arguments[2], arguments[3]).stringify(),
    )
    return
  }
  let descriptor = arguments[0].split("/").last().unwrap_or("").to_owned()
  let (operation, start) = if arguments.length() > 1 &&
    !arguments[1].has_prefix("--") {
    (arguments[1], 2)
  } else {
    ("", 1)
  }
  let options : Map[String, String] = {}
  for i = start; i < arguments.length(); i = i + 2 {
    guard arguments[i].has_prefix("--") &&
      i + 1 < arguments.length() &&
      !options.contains(arguments[i]) else {
      fail("expected unique native --option value pairs")
    }
    let value = arguments[i + 1]
    options[arguments[i]] = if [
        "--checkpoint", "--dynamics", "--initial", "--corrected", "--actor",
      ].contains(arguments[i]) {
      resolve_checkpoint(value)
    } else {
      value
    }
  }
  fn option(key : String) -> String raise {
    required(options, key)
  }
  let allowed = match descriptor {
    "policy.py" =>
      match operation {
        "fit" =>
          [
            "--train", "--dynamics", "--scene", "--config", "--experiment", "--output",
            "--warm-start-policy", "--policy-replay", "--library",
          ]
        "collect" =>
          [
            "--checkpoint", "--scene", "--experiment", "--output", "--split", "--library",
          ]
        "evaluate" =>
          [
            "--checkpoint", "--scene", "--config", "--experiment", "--output", "--library",
          ]
        _ => []
      }
    "dynamics.py" =>
      ["--train", "--validation", "--test", "--config", "--output"]
    "dynamic_refit.py" =>
      [
        "--config", "--manifest", "--initial", "--validation", "--test", "--output",
      ]
    "ppo.py" =>
      [
        "--train", "--scene", "--config", "--experiment", "--evaluation-experiment",
        "--output", "--warm-start-policy", "--library",
      ]
    "behavior_cloning.py" =>
      [
        "--train", "--scene", "--config", "--experiment", "--output", "--library",
      ]
    "dataset_aggregation.py" =>
      [
        "--train", "--scene", "--config", "--experiment", "--output", "--policies",
        "--teacher", "--collection", "--library",
      ]
    "counterfactual.py" =>
      [
        "--policies", "--scene", "--config", "--experiment", "--output", "--library",
      ]
    "cpu_physics.py" => ["--scene", "--experiment", "--output", "--library"]
    "compare_dynamics.py" =>
      ["--initial", "--corrected", "--validation", "--test", "--output"]
    "model_probe.py" =>
      [
        "--initial", "--corrected", "--actor", "--scene", "--config", "--experiment",
        "--output", "--library",
      ]
    "critic_probe.py" =>
      [
        "--policies", "--scene", "--config", "--experiment", "--output", "--library",
      ]
    "actor_update_probe.py" =>
      [
        "--train", "--dynamics", "--policies", "--scene", "--config", "--experiment",
        "--output", "--library",
      ]
    "paired_model_probe.py" =>
      [
        "--train", "--initial", "--adapted", "--policies", "--scene", "--config",
        "--experiment", "--output", "--library",
      ]
    "dynamic_refit_probe.py" =>
      [
        "--probe", "--initial", "--study", "--policies", "--scene", "--output", "--library",
      ]
    "teacher_step_verification.py" =>
      ["--study", "--incoming", "--probe", "--output"]
    "replay_direction_probe.py" =>
      [
        "--config", "--probe-config", "--collection", "--data", "--dynamics", "--policies",
        "--study", "--scene", "--output", "--library",
      ]
    _ => []
  }
  guard descriptor == "policy.py" || operation == "" else {
    fail("unexpected native positional operation: " + operation)
  }
  for key, _ in options {
    guard allowed.contains(key) else {
      fail("unsupported native option for " + descriptor + ": " + key)
    }
  }
  match descriptor {
    "dynamics.py" =>
      @training.run_dynamics(
        option("--train"),
        option("--validation"),
        option("--test"),
        option("--config"),
        option("--output"),
      )
    "dynamic_refit.py" =>
      @training.run_refit(
        option("--config"),
        option("--manifest"),
        option("--initial"),
        option("--validation"),
        option("--test"),
        option("--output"),
      )
    "policy.py" =>
      match operation {
        "fit" =>
          @physics.run_policy(
            option("--train"),
            option("--dynamics"),
            library(options),
            option("--scene"),
            option("--config"),
            option("--experiment"),
            option("--output"),
            warm_start_directory?=options.get("--warm-start-policy"),
            policy_replay_path?=options.get("--policy-replay"),
          )
        "collect" =>
          println(
            @physics.collect_checkpoint(
              library(options),
              option("--scene"),
              option("--checkpoint"),
              option("--experiment"),
              option("--output"),
              split=options.get("--split").unwrap_or("train"),
            ).stringify(),
          )
        "evaluate" =>
          println(
            @physics.evaluate_checkpoint(
              library(options),
              option("--scene"),
              option("--checkpoint"),
              option("--config"),
              option("--experiment"),
              option("--output"),
            ).stringify(),
          )
        _ => fail("native policy descriptor requires fit, collect or evaluate")
      }
    "ppo.py" =>
      @physics.run_ppo(
        option("--train"),
        library(options),
        option("--scene"),
        option("--config"),
        option("--experiment"),
        option("--evaluation-experiment"),
        option("--output"),
        warm_start_directory?=options.get("--warm-start-policy"),
      )
    "behavior_cloning.py" =>
      @physics.run_supervised(
        option("--train"),
        library(options),
        option("--scene"),
        option("--config"),
        option("--experiment"),
        option("--output"),
      )
    "dataset_aggregation.py" =>
      @physics.run_supervised(
        option("--train"),
        library(options),
        option("--scene"),
        option("--config"),
        option("--experiment"),
        option("--output"),
        policies_directory=option("--policies"),
        teacher_path=option("--teacher"),
        collection_path=option("--collection"),
      )
    "counterfactual.py" =>
      @physics.run_counterfactual(
        library(options),
        option("--scene"),
        option("--config"),
        option("--experiment"),
        option("--policies"),
        option("--output"),
      )
    "compare_dynamics.py" =>
      println(
        @comparison.run(
          option("--initial"),
          option("--corrected"),
          option("--validation"),
          option("--test"),
          option("--output"),
        ).stringify(),
      )
    "cpu_physics.py" => {
      options["--library"] = library(options)
      let args = [
        "run", "--quiet", "--warn-list", "-a", "--target", "native", "src/learning_physics/cli",
        "--",
      ]
      for key, value in options {
        args.append([key, value])
      }
      let (code, out, err) = @process.collect_output("moon", args)
      guard code == 0 else { fail(err.text() + out.text()) }
      println(out.text())
    }
    "model_probe.py"
    | "critic_probe.py"
    | "actor_update_probe.py"
    | "paired_model_probe.py"
    | "dynamic_refit_probe.py"
    | "replay_direction_probe.py"
    | "teacher_step_verification.py" => {
      if descriptor != "teacher_step_verification.py" {
        options["--library"] = library(options)
      }
      match descriptor {
        "model_probe.py" => @probes.run_model(options)
        "critic_probe.py" => @probes.run_critic(options)
        "actor_update_probe.py" => @probes.run_actor(options)
        "paired_model_probe.py" => @probes.run_actor(options, paired=true)
        "dynamic_refit_probe.py" => @probes.run_dynamic_refit(options)
        "replay_direction_probe.py" => @probes.run_replay_direction(options)
        _ => @probes.run_teacher_verification(options)
      }
    }
    _ =>
      fail(
        "no reviewed native implementation for provider descriptor: " +
        descriptor,
      )
  }
}
