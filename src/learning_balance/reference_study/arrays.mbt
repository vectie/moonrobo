///|
fn tensor(
  shape : Array[Int32],
  values : Array[Double],
) -> @artifacts.NumericArray {
  { shape, dtype: "<f8", values, }
}

///|
fn flat(rows : Array[Array[Double]]) -> Array[Double] {
  let out : Array[Double] = []
  for row in rows {
    out.append(row)
  }
  out
}

///|
fn flat3(rows : Array[Array[Array[Double]]]) -> Array[Double] {
  flat(rows.map(flat))
}

///|
fn archive_frames(
  frames : Array[@balance_native.ReferenceFrame],
  velocities : Array[Array[Array[Double]]],
  episode : @sim.Episode,
) -> Map[String, @artifacts.NumericArray] raise {
  let n = frames.length()
  guard n >= 2 && episode.steps.length() + 1 == n && velocities.length() == n else {
    fail("reference frame/control counts differ")
  }
  let bodies = frames[0].body_position.length()
  let steps = episode.steps.length()
  let first = episode.steps[0]
  {
    "state": tensor(
      [n, frames[0].state.length()],
      flat(frames.map(f => f.state)),
    ),
    "integration": tensor(
      [n, frames[0].integration.length()],
      flat(frames.map(f => f.integration)),
    ),
    "body_position": tensor(
      [n, bodies, 3],
      flat3(frames.map(f => f.body_position)),
    ),
    "body_rotation": tensor(
      [n, bodies, 3, 3],
      flat3(frames.map(f => f.body_rotation)),
    ),
    "body_quaternion": tensor(
      [n, bodies, 4],
      flat3(frames.map(f => f.body_quaternion)),
    ),
    "body_object_velocity_world": tensor([n, bodies, 6], flat3(velocities)),
    "contacts": tensor([n], frames.map(f => f.contacts.to_double())),
    "time_s": tensor([n], frames.map(f => f.time)),
    "source_setpoint": tensor(
      [steps, first.applied_action.length()],
      flat(episode.steps.map(s => s.applied_action)),
    ),
    "source_goal": tensor(
      [steps, first.goal.length()],
      flat(episode.steps.map(s => s.goal)),
    ),
    "observation": tensor(
      [steps, first.observation.length()],
      flat(episode.steps.map(s => s.observation)),
    ),
  }
}

///|
fn array_field(
  arrays : Map[String, @artifacts.NumericArray],
  name : String,
) -> @artifacts.NumericArray raise {
  guard arrays.get(name) is Some(value) else {
    fail("missing NPZ reference array: " + name)
  }
  value
}

///|
fn row(values : @artifacts.NumericArray, index : Int32) -> Array[Double] {
  let width = values.values.length() / values.shape[0]
  values.values[index * width:(index + 1) * width].to_owned()
}

///|
fn body_rows(
  values : @artifacts.NumericArray,
  frame : Int32,
  bodies : Int32,
  width : Int32,
) -> Array[Array[Double]] {
  let values = row(values, frame)
  Array::makei(bodies, b => values[b * width:(b + 1) * width].to_owned())
}

///|
fn reference_from_arrays(
  runtime : @sim.Runtime,
  arrays : Map[String, @artifacts.NumericArray],
  dt : Double,
) -> @balance_native.NativeReference raise {
  let state = array_field(arrays, "state")
  let integration = array_field(arrays, "integration")
  let positions = array_field(arrays, "body_position")
  let rotations = array_field(arrays, "body_rotation")
  let quaternions = array_field(arrays, "body_quaternion")
  let contacts = array_field(arrays, "contacts")
  let time = array_field(arrays, "time_s")
  let controls = array_field(arrays, "source_setpoint")
  let obs = array_field(arrays, "observation")
  guard state.shape.length() == 2 && state.shape[0] >= 2 else {
    fail("invalid NPZ state shape")
  }
  let n = state.shape[0]
  let bodies = runtime.body_count() - 1
  guard positions.shape == [n, bodies, 3] &&
    rotations.shape == [n, bodies, 3, 3] &&
    quaternions.shape == [n, bodies, 4] &&
    contacts.shape == [n] &&
    time.shape == [n] &&
    controls.shape[0] == n - 1 &&
    obs.shape[0] == n - 1 else {
    fail("serialized reference arrays differ from compiled layout")
  }
  let frames : Array[@balance_native.ReferenceFrame] = Array::makei(n, i => {
    state: row(state, i),
    integration: row(integration, i),
    body_position: body_rows(positions, i, bodies, 3),
    body_rotation: body_rows(rotations, i, bodies, 9),
    body_quaternion: body_rows(quaternions, i, bodies, 4),
    contacts: contacts.values[i].to_int(),
    time: time.values[i],
  })
  @balance_native.NativeReference::new(
    runtime,
    frames,
    Array::makei(n - 1, i => row(controls, i)),
    Array::makei(n - 1, i => row(obs, i)),
    dt,
  )
}
