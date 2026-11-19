///|
fn network_elements(widths : Array[Int32]) -> Int64 {
  let mut count = 0L
  for i in 1..<widths.length() {
    count += (widths[i - 1].to_int64() + 1L) * widths[i].to_int64()
  }
  count
}

///|
/// Conservative eager-training envelope, separate from measured peaks. On GB10
/// host/cgroup and CUDA free are limiting observations, never added together.
async fn admit_training(
  backend : @tensor.Backend,
  config : Config,
  dataset : Dataset,
  directory : String,
  device : Int32,
) -> Json {
  let memory = @utf8.decode(@fs.read_file("/proc/meminfo").binary())
  let mut host = 0L
  for line in memory.split("\n") {
    if line.has_prefix("MemAvailable:") {
      let text = line
        .to_owned()
        .replace_all(old="MemAvailable:", new="")
        .replace_all(old="kB", new="")
        .trim()
        .to_owned()
      host = @string.parse_int64(text) * 1024L
    }
  }
  guard host > 0L else { fail("E1 admission requires Linux MemAvailable") }
  if @fs.exists("/sys/fs/cgroup/memory.max") &&
    @fs.exists("/sys/fs/cgroup/memory.current") {
    let maximum = @utf8.decode(
        @fs.read_file("/sys/fs/cgroup/memory.max").binary(),
      )
      .trim()
      .to_owned()
    if maximum != "max" {
      let used = @string.parse_int64(
        @utf8.decode(@fs.read_file("/sys/fs/cgroup/memory.current").binary()).trim(),
      )
      host = host.min(@string.parse_int64(maximum) - used)
    }
  }
  let available = if device >= 0 {
    host.min(backend.cuda_free_bytes(device))
  } else {
    host
  }
  let c = config.learner
  let wm = [512]
  wm.append(c.wm_hidden)
  wm.push(128)
  let enc = [73 * c.goal_frames]
  enc.append(c.policy_hidden)
  enc.push(32)
  let dec = [32 + 99 * c.hist]
  dec.append(c.policy_hidden)
  dec.push(29)
  let critic = [184 + 73 * c.goal_frames]
  critic.append(c.critic_hidden)
  critic.push(1)
  let parameters = [wm, enc, dec, critic]
    .map(network_elements)
    .fold(init=0L, (a, b) => a + b)
  let world_rows = if config.world_microbatch > 0 {
    config.world_microbatch.min(c.wm_batch)
  } else {
    c.wm_batch
  }
  let actor_rows = if config.actor_microbatch > 0 {
    config.actor_microbatch.min(c.policy_batch)
  } else {
    c.policy_batch
  }
  let widths = (c.wm_hidden.fold(init=0, (a, b) => a + b) +
  2 * c.policy_hidden.fold(init=0, (a, b) => a + b) +
  8192).to_int64()
  let activations = (
      world_rows.to_int64() * c.wm_window.to_int64() +
      actor_rows.to_int64() * c.horizon.to_int64()
    ) *
    widths *
    64L
  let replay = config.environments.to_int64() *
    config.replay_steps.to_int64() *
    241L *
    64L
  let mut references = 0L
  for entry in dataset.entries {
    if entry.split != "train" {
      continue
    }
    guard !entry.file.contains("..") && !entry.file.has_prefix("/") else {
      fail("invalid reference path in admission")
    }
    let file = @fs.open(directory + "/" + entry.file, mode=ReadOnly)
    let size = file.size()
    file.close()
    guard size > 0L && size <= 67108864L && references <= 536870912L - size else {
      fail("E1 eager reference byte envelope exceeded")
    }
    references += size
  }
  let peak = 2147483648L +
    parameters * 32L +
    activations +
    replay +
    references * 64L
  let budget = available / 100L * 65L
  let report : Json = {
    "format": "moonrobo.e1-eager-memory-admission.v1",
    "estimated_peak_bytes": Json(peak),
    "limiting_available_bytes": Json(available),
    "admission_percent": 65,
    "budget_bytes": Json(budget),
    "accepted": Json(peak <= budget),
    "scope": "conservative eager envelope including reference expansion, replay, optimizer/archive copies and BPTT; not a measured peak or OOM guarantee",
  }
  println(report.stringify())
  guard peak <= budget else {
    fail("E1 training exceeds unchanged 65-percent memory admission")
  }
  report
}
