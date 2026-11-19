///|
/// Original training-report metric names, independent of the checkpoint format.
pub fn IterationMetrics::report_json(self : IterationMetrics) -> Json {
  let fields : Map[String, Json] = {
    "iteration": self.iteration.to_json(),
    "learning_rate": self.learning_rate.to_json(),
    "actor_readiness": self.actor_readiness.to_json(),
    "actor_readiness_scope": "extra steps lower effective update/data ratio",
    "world_model": {
      "wm_loss": self.world.loss.to_json(),
      "wm_err8": self.world.last_error.to_json(),
      "wm_updates": self.world.updates.to_json(),
    },
  }
  if self.policy is Some(p) {
    fields["policy"] = {
      "pi_loss": p.policy_loss.to_json(),
      "v_loss": p.critic_loss.to_json(),
      "pi_gradnorm": p.gradient_norm.to_json(),
      "imag_rew": p.imagined_reward.to_json(),
      "imag_survival": p.imagined_survival.to_json(),
      "actor_updates": 1,
      "critic_updates": p.critic_updates.to_json(),
      "imagined_steps": p.imagined_steps.to_json(),
      "critic_tail": true,
    }
  }
  Json::object(fields)
}

///|
/// Hash the preserved comparison sources and the native implementation separately.
pub async fn source_provenance(
  python_root : String,
  native_root : String,
) -> (Json, Json) {
  let python : Map[String, Json] = Map([])
  for name in @fs.readdir(python_root, sort=true) {
    if name.has_suffix(".py") {
      python[name] = @artifacts.sha256(
        @fs.read_file(python_root + "/" + name).binary(),
      ).to_json()
    }
  }
  let native : Map[String, Json] = Map([])
  for
    subdir in [
      "", "assets/", "physics/", "cmd/", "usd/", "native/", "gpu_protocol/", "gpu_native/",
      "producer/", "producer/native/", "storage/",
    ] {
    let dir = native_root + "/" + subdir
    for name in @fs.readdir(dir, sort=true) {
      if name.has_suffix(".mbt") ||
        name.has_suffix(".cpp") ||
        name.has_suffix(".c") ||
        name.has_suffix(".cu") ||
        name.has_suffix(".h") ||
        name == "moon.pkg" ||
        name == "CMakeLists.txt" {
        native[subdir + name] = @artifacts.sha256(
          @fs.read_file(dir + name).binary(),
        ).to_json()
      }
    }
  }
  (Json::object(python), Json::object(native))
}

///|
pub fn Learner::training_report(
  self : Learner,
  identity : Json,
  config : Json,
  resume_kind : String,
  iteration : Int32,
  counters : TrainingCounters,
  wall_seconds : Double,
  updates : Array[Json],
  checkpoint_sha256 : String,
  physics_settings : Json,
  python_sources : Json,
  native_sources : Json,
  dependencies : Json,
  initialization? : Json,
) -> Json raise {
  guard finite(wall_seconds) && wall_seconds >= 0.0 else {
    fail("invalid training report wall time")
  }
  let profile = match config {
    Object(fields) => fields.get("profile").unwrap_or(Json::null())
    _ => Json::null()
  }
  {
    "format": "moonrobo.supermimic-aligned-training.v1",
    "profile": profile,
    "identity": identity,
    "config": config,
    "resume_kind": resume_kind.to_json(),
    "iteration": iteration.to_json(),
    "counters": counters.to_json(),
    "wall_seconds_this_invocation": wall_seconds.to_json(),
    "updates": updates.to_json(),
    "result_scope": (if profile == "cpu-smoke".to_json() ||
      profile == "smc-protocol-cpu-check".to_json() {
      "method-integration smoke"
    } else {
      "training"
    }).to_json(),
    "hardware_execution": false,
    "checkpoint_sha256": checkpoint_sha256.to_json(),
    "physics_settings": physics_settings,
    "source_files": python_sources,
    "moonbit_source_files": native_sources,
    "parameters": {
      "wm": self.wm.net.parameters.length().to_json(),
      "pi": (self.policy.encoder.parameters.length() +
      self.policy.decoder.parameters.length()).to_json(),
      "critic": self.critic.net.parameters.length().to_json(),
    },
    "motion_frames": self.motion.states.length().to_json(),
    "dependencies": dependencies,
    "initialization": initialization.unwrap_or(Json::null()),
    "numerical_parity": "MoonBit float64; RNG and reduction order differ from Torch; differential execution deferred",
  }
}
