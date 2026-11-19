///|
/// Historical provider names are inert descriptors. This executable invokes
/// native MoonBit implementations directly, never an interpreter or subprocess.
async fn main {
  let args = @env.args()[1:].to_owned()
  guard args.length() > 0 else { fail("provider descriptor required") }
  let descriptor = args[0].split("/").to_array().last().unwrap().to_owned()
  let required = fn(key) raise { @entry.required(args, key) }
  let root = @entry.option(args, "--repo").unwrap_or(".")
  let source = fn() raise {
    @entry.option(args, "--teacher-provider-source").unwrap_or(
      root + "/src/learning_balance/physics/teacher.mbt",
    )
  }
  if descriptor == "sustained_balance_verify.py" {
    println(@verification.run(required("--study")).stringify())
    return
  }
  let output = required("--output")
  let library = @entry.mujoco_library(args)
  let scene = required("--scene")
  for i in 1..<args.length() {
    if ["--checkpoint", "--dynamics"].contains(args[i - 1]) &&
      args[i].has_suffix(".moon.json") &&
      !@fs.exists(args[i]) {
      let legacy = args[i][:args[i].length() - 10].to_owned() + ".pt"
      if @fs.exists(legacy) {
        args[i] = legacy
      }
    }
  }
  match descriptor {
    "balance_teacher.py" => {
      guard args.length() > 1 else { fail("teacher command required") }
      println(
        @teacher.run(
          library,
          scene,
          required("--experiment"),
          required("--config"),
          output,
          args[1],
          source(),
          teacher_path?=@entry.option(args, "--teacher"),
          diagnostic_case?=@entry.option(args, "--case"),
          diagnostic_seed?=@entry.option(args, "--seed").map(fn(value) raise {
            @string.parse_int(value)
          }),
        ).stringify(),
      )
    }
    "balance_teacher_long.py" | "balance_teacher_long_fit.py" =>
      println(
        @teacher.run_long(
          library,
          scene,
          required("--study"),
          required("--config"),
          output,
          source(),
        ).stringify(),
      )
    "learned_balance_study.py" =>
      @studies.run_learned_study(
        library,
        scene,
        required("--config"),
        required("--collection"),
        required("--experiment"),
        required("--teacher"),
        required("--intervention"),
        required("--policies"),
        output,
      )
    "learned_balance_long.py" =>
      @studies.run_learned_long(
        library,
        scene,
        required("--config"),
        required("--study"),
        output,
      )
    "sustained_balance_study.py" =>
      @studies.run_sustained(
        library,
        scene,
        required("--config"),
        required("--study"),
        required("--teacher-study"),
        output,
      )
    "balance_intervention.py" =>
      println(
        @intervention.run(
          library,
          scene,
          required("--config"),
          required("--collection"),
          required("--experiment"),
          required("--teacher"),
          required("--policies"),
          source(),
          output,
        ).stringify(),
      )
    "balance_long_intervention.py" =>
      println(
        @intervention.run_long(
          library,
          scene,
          required("--config"),
          required("--study"),
          required("--long"),
          source(),
          output,
        ).stringify(),
      )
    "balance_feature_study.py" =>
      println(
        @features.run(
          library,
          scene,
          required("--config"),
          required("--teacher"),
          required("--intervention"),
          required("--experiment"),
          required("--policies"),
          source(),
          output,
        ).stringify(),
      )
    "temporal_refinement.py" | "temporal_value_training.py" =>
      if descriptor == "temporal_refinement.py" {
        @refinement.run_refinement(
          library,
          scene,
          required("--config"),
          required("--experiment"),
          required("--collection"),
          required("--data"),
          required("--policies"),
          required("--dynamics"),
          output,
        )
      } else {
        @refinement.run_value_training(
          library,
          scene,
          required("--config"),
          required("--experiment"),
          required("--collection"),
          required("--data"),
          required("--policies"),
          required("--dynamics"),
          output,
        )
      }
    "temporal_ppo_noise.py" =>
      println(
        @calibration.calibrate_noise(
          library,
          scene,
          required("--config"),
          required("--collection"),
          required("--policies"),
          output,
        ).stringify(),
      )
    "temporal_ppo_verification.py" =>
      println(
        @ppo_verification.verify(
          required("--study"),
          required("--incoming"),
          library,
          scene,
          output,
        ).stringify(),
      )
    "temporal_probe.py" | "replay_direction_probe.py" => {
      let options : Map[String, String] = Map([])
      let mut i = 1
      while i < args.length() {
        guard args[i].has_prefix("--") && i + 1 < args.length() else {
          fail("expected option value pair")
        }
        guard !options.contains(args[i]) else {
          fail("duplicate native option")
        }
        options[args[i]] = args[i + 1]
        i += 2
      }
      options["--library"] = library
      if descriptor == "temporal_probe.py" {
        @probes.run_temporal_probe(options)
      } else {
        @probes.run_replay_direction(options)
      }
    }
    "temporal_training.py" =>
      @temporal.run_supervised_study(args, library, scene, source())
    "temporal_disturbance.py" =>
      @temporal.run_disturbance_study(args, library, scene, source())
    "temporal_ppo.py" => @temporal.run_ppo_study(args, library, scene)
    _ => fail("unsupported native provider descriptor: " + descriptor)
  }
}
