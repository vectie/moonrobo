///|
pub(all) struct BalanceTrainingData {
  split : String
  joint_names : Array[String]
  lower : Array[Double]
  upper : Array[Double]
  observations : Array[Array[Double]]
  goals : Array[Array[Double]]
  targets : Array[Array[Double]]
  features : Array[Array[Double]]
} derive(Debug, ToJson, FromJson)

///|
pub fn BalanceTrainingData::validate(self : BalanceTrainingData) -> Unit raise {
  let n = self.observations.length()
  let nu = self.joint_names.length()
  guard self.split == "train" &&
    n > 0 &&
    self.goals.length() == n &&
    self.targets.length() == n &&
    self.features.length() == n else {
    fail("balance fitting accepts aligned nonempty training-only points")
  }
  guard self.lower.length() == nu && self.upper.length() == nu else {
    fail("joint limit layout mismatch")
  }
  for i in 0..<n {
    guard self.observations[i].length() == 3 * nu + 6 &&
      self.goals[i].length() == nu &&
      self.targets[i].length() == nu &&
      self.features[i].length() == 6 else {
      fail("balance observation/goal/feature layout differs")
    }
    for
      row in [
        self.observations[i],
        self.goals[i],
        self.targets[i],
        self.features[i],
      ] {
      for v in row {
        guard finite(v) else { fail("nonfinite balance training data") }
      }
    }
  }
}

///|
pub fn LearnedAnkleHead::checkpoint(
  self : LearnedAnkleHead,
  provenance : Json,
) -> @artifacts.Checkpoint {
  @artifacts.Checkpoint::new("learned-balance-head", {
    "head": self.to_json(),
    "provenance": provenance,
    "physical_execution_allowed": false,
    "numeric_precision": "float64",
  })
}

///|
pub fn SustainedBalanceHead::checkpoint(
  self : SustainedBalanceHead,
  provenance : Json,
) -> @artifacts.Checkpoint {
  @artifacts.Checkpoint::new("sustained-balance-head", {
    "head": self.to_json(),
    "provenance": provenance,
    "physical_execution_allowed": false,
    "numeric_precision": "float64",
  })
}

///|
fn checkpoint_head(
  checkpoint : @artifacts.Checkpoint,
  kind : String,
) -> Json raise {
  checkpoint.validate()
  guard checkpoint.model_kind == kind &&
    checkpoint.metadata is Object(fields) &&
    fields.get("head") is Some(head) else {
    fail("expected " + kind + " checkpoint")
  }
  head
}

///|
pub fn learned_from_checkpoint(
  checkpoint : @artifacts.Checkpoint,
) -> LearnedAnkleHead raise {
  @json.from_json(checkpoint_head(checkpoint, "learned-balance-head"))
}

///|
pub fn sustained_from_checkpoint(
  checkpoint : @artifacts.Checkpoint,
) -> SustainedBalanceHead raise {
  @json.from_json(checkpoint_head(checkpoint, "sustained-balance-head"))
}

///|
/// Fit, save and reload a censored OLS feedback head from explicit observation-only features. Stored Python providers remain the reference implementation.
pub async fn run_fit(
  data_path : String,
  output : String,
  sustained : Bool,
  pose_rate~ : Bool = true,
  control_waist~ : Bool = true,
) -> Json {
  let raw = @fs.read_file(data_path).binary()
  let bytes = if data_path.has_suffix(".gz") {
    @artifacts.decompress(raw)
  } else {
    raw
  }
  let data : BalanceTrainingData = @json.from_json(
    @json.parse(@utf8.decode(bytes)),
  )
  data.validate()
  let provenance : Json = {
    "data_path": data_path.to_json(),
    "data_sha256": @artifacts.sha256(raw).to_json(),
    "training_points": data.observations.length().to_json(),
  }
  let report : Json = if sustained {
    let head = SustainedBalanceHead::new(
      data.joint_names,
      data.lower,
      data.upper,
      pose_rate~,
      control_waist~,
    )
    let (ankles, waist) = head.fit(
      data.observations,
      data.goals,
      data.targets,
      data.features,
    )
    let digest = @artifacts.save_checkpoint(output, head.checkpoint(provenance))
    let restored = sustained_from_checkpoint(
      @artifacts.load_checkpoint(output, "sustained-balance-head"),
    )
    guard head.predict(data.observations[0], data.goals[0], data.features[0]) ==
      restored.predict(data.observations[0], data.goals[0], data.features[0]) else {
      fail("sustained balance checkpoint reload differs")
    }
    {
      "joints": ankles.to_json(),
      "waist": waist.to_json(),
      "checkpoint_sha256": digest.to_json(),
    }
  } else {
    let head = LearnedAnkleHead::new(data.joint_names, data.lower, data.upper)
    let inputs = Array::makei(data.observations.length(), fn(i) {
      head.inputs(data.observations[i], data.features[i])
    })
    let joints = head.fit(inputs, data.goals, data.targets)
    let digest = @artifacts.save_checkpoint(output, head.checkpoint(provenance))
    let restored = learned_from_checkpoint(
      @artifacts.load_checkpoint(output, "learned-balance-head"),
    )
    guard head.predict(data.observations[0], data.goals[0], data.features[0]) ==
      restored.predict(data.observations[0], data.goals[0], data.features[0]) else {
      fail("learned balance checkpoint reload differs")
    }
    { "joints": joints.to_json(), "checkpoint_sha256": digest.to_json() }
  }
  let complete : Json = {
    "format": "moonrobo.moonbit-balance-fit.v1",
    "fit": report,
    "reload_matches": true,
    "physical_execution_allowed": false,
    "validation_physics_performed": false,
    "precision": "float64",
    "least_squares": "reorthogonalized QR; full-rank required",
  }
  @fs.write_file(
    output + ".report.json",
    @utf8.encode(complete.stringify()),
    create_mode=CreateOrTruncate,
  )
  complete
}
