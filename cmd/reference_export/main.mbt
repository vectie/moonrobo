///|
async fn main {
  let args = @env.args()
  guard args.length() == 7 else {
    fail(
      "usage: moon run --target native cmd/reference_export -- ACTOR.json ACTOR_SHA256 COLLECTION.json COLLECTION_SHA256 REFERENCES OUTPUT.json",
    )
  }
  let (actor, metadata) = @reference.load_reference_actor(
    args[1],
    expected_sha256=args[2],
  )
  let batch = @reference.restore_collected_batch(args[3], args[4])
  let (_, references) = @reference.load_references(args[5])
  let clips = references.map(archive => archive.clip())
  let geometry = @reference.kinematics_from_spec(metadata.kinematics)
  let episodes : Array[Json] = []
  let mut start = 0
  for length in batch.episode_lengths {
    guard length > 0 && start + length <= batch.points.length() else {
      fail("invalid collection episode boundaries")
    }
    let transitions : Array[Json] = []
    let mut reward_error = 0.0
    let mut observation_error = 0.0
    for offset in 0..<length {
      let i = start + offset
      let point = batch.points[i]
      let next_phase = point.step + 1
      let clip = clips[point.clip]
      let observation = point.history[point.history.length() - 1]
      let previous = observation[observation.length() - actor.nu:].to_owned()
      let reward = @reference.reward_from_geometry(
        geometry,
        batch.next_states[i],
        batch.actions[i],
        previous,
        clip.positions[next_phase],
        clip.quaternions[next_phase],
        clip.goals[next_phase][:actor.nu].to_owned(),
        metadata.dt_s,
      )
      reward_error = reward_error.max((reward.reward - batch.reward[i]).abs())
      let tape = @numeric.Tape::new()
      let expected = @reference.observation_graph(
        tape,
        tape.vector(point.state),
        tape.vector(previous),
      ).map(x => x.value)
      for j, x in expected {
        observation_error = observation_error.max((x - observation[j]).abs())
      }
      if offset > 0 {
        guard point.state == batch.next_states[i - 1] else {
          fail("collection continuity changed")
        }
      }
      let next_state = batch.next_states[i]
      let rotation = @reference.quaternion_matrix(next_state[3:7].to_owned())
      transitions.push({
        "time_s": offset.to_double() * metadata.dt_s,
        "state": point.state,
        "observation": observation,
        "applied_action": batch.actions[i],
        "next_state": next_state,
        "goal": clip.goals[next_phase],
        "reward": batch.reward[i],
        "terminated": reward.fallen,
        "truncated": !reward.fallen && offset == length - 1,
        "root_height_m": next_state[2],
        "upright_z": rotation[2][2],
      })
    }
    guard reward_error <= 1.0e-10 && observation_error <= 1.0e-8 else {
      fail("reconstructed reward or observation differs from collected physics")
    }
    episodes.push({
      "clip_index": batch.points[start].clip,
      "origin_step": batch.points[start].origin,
      "steps": transitions,
      "maximum_reward_error": reward_error,
      "maximum_observation_error": observation_error,
    })
    start += length
  }
  guard start == batch.points.length() else {
    fail("collection episode lengths omit transitions")
  }
  let report : Json = {
    "format": "moonrobo.g1-reference-numeric-export.moonbit.v1",
    "actor_sha256": args[2],
    "collection_sha256": args[4],
    "dt_s": metadata.dt_s,
    "episodes": episodes,
    "physical_execution_allowed": false,
    "release_qualified": false,
    "contacts_reconstructed": false,
  }
  @fs.write_file(
    args[6],
    @utf8.encode(report.stringify(indent=2)),
    create_mode=CreateOrTruncate,
  )
  let summary : Json = {
    "output": args[6],
    "episodes": episodes.length(),
    "transitions": start,
    "sha256": @artifacts.sha256(@fs.read_file(args[6]).binary()),
  }
  println(summary.stringify())
}
