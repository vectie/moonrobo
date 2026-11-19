///|
fn field(value : Json, key : String) -> Json raise {
  guard value is Object(m) && m.get(key) is Some(v) else {
    fail("missing " + key)
  }
  v
}

///|
fn text(value : Json, key : String) -> String raise {
  @json.from_json(field(value, key))
}

///|
fn integer(value : Json, key : String) -> Int32 raise {
  @json.from_json(field(value, key))
}

///|
fn number(value : Json, key : String) -> Double raise {
  @json.from_json(field(value, key))
}

///|
fn array(value : Json, key : String) -> Array[Json] raise {
  @json.from_json(field(value, key))
}

///|
fn numbers(value : Json, key : String) -> Array[Double] raise {
  @json.from_json(field(value, key))
}

///|
fn integers(value : Json, key : String) -> Array[Int32] raise {
  @json.from_json(field(value, key))
}

///|
fn strings(value : Json, key : String) -> Array[String] raise {
  @json.from_json(field(value, key))
}

///|
fn merge(a : Json, b : Json) -> Json raise {
  guard a is Object(x) && b is Object(y) else { fail("objects required") }
  let m = x.copy()
  for k, v in y {
    m[k] = v
  }
  m.to_json()
}

///|
async fn read(path : String) -> Json {
  @artifacts.load_json(path)
}

///|
async fn digest(path : String) -> String {
  @artifacts.sha256(@fs.read_file(path).binary())
}

///|
fn resolve(folder : String, path : String) -> String {
  if path.has_prefix("/") {
    path
  } else {
    folder + "/" + path
  }
}

///|
fn stem(path : String) -> String {
  let name = path.split("/").last().unwrap().to_owned()
  if name.has_suffix(".npz") {
    name[:name.length() - 4].to_owned()
  } else {
    name
  }
}

///|
fn tensor(
  arrays : Map[String, @artifacts.NumericArray],
  key : String,
) -> @artifacts.NumericArray raise {
  guard arrays.get(key) is Some(v) else { fail("missing tensor " + key) }
  v
}

///|
fn vector(
  arrays : Map[String, @artifacts.NumericArray],
  key : String,
) -> Array[Double] raise {
  tensor(arrays, key).values.copy()
}

///|
fn matrix(
  arrays : Map[String, @artifacts.NumericArray],
  key : String,
) -> Array[Array[Double]] raise {
  let a = tensor(arrays, key)
  if a.shape.length() != 2 {
    fail("rank 2 required: " + key)
  }
  Array::makei(a.shape[0], i => {
    Array::makei(a.shape[1], j => a.values[i * a.shape[1] + j])
  })
}

///|
fn numeric(
  shape : Array[Int32],
  values : Array[Double],
) -> @artifacts.NumericArray {
  { shape, dtype: "<f8", values, }
}

///|
fn matrix_array(values : Array[Array[Double]]) -> @artifacts.NumericArray {
  let flat : Array[Double] = []
  for row in values {
    flat.append(row)
  }
  numeric(
    [values.length(), if values.is_empty() { 0 } else { values[0].length() }],
    flat,
  )
}

///|
fn maximum_difference(a : Array[Double], b : Array[Double]) -> Double raise {
  if a.length() != b.length() {
    fail("array widths differ")
  }
  let mut maximum = 0.0
  for i, v in a {
    let d = (v - b[i]).abs()
    if d > maximum {
      maximum = d
    }
  }
  maximum
}

///|
fn exact_source(
  actual : Array[Double],
  source : Array[Double],
  dtype : String,
  message : String,
) -> Unit raise {
  let rounded = if dtype == "<f4" || dtype == "=f4" {
    actual.map(v => v.to_float().to_double())
  } else {
    actual
  }
  if rounded != source {
    fail(message)
  }
}

///|
fn last_previous(observation : Array[Double], nu : Int32) -> Array[Double] {
  Array::makei(nu, i => observation[observation.length() - nu + i])
}

///|
struct Targets {
  positions : Array[Array[Array[Double]]]
  quaternions : Array[Array[Double]]
  joints : Array[Array[Double]]
}

///|
fn targets(
  reference : @ref.ReferenceArchive,
  phase : Int32,
  count : Int32,
) -> Targets raise {
  let clip = reference.clip()
  if phase < 0 || phase + count >= clip.goals.length() {
    fail("reference target interval out of bounds")
  }
  {
    positions: Array::makei(count, i => {
      clip.positions[phase + i + 1].map(p => {
        p.map(v => v.to_float().to_double())
      })
    }),
    quaternions: Array::makei(count, i => {
      clip.quaternions[phase + i + 1].map(v => v.to_float().to_double())
    }),
    joints: Array::makei(count, i => {
      Array::makei(29, j => clip.goals[phase + i + 1][j].to_float().to_double())
    }),
  }
}

///|
struct Snapshot {
  state : Array[Double]
  integration : Array[Double]
  observation : Array[Double]
  actions : Array[Array[Double]]
  context : Array[Double]
}

///|
fn Snapshot::arrays(self : Snapshot) -> Map[String, @artifacts.NumericArray] {
  {
    "state": numeric([self.state.length()], self.state),
    "integration": numeric([self.integration.length()], self.integration),
    "observation": numeric([self.observation.length()], self.observation),
    "actions": matrix_array(self.actions),
    "context": numeric([self.context.length()], self.context),
  }
}

///|
fn snapshot(arrays : Map[String, @artifacts.NumericArray]) -> Snapshot raise {
  {
    state: vector(arrays, "state"),
    integration: vector(arrays, "integration"),
    observation: vector(arrays, "observation"),
    actions: matrix(arrays, "actions"),
    context: vector(arrays, "context"),
  }
}

///|
struct Branch {
  state : Array[Array[Double]]
  observation : Array[Array[Double]]
  actions : Array[Array[Double]]
  next_state : Array[Array[Double]]
  rewards : Array[Double]
  terminated : Array[Bool]
  truncated : Array[Bool]
}

///|
fn Branch::arrays(self : Branch) -> Map[String, @artifacts.NumericArray] {
  {
    "state": matrix_array(self.state),
    "observation": matrix_array(self.observation),
    "applied_action": matrix_array(self.actions),
    "next_state": matrix_array(self.next_state),
    "reward": numeric([self.rewards.length()], self.rewards),
    "terminated": numeric(
      [self.terminated.length()],
      self.terminated.map(v => if v { 1.0 } else { 0.0 }),
    ),
    "truncated": numeric(
      [self.truncated.length()],
      self.truncated.map(v => if v { 1.0 } else { 0.0 }),
    ),
  }
}

///|
fn branch(arrays : Map[String, @artifacts.NumericArray]) -> Branch raise {
  {
    state: matrix(arrays, "state"),
    observation: matrix(arrays, "observation"),
    actions: matrix(arrays, "applied_action"),
    next_state: matrix(arrays, "next_state"),
    rewards: vector(arrays, "reward"),
    terminated: vector(arrays, "terminated").map(v => v != 0),
    truncated: vector(arrays, "truncated").map(v => v != 0),
  }
}

///|
fn branch_returns(
  branch : Branch,
  horizons : Array[Int32],
  gamma : Double,
) -> Json {
  let result : Map[String, Json] = {}
  for h in horizons {
    let value = @ref.discounted_returns(branch.rewards, gamma, h)
    result[h.to_string()] = value.prefix_return.to_json()
  }
  result.to_json()
}

///|
async fn save_branch(
  output : String,
  id : String,
  branch : Branch,
  metadata : Json,
  horizons : Array[Int32],
  gamma : Double,
) -> Json {
  let file = "physics/" + id + ".npz"
  let sha = @artifacts.save_npz(output + "/" + file, branch.arrays())
  merge(metadata, {
    "episode_id": id,
    "file": file,
    "sha256": sha,
    "steps": branch.state.length(),
    "returns": branch_returns(branch, horizons, gamma),
  })
}

///|
fn geometry_observation(
  state : Array[Double],
  previous : Array[Double],
) -> Array[Double] {
  let tape = @numeric.Tape::new()
  @ref.observation_graph(tape, tape.vector(state), tape.vector(previous)).map(v => {
    v.value
  })
}

///|
fn model_state_digest(model : @training.Dynamics) -> String {
  let values : Array[Array[Double]] = [
    model.network.parameters,
    model.state_stats.mean,
    model.state_stats.scale,
    model.action_stats.mean,
    model.action_stats.scale,
    model.context_stats.mean,
    model.context_stats.scale,
    model.network.dimensions.map(i => i.to_double()),
  ]
  @artifacts.sha256(@utf8.encode(values.to_json().stringify()))
}

///|
async fn provider_digest(file : String) -> String? {
  let root = @env.get_env_var("MOONROBO_SOURCE_ROOT").unwrap_or(
    @env.current_dir().unwrap_or("."),
  )
  let path = root + "/src/learning_reference_directions/" + file
  if @fs.exists(path) {
    Some(digest(path))
  } else {
    None
  }
}
