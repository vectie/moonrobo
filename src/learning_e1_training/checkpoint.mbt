///|
pub(all) struct Identity {
  robot : Profile
  config : Config
  dataset_sha256 : String
  scene_receipt_sha256 : String
  tensor_library_sha256 : String
  mujoco_library_sha256 : String
  admission_sha256 : String?
  training_revision : String?
} derive(ToJson, FromJson)

///|
pub(all) struct Saved {
  format : String
  identity : Identity
  learner : @gpu.CheckpointMetadata
  runtime : @runner.RuntimeSnapshotV2
  files : Map[String, String]
  sampler_returns : Array[Double]
  sampler_average : Array[Double]
  sampler_completed : Array[Int32]
  physical_rng : UInt32
  resume_kind : String
} derive(ToJson, FromJson)

///|
pub async fn hash_file(path : String) -> String {
  let file = @fs.open(path, mode=ReadOnly)
  defer file.close()
  let size = file.size()
  guard size > 0L && size <= 536870912L else {
    fail("E1 artifact byte bound exceeded: " + path)
  }
  let hash = @crypto.SHA256::new()
  for offset = 0L; offset < size; {
    let count = (size - offset).min(262144L).to_int()
    hash.update(file.read_exactly_at(count, position=offset))
    continue offset + count.to_int64()
  }
  @crypto.bytes_to_hex_string(hash.finalize())
}

///|
async fn save_generation(
  output : String,
  identity : Identity,
  learner : @gpu.Learner,
  runner : @runner.TrainingRunner,
  env : Environment,
) -> String {
  let generation = "generation-\{runner.iteration}"
  let directory = output + "/" + generation
  guard !@fs.exists(directory) else {
    fail("E1 checkpoint generation already exists")
  }
  @fs.mkdir(directory)
  learner.save_optimizers(directory)
  let runtime = runner.write_snapshot_v2(directory)
  let files : Map[String, String] = {}
  for name in @fs.readdir(directory) {
    files[name] = hash_file(directory + "/" + name)
  }
  let (returns, average, completed) = env.sampler.snapshot()
  let saved : Saved = {
    format: "moonrobo.e1-native-checkpoint.v1",
    identity,
    learner: learner.checkpoint_metadata(),
    runtime,
    files,
    sampler_returns: returns,
    sampler_average: average,
    sampler_completed: completed,
    physical_rng: env.rng.state(),
    resume_kind: "warm-physical-reset-replay-refill",
  }
  let data = @utf8.encode(Json(saved).stringify())
  @fs.write_file(directory + "/checkpoint.json", data, create_mode=CreateNew)
  let pointer : Json = {
    "format": "moonrobo.e1-checkpoint-pointer.v1",
    "generation": Json(generation),
    "iteration": Json(runner.iteration),
    "sha256": Json(@artifacts.sha256(data)),
  }
  @fs.write_file(
    output + "/current.json.tmp",
    @utf8.encode(pointer.stringify()),
    create_mode=CreateOrTruncate,
  )
  @fs.rename(
    output + "/current.json.tmp",
    output + "/current.json",
    replace=true,
  )
  output + "/current.json"
}

///|
pub async fn open_checkpoint(pointer : String) -> (Saved, String) {
  let json = @json.parse(@utf8.decode(read_bounded(pointer, 1048576L)))
  guard json is Object(fields) &&
    fields.get("format") == Some(Json("moonrobo.e1-checkpoint-pointer.v1")) &&
    fields.get("generation") is Some(String(generation)) &&
    generation.has_prefix("generation-") &&
    !generation.contains("/") &&
    !generation.contains("\\") &&
    !generation.contains("..") &&
    fields.get("sha256") is Some(String(digest)) else {
    fail("invalid E1 checkpoint pointer")
  }
  let parts = pointer.split("/").map(x => x.to_owned()).collect()
  guard parts.length() > 1 else {
    fail("checkpoint pointer needs an explicit directory")
  }
  ignore(parts.pop())
  let directory = parts.join("/") + "/" + generation
  let bytes = read_bounded(directory + "/checkpoint.json", 4194304L)
  guard @artifacts.sha256(bytes) == digest else {
    fail("E1 checkpoint metadata digest differs")
  }
  let saved : Saved = @json.from_json(@json.parse(@utf8.decode(bytes)))
  guard saved.format == "moonrobo.e1-native-checkpoint.v1" &&
    saved.resume_kind == "warm-physical-reset-replay-refill" &&
    fields.get("iteration") == Some(Json(saved.runtime.iteration)) &&
    saved.files.contains("policy.pt") &&
    saved.files.contains("world.pt") &&
    saved.files.contains("critic.pt") &&
    Json(saved.identity.robot) ==
    Json(profile(joints=saved.identity.robot.joints.length())) else {
    fail("invalid E1 checkpoint contract")
  }
  saved.identity.config.validate()
  for name, hash in saved.files {
    guard !name.is_empty() &&
      !name.contains("/") &&
      !name.contains("\\") &&
      !name.contains("..") else {
      fail("invalid E1 checkpoint member")
    }
    guard hash_file(directory + "/" + name) == hash else {
      fail("E1 checkpoint member digest differs: " + name)
    }
  }
  for blob in saved.runtime.blobs() {
    guard saved.files.get(blob.file) == Some(blob.sha256) else {
      fail("checkpoint receipt omits runtime blob digest")
    }
  }
  (saved, directory)
}
