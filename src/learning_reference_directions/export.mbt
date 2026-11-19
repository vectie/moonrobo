///|
fn validate_branch(
  branch : Branch,
  arrays : Map[String, @artifacts.NumericArray],
  inputs : Snapshot,
  target : Targets,
  geometry : @balance.Kinematics,
  maximum_steps : Int32,
  dt : Double,
) -> (Double, Double) raise {
  let n = branch.state.length()
  if n == 0 ||
    tensor(arrays, "state").dtype != "<f8" ||
    branch.state[0] != inputs.state {
    fail("branch precision or initial state differs")
  }
  let mut reward_error = 0.0
  let mut observation_error = 0.0
  for i in 0..<n {
    if i > 0 && branch.state[i] != branch.next_state[i - 1] {
      fail("branch state continuity differs")
    }
    let previous = last_previous(branch.observation[i], 29)
    let reward = @ref.reward_from_geometry(
      geometry,
      branch.next_state[i],
      branch.actions[i],
      previous,
      target.positions[i],
      target.quaternions[i],
      target.joints[i],
      dt,
    )
    if reward.fallen != branch.terminated[i] {
      fail("branch termination differs")
    }
    let r = (reward.reward - branch.rewards[i]).abs()
    if r > reward_error {
      reward_error = r
    }
    let o = maximum_difference(
      geometry_observation(branch.state[i], previous),
      branch.observation[i],
    )
    if o > observation_error {
      observation_error = o
    }
    if i > 0 && previous != branch.actions[i - 1] {
      fail("previous-control history differs")
    }
    if i < n - 1 && (branch.terminated[i] || branch.truncated[i]) {
      fail("invalid intermediate branch boundary")
    }
  }
  if reward_error > 0.000000000001 || observation_error > 0.0000000001 {
    fail("reward or observation reconstruction differs")
  }
  if !(branch.terminated[n - 1] || branch.truncated[n - 1]) ||
    (!branch.terminated[n - 1] && n != maximum_steps) {
    fail("invalid final branch boundary or short unfallen branch")
  }
  (reward_error, observation_error)
}

///|
fn export_dataset(
  runtime : @physics.Runtime,
  record : Json,
  branch : Branch,
  reference : @ref.ReferenceArchive,
  manifest : Json,
  dt : Double,
  provenance : String,
  revision : String,
) -> Json raise {
  let goals = reference.goals()
  let offset = integer(record, "offset")
  let steps : Array[@physics.Transition] = Array::makei(branch.state.length(), i => {
    time_s: i.to_double() * dt,
    state: branch.state[i],
    observation: branch.observation[i],
    applied_action: branch.actions[i],
    next_state: branch.next_state[i],
    goal: goals[offset + i + 1],
    reward: branch.rewards[i],
    terminated: branch.terminated[i],
    truncated: branch.truncated[i],
  })
  let context = numbers(record, "context")
  let episode : @physics.Episode = {
    id: text(record, "episode_id"),
    source_family: text(record, "source_family"),
    split: "train",
    context,
    steps,
    case_id: text(record, "source_episode_id"),
    reference_nominal_rad: goals[offset],
  }
  let dataset = runtime.dataset([episode], revision, dt~)
  merge(dataset, {
    "model_ref": field(manifest, "model_ref"),
    "goal_axes": field(field(manifest, "layout"), "goal_axes"),
    "provenance": provenance,
  })
}

///|
/// Independent open-tape response verifier and registry export stream.
pub async fn export_action_response(
  folder : String,
  scene : String,
  library : String,
  emit : (Json) -> Unit,
) -> Unit {
  let report = read(folder + "/report.json")
  let config = field(report, "config")
  let refs_path = text(report, "references")
  let (manifest, references) = @ref.load_references(refs_path)
  if digest(refs_path + "/manifest.json") !=
    text(report, "reference_manifest_sha256") {
    fail("reference manifest changed")
  }
  let dt = number(field(manifest, "layout"), "dt_s")
  let runtime = @physics.Runtime::open(library, scene)
  let (lower, upper) = runtime.control_bounds()
  for record in array(report, "physical_records") {
    let (_, meta) = @ref.load_reference_actor(
      text(record, "geometry_checkpoint"),
      expected_sha256=text(record, "source_actor_sha256"),
    )
    let geometry = @ref.kinematics_from_spec(meta.kinematics)
    let path = resolve(folder, text(record, "file"))
    let snapshot_path = resolve(folder, text(record, "snapshot"))
    let arrays = @artifacts.load_npz(
      path,
      expected_sha256=text(record, "sha256"),
    )
    let snapshot_arrays = @artifacts.load_npz(
      snapshot_path,
      expected_sha256=text(record, "snapshot_sha256"),
    )
    let data = branch(arrays)
    let s = snapshot(snapshot_arrays)
    let direction = if text(record, "role") == "counterfactual" {
      vector(
        @artifacts.load_npz(
          resolve(folder, text(record, "direction_file")),
          expected_sha256=text(record, "direction_sha256"),
        ),
        "direction",
      )
    } else {
      Array::make(29, 0.0)
    }
    let expected = @ref.first_action_tape(
      s.actions,
      direction,
      number(record, "amplitude"),
      lower,
      upper,
    )
    let n = integer(record, "steps")
    if n != data.state.length() {
      fail("branch length differs from record")
    }
    for i in 0..<n {
      if expected[i] != data.actions[i] {
        fail("branch is not frozen one-action perturbation")
      }
    }
    let reference = references[integer(record, "clip_index")]
    let target = targets(reference, integer(record, "offset"), n)
    let (reward_error, obs_error) = validate_branch(
      data,
      arrays,
      s,
      target,
      geometry,
      integer(config, "maximum_branch_steps"),
      dt,
    )
    if data.observation[0] != s.observation {
      fail("initial observation differs")
    }
    let dataset = export_dataset(
      runtime, record, data, reference, manifest, dt, "Known development-state open-loop physical action branches; float64 archives, one perturbed first control, frozen later controls",
      "reference-action-response",
    )
    emit({
      "record": record,
      "dataset": dataset,
      "verification": {
        "reward_error": reward_error,
        "observation_error": obs_error,
      },
    })
  }
}

///|
/// Reconstruct both the frozen source inputs and each recorded feedback action.
pub async fn export_feedback_response(
  folder : String,
  scene : String,
  library : String,
  emit : (Json) -> Unit,
) -> Unit {
  let report = read(folder + "/report.json")
  let source = text(report, "source_study")
  if digest(source + "/report.json") != text(report, "source_report_sha256") {
    fail("response source changed")
  }
  let previous = read(source + "/report.json")
  let old_source = text(previous, "source_study")
  if digest(old_source + "/report.json") !=
    text(previous, "source_report_sha256") {
    fail("controller source changed")
  }
  let old = read(old_source + "/report.json")
  let old_records : Map[String, Json] = {}
  for r in array(old, "physical_records") {
    old_records[text(r, "episode_id")] = r
  }
  let refs_path = text(report, "references")
  let (manifest, references) = @ref.load_references(refs_path)
  if digest(refs_path + "/manifest.json") !=
    text(report, "reference_manifest_sha256") {
    fail("reference manifest changed")
  }
  let dt = number(field(manifest, "layout"), "dt_s")
  let runtime = @physics.Runtime::open(library, scene)
  let verified : Map[String, Bool] = {}
  for record in array(report, "physical_records") {
    let actor_path = text(record, "geometry_checkpoint")
    let (actor, meta) = @ref.load_reference_actor(
      actor_path,
      expected_sha256=text(record, "source_actor_sha256"),
    )
    let geometry = @ref.kinematics_from_spec(meta.kinematics)
    let schedule = schedule_for(references, geometry, dt)
    let input_file = text(record, "inputs")
    let arrays = @artifacts.load_npz(
      resolve(folder, text(record, "file")),
      expected_sha256=text(record, "sha256"),
    )
    let initial = @artifacts.load_npz(
      resolve(folder, input_file),
      expected_sha256=text(record, "inputs_sha256"),
    )
    let inputs = feedback_inputs(initial, actor)
    if !verified.contains(input_file) {
      guard array(previous, "conditions")
        .filter(c => {
          field(c, "method") == field(record, "method") &&
          field(c, "seed") == field(record, "seed") &&
          field(c, "clip_index") == field(record, "clip_index") &&
          field(c, "offset") == field(record, "offset")
        })
        .get(0)
        is Some(condition) else {
        fail("source feedback condition missing")
      }
      let snapshots = @artifacts.load_npz(
        resolve(source, text(condition, "snapshot")),
        expected_sha256=text(condition, "snapshot_sha256"),
      )
      for key, v in snapshots {
        let actual = tensor(initial, key)
        if actual.shape != v.shape || actual.values != v.values {
          fail("initial solver or control tape differs")
        }
      }
      guard old_records.get(text(record, "source_episode_id")) is Some(original) else {
        fail("causal history source absent")
      }
      let original_arrays = @artifacts.load_npz(
        resolve(old_source, text(original, "file")),
        expected_sha256=text(original, "sha256"),
      )
      let expected = restored_inputs(
        snapshots,
        original_arrays,
        actor,
        integer(record, "clip_index"),
        integer(record, "offset"),
      )
      for key in ["history", "actual_features", "reference_features"] {
        let a = tensor(initial, key)
        let b = tensor(expected, key)
        if a.shape != b.shape || a.values != b.values {
          fail("controller does not restore original causal memory")
        }
      }
      verified[input_file] = true
    }
    let data = branch(arrays)
    let n = integer(record, "steps")
    if n != data.state.length() {
      fail("branch length differs from record")
    }
    let mut direction = Array::makei(32, _ => Array::make(29, 0.0))
    if text(record, "role") == "counterfactual" {
      let archive = @artifacts.load_npz(
        resolve(folder, text(record, "direction_file")),
        expected_sha256=text(record, "direction_sha256"),
      )
      let tensor = tensor(archive, "direction")
      if tensor.shape != [32, 29] {
        fail("direction has wrong shape")
      }
      direction = matrix(archive, "direction")
      let mut square = 0.0
      for row in direction {
        for v in row {
          square += v * v
        }
      }
      if (square / (32.0 * 29.0) - 1).abs() > 0.000000000001 {
        fail("direction has wrong RMS normalization")
      }
    }
    let mode = text(record, "execution_mode")
    let amplitude = number(record, "amplitude")
    let mut history = inputs.history.map(row => row.copy())
    let mut features = inputs.features.copy()
    let mut memory = @ref.observer_memory(
      history[history.length() - 1],
      features,
    )
    let mut action_error = 0.0
    for t in 0..<n {
      let base = if mode == "open-tape" {
        inputs.snapshot.actions[t]
      } else if mode == "feedback" {
        policy_action(actor, schedule, inputs, history, features, t)
      } else {
        fail("unknown execution mode")
      }
      let expected = runtime.clip_control(
        Array::makei(base.length(), i => base[i] + amplitude * direction[t][i]),
      )
      let error = maximum_difference(expected, data.actions[t])
      if error > action_error {
        action_error = error
      }
      if mode == "feedback" {
        let obs = geometry_observation(data.next_state[t], data.actions[t])
        let error = geometry.from_observation(obs)
        let (next_features, next_memory) = @ref.observer_advance(
          obs, memory, dt, error,
        )
        features = next_features
        memory = next_memory
        history = Array::makei(history.length(), i => {
          if i + 1 < history.length() {
            history[i + 1]
          } else {
            obs
          }
        })
      }
    }
    if action_error > 0.0000000001 {
      fail("branch actions disagree with frozen tape/causal feedback law")
    }
    let reference = references[integer(record, "clip_index")]
    let target = targets(reference, integer(record, "offset"), n)
    let (reward_error, obs_error) = validate_branch(
      data,
      arrays,
      inputs.snapshot,
      target,
      geometry,
      32,
      dt,
    )
    let expected_previous = if mode == "open-tape" {
      last_previous(inputs.snapshot.observation, 29)
    } else {
      last_previous(inputs.history[inputs.history.length() - 1], 29)
    }
    if last_previous(data.observation[0], 29) != expected_previous {
      fail("initial previous-control history differs")
    }
    let dataset = export_dataset(
      runtime, record, data, reference, manifest, dt, "Known-state H32 action-tape/causal-feedback response; float64 archives and explicitly restored controller memory",
      "reference-feedback-response",
    )
    emit({
      "record": record,
      "dataset": dataset,
      "verification": {
        "action_error_rad": action_error,
        "reward_error": reward_error,
        "observation_error": obs_error,
      },
    })
  }
}
