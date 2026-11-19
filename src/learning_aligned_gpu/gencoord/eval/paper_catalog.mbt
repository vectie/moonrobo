///|
priv struct CatalogJob {
  paper_catalog : Bool
  plugin : String
  device : String
  environments : Int32
  motion_file : String
  manifest_sha256 : String
  layout : String
  checkpoint : String
  physical_steps : Int32
  output : String
} derive(@json.FromJson)

///|
async fn score_catalog(path : String) -> Unit {
  let j : CatalogJob = @json.from_json(read_play_json(path))
  let c : NativeCatalog = @json.from_json(
    read_play_json(j.motion_file + "/source.json"),
  )
  guard j.paper_catalog &&
    j.device == "cuda:0" &&
    j.environments > 0 &&
    j.environments <= 4096 &&
    c.frames > 0 &&
    c.clips > 0 &&
    c.manifest_sha256 == j.manifest_sha256 &&
    !@fs.path_exists(j.output) else {
    fail("invalid paper evaluation or output already exists")
  }
  let b = @tensor.Backend::open(j.plugin)
  let free = @linuxmem.host_available().min(b.cuda_free_bytes(0))
  let budget = (free / 100L * 80L).min(free - 17179869184L)
  let planned = c.frames.to_int64() * 300L +
    j.environments.to_int64() * 7340032L +
    6442450944L
  guard planned <= budget else {
    fail("paper evaluation memory admission declined")
  }
  let sim = b.open_mjlab(path)
  guard read_play_json(j.layout) is Object(layout) else {
    fail("missing G1 layout")
  }
  let kin : @aligned.Kinematics = @json.from_json(layout["geometry"])
  let scale = sim.exchange(0)
  let offset = sim.exchange(1)
  let expected = (scale.values(), offset.values())
  let model = @gc.GenModel::new(
    b,
    scale,
    offset,
    context_dim=33,
    device=0,
    dt=0.02,
    decimation=4,
  )
  let learner = @gc.GenLearner::new(model, @geometry.Context::new(b, kin, 0))
  let (_, steps) = learner.load_weights(j.checkpoint)
  assert_eq(steps, j.physical_steps)
  assert_eq((scale.values(), offset.values()), expected)
  let refs = @gc.GenMotions::from_fields(
    b,
    Array::makei(6, i => sim.exchange(9 + i)),
  )
  ignore(sim.exchange(19))
  let mut t = 0
  while true {
    let state = @gc.GenState::from_replay(b, sim.exchange(2))
    let goal = state.goals(b, refs.window(sim.exchange(4), sim.exchange(20)))
    ignore(sim.exchange(21, input=model.act(state, goal, frozen=true)))
    t += 1
    if t % 64 == 0 {
      let scored = sim.exchange(22).values()
      if t % 512 == 0 {
        println("vector step \{t}, scored \{scored}")
      }
      if scored[0] == scored[1] {
        break
      }
      guard t <= c.frames else { fail("non-terminating catalog evaluation") }
    }
  }
  ignore(sim.exchange(23))
}
