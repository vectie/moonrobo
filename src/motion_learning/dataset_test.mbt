///|
fn fixture() -> MotionDataset {
  let steps : Array[Transition] = []
  for i in 0..<4 {
    steps.push({
      time_s: i.to_double() * 0.02,
      state: [i.to_double(), 2.0],
      observation: [i.to_double()],
      applied_action: [0.5],
      next_state: [i.to_double() + 1.0, 2.0],
      goal: [3.0],
      reward: 1.0,
      terminated: i == 3,
      truncated: false,
    })
  }
  {
    format: "moonrobo.motion-dataset.v1",
    dataset_id: "synthetic",
    model_ref: "synthetic-two-state",
    provenance: "agent-authored numeric fixture",
    frame_convention: "scalar fixture, no spatial frame",
    dt_s: 0.02,
    state_axes: [{ name: "q", unit: "rad", }, { name: "dq", unit: "rad/s", }],
    observation_axes: [{ name: "q", unit: "rad", }],
    action_axes: [{ name: "effort", unit: "N.m", }],
    goal_axes: [{ name: "target", unit: "rad", }],
    context_axes: [{ name: "friction", unit: "1", }],
    episodes: [
      {
        id: "clip-a",
        source_family: "source-a",
        split: "train",
        context: [1.0],
        steps,
      },
    ],
  }
}

///|
test "reader and numeric windows retain channel order and terminal labels" {
  let data = parse(fixture().to_json().stringify()).unwrap()
  let batch = data.windows(split="train", length=3).unwrap()
  assert_eq(batch.windows.length(), 2)
  assert_eq(batch.state, [
    0.0, 2.0, 1.0, 2.0, 2.0, 2.0, 1.0, 2.0, 2.0, 2.0, 3.0, 2.0,
  ])
  assert_eq(batch.applied_action, [0.5, 0.5, 0.5, 0.5, 0.5, 0.5])
  assert_eq(batch.context, [1.0, 1.0])
  assert_eq(batch.terminated, [false, false, false, false, false, true])
  assert_eq(batch.truncated, [false, false, false, false, false, false])
  assert_eq(batch.layout.episodes.length(), 0)
  assert_eq(data.windows(split="test", length=3).unwrap().windows.length(), 0)
}

///|
test "windows exclude gaps and never cross episodes" {
  let data = fixture()
  let episode = data.episodes[0]
  episode.steps[2] = { ..episode.steps[2], time_s: 0.20, }
  episode.steps[3] = { ..episode.steps[3], time_s: 0.22, }
  let batch = data.windows(split="train", length=2).unwrap()
  assert_eq(batch.windows.map(w => w.start_step), [0, 2])
  assert_eq(data.windows(split="train", length=3).unwrap().windows.length(), 0)
  let shorter = { ..episode, steps: [episode.steps[0]], }
  let split = { ..data, episodes: [shorter, { ..shorter, id: "clip-b", }], }
  assert_eq(split.windows(split="train", length=2).unwrap().windows.length(), 0)
}

///|
test "strided windows retain episode tails and still reject gaps" {
  let base = fixture()
  let steps = Array::makei(10, i => {
    ..base.episodes[0].steps[0],
    time_s: i.to_double() * 0.02,
    state: [i.to_double(), 2.0],
    next_state: [i.to_double() + 1, 2.0],
    terminated: i == 9,
  })
  let episode = { ..base.episodes[0], steps, }
  let data = { ..base, episodes: [episode, { ..episode, id: "clip-b", }], }
  let batch = data.windows(split="train", length=3, stride=3).unwrap()
  assert_eq(batch.windows.map(w => w.start_step), [0, 3, 6, 7, 0, 3, 6, 7])
  assert_eq(batch.windows.map(w => w.episode_id), [
    "clip-a", "clip-a", "clip-a", "clip-a", "clip-b", "clip-b", "clip-b", "clip-b",
  ])
  assert_eq(batch.terminated.filter(x => x).length(), 2)
  assert_eq(
    data.windows(split="train", length=3),
    data.windows(split="train", length=3, stride=1),
  )
  assert_true(data.windows(split="train", length=3, stride=0) is Err(_))
  for i in 4..<steps.length() {
    steps[i] = { ..steps[i], time_s: steps[i].time_s + 0.2, }
  }
  assert_eq(
    data.windows(split="train", length=3, stride=3).unwrap().windows.map(w => {
      w.start_step
    }),
    [0, 6, 7, 0, 6, 7],
  )
}

///|
test "all splits are checked for family leakage and reset boundaries" {
  let data = fixture()
  let episode = data.episodes[0]
  let leaked = {
    ..data,
    episodes: [episode, { ..episode, id: "clip-b", split: "test", }],
  }
  assert_true(leaked.windows(split="train", length=2) is Err(_))
  episode.steps[1] = { ..episode.steps[1], truncated: true, }
  assert_true(data.validate() is Err(_))
}

///|
test "bad dimensions, nonfinite values and invalid JSON fail" {
  let data = fixture()
  data.episodes[0].steps[0] = {
    ..data.episodes[0].steps[0],
    applied_action: [],
  }
  assert_true(data.validate() is Err(_))
  assert_true({ ..fixture(), dt_s: 0.0, }.validate() is Err(_))
  let nonfinite = fixture()
  nonfinite.episodes[0].steps[0] = {
    ..nonfinite.episodes[0].steps[0],
    reward: 0.0 / 0.0,
  }
  assert_true(nonfinite.validate() is Err(_))
  assert_true(parse("{}") is Err(_))
  assert_true(fixture().windows(split="train", length=0) is Err(_))
}
