///|
pub(all) struct WindowBatch {
  layout : Json
  horizon : Int32
  count : Int32
  digest : String
  storage_digest : String
  state : Array[Double]
  action : Array[Double]
  target : Array[Double]
  observation : Array[Double]
  goal : Array[Double]
  start_time_s : Array[Double]
  context : Array[Double]
} derive(Debug)

///|
pub fn sha256(bytes : Bytes) -> String {
  let mut result = ""
  for byte in @crypto.sha256(bytes) {
    result += byte.to_hex()
  }
  result
}

///|
fn field(value : Json, key : String) -> Json raise {
  guard value is Object(fields) && fields.get(key) is Some(result) else {
    fail("missing artifact field: " + key)
  }
  result
}

///|
fn integer(value : Json) -> Int32 raise {
  guard value is Number(n, ..) &&
    n >= 0 &&
    n <= 2147483647.0 &&
    n.to_int().to_double() == n else {
    fail("nonnegative integer required")
  }
  n.to_int()
}

///|
fn text(value : Json) -> String raise {
  guard value is String(s) else { fail("string required") }
  s
}

///|
fn array(value : Json) -> Array[Json] raise {
  guard value is Array(items) else { fail("array required") }
  items
}

///|
fn numbers(value : Json, size : Int32) -> Array[Double] raise {
  let items = array(value)
  guard items.length() == size else { fail("artifact array shape differs") }
  items.map(item => {
    guard item is Number(n, ..) && n.abs() <= 1.7976931348623157e308 else {
      fail("nonfinite artifact tensor")
    }
    n
  })
}

///|
pub fn decode_window_batch(
  raw : Bytes,
  split : String,
  storage_digest? : String,
) -> WindowBatch raise {
  let data = @json.parse(@utf8.decode(raw))
  guard text(field(data, "format")) == "moonrobo.training-batch.v1" &&
    text(field(data, "split")) == split else {
    fail("expected a MoonBit training batch for " + split)
  }
  let layout = field(data, "layout")
  let count = array(field(data, "windows")).length()
  let horizon = integer(field(data, "window_length"))
  guard count > 0 && horizon > 0 && count <= 2147483647 / horizon else {
    fail("nonempty fixed-length windows required")
  }
  let rows = count * horizon
  fn tensor(key : String, axes : String) -> Array[Double] raise {
    let width = array(field(layout, axes)).length()
    guard width == 0 || rows <= 2147483647 / width else {
      fail("tensor shape overflow")
    }
    numbers(field(data, key), rows * width)
  }
  let times = numbers(field(data, "time_s"), rows)
  let width = array(field(layout, "context_axes")).length()
  guard width == 0 || count <= 2147483647 / width else {
    fail("context shape overflow")
  }
  let digest = sha256(raw)
  {
    layout,
    horizon,
    count,
    digest,
    storage_digest: storage_digest.unwrap_or(digest),
    state: tensor("state", "state_axes"),
    action: tensor("applied_action", "action_axes"),
    target: tensor("next_state", "state_axes"),
    observation: tensor("observation", "observation_axes"),
    goal: tensor("goal", "goal_axes"),
    context: numbers(field(data, "context"), count * width),
    start_time_s: Array::makei(count, i => times[i * horizon]),
  }
}

///|
pub fn WindowBatch::compatible(
  self : WindowBatch,
  other : WindowBatch,
  require_dataset_id~ : Bool = true,
) -> Unit raise {
  for
    key in [
      "dataset_id", "model_ref", "dt_s", "state_axes", "action_axes", "context_axes",
      "frame_convention",
    ] {
    if key == "dataset_id" && !require_dataset_id {
      continue
    }
    guard field(self.layout, key) == field(other.layout, key) else {
      fail("incompatible learning layout: " + key)
    }
  }
  guard self.horizon == other.horizon else { fail("window horizons differ") }
}

///|
pub async fn load_window_batch(path : String, split : String) -> WindowBatch {
  load_batch(path, split, 0)
}

///|
async fn load_batch(
  path : String,
  split : String,
  depth : Int32,
) -> WindowBatch {
  guard depth < 32 else { fail("training shard nesting exceeds 32") }
  let stored = @fs.read_file(path).binary()
  let storage_digest = sha256(stored)
  let raw = if path.has_suffix(".gz") { decompress(stored) } else { stored }
  let data = @json.parse(@utf8.decode(raw))
  if text(field(data, "format")) != "moonrobo.training-batch-shards.v1" {
    return decode_window_batch(raw, split, storage_digest~)
  }
  let shards = array(field(data, "shards"))
  guard text(field(data, "split")) == split && !shards.is_empty() else {
    fail("nonempty shards for requested split required")
  }
  let layout = field(data, "layout")
  let horizon = integer(field(data, "window_length"))
  let pieces = path.split("/").map(s => s.to_owned()).collect()
  ignore(pieces.pop())
  let parent = pieces.join("/")
  let result : WindowBatch = {
    layout,
    horizon,
    count: 0,
    digest: sha256(raw),
    storage_digest,
    state: [],
    action: [],
    target: [],
    observation: [],
    goal: [],
    start_time_s: [],
    context: [],
  }
  let mut count = 0
  for shard in shards {
    let name = text(field(shard, "file"))
    let child = if parent == "" { name } else { parent + "/" + name }
    let batch = load_batch(child, split, depth + 1)
    guard batch.digest == text(field(shard, "sha256")) &&
      batch.layout == layout &&
      batch.horizon == horizon &&
      batch.count == integer(field(shard, "windows")) else {
      fail("training shard differs from its manifest")
    }
    guard count <= 2147483647 - batch.count else {
      fail("training shard count overflow")
    }
    count += batch.count
    result.state.append(batch.state)
    result.action.append(batch.action)
    result.target.append(batch.target)
    result.observation.append(batch.observation)
    result.goal.append(batch.goal)
    result.start_time_s.append(batch.start_time_s)
    result.context.append(batch.context)
  }
  { ..result, count, }
}
