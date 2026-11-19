///|
fn archive_tensor(
  shape : Array[Int32],
  values : Array[Double],
) -> @artifacts.NumericArray {
  { shape, values, dtype: "<f8", }
}

///|
fn matrix_tensor(rows : Array[Array[Double]]) -> @artifacts.NumericArray {
  guard !rows.is_empty() else { abort("cannot archive an empty matrix") }
  let values : Array[Double] = []
  for row in rows {
    guard row.length() == rows[0].length() else {
      abort("ragged matrix archive")
    }
    values.append(row)
  }
  archive_tensor([rows.length(), rows[0].length()], values)
}

///|
pub fn ReferenceArchive::native_reference(
  self : ReferenceArchive,
  runtime : @physics.Runtime,
  dt : Double,
) -> @balance_native.NativeReference raise {
  let state = self.matrix("state")
  let integration = self.matrix("integration")
  let positions = self.arrays["body_position"]
  let rotations = self.arrays["body_rotation"]
  let quaternions = self.arrays["body_quaternion"]
  let bodies = positions.shape[1]
  let frames = Array::makei(state.length(), i => {
    (
      {
        state: state[i],
        integration: integration[i],
        body_position: Array::makei(bodies, b => {
          positions.values[(i * bodies + b) * 3:(i * bodies + b + 1) * 3].to_owned()
        }),
        body_rotation: Array::makei(bodies, b => {
          rotations.values[(i * bodies + b) * 9:(i * bodies + b + 1) * 9].to_owned()
        }),
        body_quaternion: Array::makei(bodies, b => {
          quaternions.values[(i * bodies + b) * 4:(i * bodies + b + 1) * 4].to_owned()
        }),
        contacts: self.arrays["contacts"].values[i].to_int(),
        time: self.arrays["time_s"].values[i],
      } : @balance_native.ReferenceFrame)
  })
  @balance_native.NativeReference::new(
    runtime,
    frames,
    self.matrix("source_setpoint"),
    self.matrix("observation"),
    dt,
  )
}

///|
fn episode_arrays(
  episode : @physics.Episode,
) -> Map[String, @artifacts.NumericArray] {
  let steps = episode.steps
  {
    "state": matrix_tensor(steps.map(step => step.state)),
    "observation": matrix_tensor(steps.map(step => step.observation)),
    "applied_action": matrix_tensor(steps.map(step => step.applied_action)),
    "next_state": matrix_tensor(steps.map(step => step.next_state)),
    "reward": archive_tensor([steps.length()], steps.map(step => step.reward)),
    "terminated": archive_tensor(
      [steps.length()],
      steps.map(step => if step.terminated { 1.0 } else { 0.0 }),
    ),
    "truncated": archive_tensor(
      [steps.length()],
      steps.map(step => if step.truncated { 1.0 } else { 0.0 }),
    ),
  }
}

///|
pub fn summarize_tracking(trials : Array[Json]) -> Json raise {
  guard !trials.is_empty() else { fail("empty tracking summary") }
  let mut steps = 0
  let mut falls = 0
  let mut seconds = 0.0
  for trial in trials {
    steps += json_integer(json_field(trial, "steps"))
    if json_boolean(json_field(trial, "failed")) {
      falls += 1
    }
    seconds += json_number(json_field(trial, "simulated_seconds"))
  }
  guard steps > 0 else { fail("no physical tracking steps") }
  let result : Map[String, Json] = {
    "trials": trials.length().to_json(),
    "falls": falls.to_json(),
    "steps": steps.to_json(),
    "mean_survival_s": (seconds / trials.length().to_double()).to_json(),
  }
  for
    metric in [
      "joint_rmse_rad", "body_position_rmse_m", "root_position_rmse_m", "root_orientation_rmse_rad",
    ] {
    let mut total = 0.0
    for trial in trials {
      let x = json_number(json_field(trial, metric))
      total += x * x * json_integer(json_field(trial, "steps")).to_double()
    }
    result[metric] = (total / steps.to_double()).sqrt().to_json()
  }
  result.to_json()
}

///|
pub fn assess_tracking_quality(
  trials : Array[Json],
  config : Json,
) -> Json raise {
  let dt = json_number(json_field(config, "dt_s"))
  let expected : Map[(String, Int32), Bool] = Map([])
  for id in json_array(json_field(config, "reference_ids")) {
    for origin in json_array(json_field(config, "origins_s")) {
      expected[(json_text(id), @math.round(json_number(origin) / dt).to_int())] = true
    }
  }
  let seen : Map[(String, Int32), Bool] = Map([])
  let limits = json_fields(json_field(config, "maximum_per_trial"))
  let failures : Array[Json] = []
  for trial in trials {
    seen[(
      json_text(json_field(trial, "case_id")),
      json_integer(json_field(trial, "reference_start_step")),
    )] = true
    let reasons : Array[String] = []
    let elapsed = json_number(json_field(trial, "simulated_seconds"))
    let requested = json_number(json_field(trial, "requested_seconds"))
    if json_boolean(json_field(trial, "failed")) ||
      (elapsed - requested).abs() >
      1.0e-10.max(1.0e-9 * elapsed.abs().max(requested.abs())) {
      reasons.push("incomplete-trajectory")
    }
    for metric, limit in limits {
      let x = json_number(json_field(trial, metric))
      if !finite(x) || x > json_number(limit) {
        reasons.push(metric)
      }
    }
    if !reasons.is_empty() {
      failures.push({
        "episode_id": json_field(trial, "episode_id"),
        "reasons": reasons,
      })
    }
  }
  let complete = trials.length() == expected.length() &&
    seen.length() == expected.length() &&
    seen.keys().all(key => expected.contains(key))
  {
    "scope": json_field(config, "scope"),
    "trials": trials.length(),
    "expected_trials": expected.length(),
    "coverage_complete": complete,
    "failed_quality_trials": failures.length(),
    "failures": failures,
    "quality_passed": complete && failures.is_empty(),
    "release_qualified": false,
    "physical_execution_allowed": false,
  }
}

///|
pub async fn evaluate_initialization(
  runtime : @physics.Runtime,
  references : Array[ReferenceArchive],
  actor : ReferenceActor,
  geometry : @balance.Kinematics,
  quality : Json,
  output : String,
  label : String,
  dt : Double,
) -> Json {
  @fs.mkdir(output + "/physics/" + label, recursive=true)
  let trials : Array[Json] = []
  let records : Array[Json] = []
  for archive in references {
    let reference = archive.native_reference(runtime, dt)
    let case : @physics.Case = @json.from_json(
      json_field(archive.metadata, "case"),
    )
    for origin_s in json_array(json_field(quality, "origins_s")) {
      let origin = @math.round(json_number(origin_s) / dt).to_int()
      let runner = ReferenceRunner::new(actor, geometry, dt)
      let (episode, trial) = @balance_native.replay_reference(
        runtime,
        reference,
        case,
        origin,
        "policy",
        preview_length=actor.future_length,
        policy=(obs, current, future, valid) => {
          runner.predict(obs, current, future, valid)
        },
      )
      let id = episode.id + "-" + label
      let trial_fields = json_fields(trial)
      trial_fields["episode_id"] = id.to_json()
      let path = "physics/" + label + "/" + id + ".npz"
      let hash = @artifacts.save_npz(
        output + "/" + path,
        episode_arrays(episode),
      )
      records.push({
        "file": path,
        "sha256": hash,
        "reference_id": json_field(archive.metadata, "id"),
        "reference_sha256": json_field(archive.metadata, "sha256"),
        "origin_step": origin,
        "episode_id": id,
        "source_family": case.family,
        "split": case.split,
        "context": episode.context,
        "steps": episode.steps.length(),
      })
      trials.push(trial_fields.to_json())
    }
  }
  {
    "label": label,
    "trials": trials,
    "records": records,
    "quality": assess_tracking_quality(trials, quality),
    "summary": summarize_tracking(trials),
  }
}
