///|
async test "original learning actual action collection archive roundtrip and middle-origin memory" {
  let f = contract_fixture()
  let folder = @fs.tmpdir(prefix="moonrobo-reference-collection-")
  let config : Json = {
    "noise_seed_base": 10,
    "raw_action_std": 0.03,
    "gamma": 0.99,
    "maximum_action_alignment_error_rad": 0.00008,
    "maximum_feature_alignment_error": 0.00002,
  }
  let group = physical_group(
    f.runtime,
    [f.archive],
    f.schedule,
    f.actor,
    f.geometry,
    config,
    0,
    0,
    "training",
    folder,
    folder,
    { "checkpoint": "fixture" },
    [0],
    [0],
    "contract",
  )
  let batch = group.batch
  assert_eq(group.records.length(), 1)
  assert_eq(
    json_integer(json_field(group.records[0], "steps")),
    batch.points.length(),
  )
  assert_true(
    json_number(json_field(group.records[0], "maximum_action_alignment_error")) <
    0.00008,
  )
  assert_eq(
    json_integer(json_field(group.trials[0], "steps")),
    batch.reward.length(),
  )
  assert_true(batch.points.length() > 3)
  assert_eq(batch.reward.length(), batch.points.length())
  assert_eq(batch.done.filter(x => x).length(), 1)
  for i, point in batch.points {
    let command = f.schedule.command(0, point.step, f.actor.future_length)
    let requested = f.actor.action_from_latent(
      batch.latent[i],
      point.history,
      command.current,
      point.actual_features,
      point.reference_features,
    )
    contract_close(requested, batch.actions[i], atol=0.00008)
  }
  let path = contract_path("collection")
  let sha = save_collected_batch(path, batch)
  let restored = restore_collected_batch(path, sha)
  assert_eq(restored.to_json(), batch.to_json())
  let npz = path + ".npz"
  let npz_sha = @artifacts.save_npz(npz, collected_npz(batch))
  let original = restore_python_collection(
    npz,
    npz_sha,
    0,
    0,
    [1.0, 1.0],
    f.actor,
    f.schedule,
    0.99,
  )
  assert_eq(original.to_json(), batch.to_json())
  let middle = restored.points[3]
  assert_eq(middle.origin, 0)
  assert_eq(middle.step, 3)
  assert_eq(middle.history.last(), restored.points[3].history.last())
  let norm = n => {
    (
      { mean: Array::make(n, 0.0), scale: Array::make(n, 1.0), } :
      @numeric.Normalization)
  }
  let model = @training.Dynamics::new(
    norm(71),
    norm(29),
    norm(2),
    8,
    @numeric.Rng::new(77U),
    translation_invariant=true,
  )
  let t = @numeric.Tape::new()
  let (objective, active) = imagined_objective(
    t,
    model,
    f.actor,
    t.vector(f.actor.parameters()),
    None,
    [middle],
    f.geometry,
    f.schedule,
    f.schedule.length + 2,
    0.99,
    critic_tail=false,
  )
  assert_true(@numeric.finite(objective.value))
  assert_eq(active, f.schedule.length - 3)
  @fs.remove(path)
  @fs.remove(npz)
  @fs.rmdir(folder, recursive=true)
}

///|
async test "original learning behavior loader applies named direction to frozen base only" {
  let f = contract_fixture()
  let folder = @fs.tmpdir(prefix="moonrobo-reference-behavior-")
  let hash = save_reference_actor(
    folder + "/actor.json",
    f.actor,
    contract_spec(f),
    0.02,
    { "fixture": true },
  )
  let base = f.actor.parameters()
  let direction = Array::makei(base.length(), i => {
    -1.0 + 2.0 * i.to_double() / (base.length() - 1).to_double()
  })
  let checkpoint = @artifacts.Checkpoint::new(
    "moonrobo.g1-reference-parameter-direction.moonbit.v1",
    { "base_actor_sha256": hash, "parameter_names": f.actor.parameter_names() },
  )
  checkpoint.put("direction", [direction.length()], direction)
  let direction_hash = @artifacts.save_checkpoint(
    folder + "/direction.json",
    checkpoint,
  )
  let behavior : Json = {
    "checkpoint": "actor.json",
    "sha256": hash,
    "direction_file": "direction.json",
    "direction_sha256": direction_hash,
    "coefficient": 0.002,
  }
  let probe = load_behavior_actor(folder, behavior)
  assert_eq(probe.parameters(), base.mapi((i, x) => x + 0.002 * direction[i]))
  assert_eq(f.actor.parameters(), base)
  assert_eq(probe.fixed_buffers(), f.actor.fixed_buffers())
  @fs.rmdir(folder, recursive=true)
}

///|
async test "original learning reconstructed cycle checks actor model and value then rejects mutation" {
  let f = contract_fixture()
  let folder = @fs.tmpdir(prefix="moonrobo-reference-reconstruct-")
  let model = contract_model(@numeric.Rng::new(55U))
  let value = ReferenceValue::new(
    f.actor,
    Array::make(71, 0.0),
    Array::make(71, 1.0),
    1,
    @numeric.Rng::new(56U),
  )
  let hash = save_reference_actor(
    folder + "/actor-cycle-1.json",
    f.actor,
    contract_spec(f),
    0.02,
    { "fixture": true },
  )
  ignore(
    @artifacts.save_checkpoint(
      folder + "/dynamics-cycle-1.json",
      model.checkpoint(Json::null()),
    ),
  )
  ignore(
    save_reference_value(folder + "/value-cycle-1.json", value, Json::null()),
  )
  let cycle : Json = {
    "cycle": 1,
    "checkpoint": { "checkpoint": "actor-cycle-1.json", "sha256": hash },
  }
  let verified = verify_reconstructed_cycle(
    f.actor,
    model,
    value,
    cycle,
    folder,
  )
  assert_eq(json_field(verified, "all_tensors_identical"), true.to_json())
  model.network.parameters[model.network.parameters.length() - 1] += 0.001
  let rejected = try {
    ignore(verify_reconstructed_cycle(f.actor, model, value, cycle, folder))
    false
  } catch {
    _ => true
  }
  assert_true(rejected)
  @fs.rmdir(folder, recursive=true)
}

///|
test "original learning first three anchor fits match FIFO parameters draws and later pool counts" {
  let episode = (offset : Double) => {
    let state = Array::makei(6, i => {
      let row = Array::make(71, offset + i.to_double())
      row[3] = 1.0
      row[4] = 0.0
      row[5] = 0.0
      row[6] = 0.0
      row
    })
    (
      {
        state,
        action: Array::makei(6, _ => Array::make(29, 0.0)),
        next_state: state.map(row => {
          row.mapi((i, x) => if i >= 42 { x + 0.01 } else { x })
        }),
        context: [1.0, 1.0],
      } : LearningEpisode)
  }
  let fifo = ReferenceModelReplay::new(9, 4)
  let anchor = ReferenceModelReplay::new(9, 4, anchor_after=3)
  let left = contract_model(@numeric.Rng::new(86U))
  let right = contract_model(@numeric.Rng::new(86U))
  let left_optimizer = @numeric.Adam::new(
    left.network.parameters.length(),
    0.001,
  )
  let right_optimizer = @numeric.Adam::new(
    right.network.parameters.length(),
    0.001,
  )
  let left_rng = @numeric.Rng::new(1U)
  let right_rng = @numeric.Rng::new(1U)
  let config = { ..contract_config(), model_updates: 2, }
  for cycle in 0..<3 {
    fifo.append([episode(cycle.to_double() * 100.0)])
    anchor.append([episode(cycle.to_double() * 100.0)])
    if cycle == 1 {
      assert_eq(fifo.windows().map(w => w.state[0][0]), [
        0.0, 1.0, 2.0, 100.0, 101.0, 102.0,
      ])
    }
    let left_draws : Array[Int32] = []
    let right_draws : Array[Int32] = []
    ignore(
      fit_model_updates(left, left_optimizer, fifo, config, left_rng, sample_indices=ids => {
        left_draws.append(ids)
      }),
    )
    ignore(
      fit_model_updates(right, right_optimizer, anchor, config, right_rng, sample_indices=ids => {
        right_draws.append(ids)
      }),
    )
    assert_eq(
      sample_indices_digest([left_draws]),
      sample_indices_digest([right_draws]),
    )
    assert_eq(left.network.parameters, right.network.parameters)
  }
  fifo.append([episode(300.0)])
  anchor.append([episode(300.0)])
  assert_eq(fifo.windows().map(w => w.state[0][0]), [
    100.0, 101.0, 102.0, 200.0, 201.0, 202.0, 300.0, 301.0, 302.0,
  ])
  assert_eq(anchor.windows().map(w => w.state[0][0]), [
    0.0, 1.0, 2.0, 200.0, 201.0, 202.0, 300.0, 301.0, 302.0,
  ])
  assert_eq(anchor.anchor_count(), 3)
  let clone = @numeric.Rng::new(1U)
  clone.set_state(right_rng.state())
  let expected = Array::makei(8, _ => clone.index(9))
  let actual : Array[Int32] = []
  ignore(
    fit_model_updates(right, right_optimizer, anchor, config, right_rng, sample_indices=ids => {
      actual.append(ids)
    }),
  )
  assert_eq(actual, expected)
  assert_eq(sample_indices_digest([actual]), sample_indices_digest([expected]))
  assert_eq(
    actual.filter(i => i < 3).length(),
    expected.filter(i => i < 3).length(),
  )
  assert_eq(anchor.windows().length() - anchor.anchor_count(), 6)
  for window in anchor.windows() {
    assert_eq(window.state[3][0] - window.state[0][0], 3.0)
  }
}
