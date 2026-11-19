///|
/// Local reference provider output. Goals are already prepared in the trained
/// preview format; rotation maps the reference body into the calibrated actor
/// world. Completion still requires a valid fresh sensor capture.
pub(all) struct Reference {
  goals : Array[Double]
  body_to_world : Array[Double]
  complete : Bool
}

///|
/// Compose the existing runner, without a new execution engine. Actor, sensor,
/// mapping and reference must belong to the same selected deployment bundle.
/// Output projection happens before the runner's post-inference time checks.
/// The caller supplies publication and qualified stop behavior explicitly.
pub fn new_runner(
  supervisor : @skills.Supervisor,
  actor : @actor.Actor,
  mapping : @policy.Mapping,
  sensor : Sensor,
  reference~ : (@skills.Execution, Int32, Int64) -> Reference raise,
  publish~ : (ArrayView[@low.MotorCommand]) -> Unit raise,
  stop~ : () -> Unit,
  maximum_sensor_age_ms~ : Int64 = 100L,
) -> @runner.Runner raise {
  let bundle = actor.bundle()
  guard bundle.observation_width() == 99 &&
    bundle.profile_id() == mapping.profile_id() &&
    bundle.profile_id() == sensor.profile_id else {
    fail("E1 control actor, sensor and command profiles differ")
  }
  let commands : Ref[Array[@low.MotorCommand]?] = Ref(None)
  @runner.Runner::new(
    supervisor,
    clock=sensor.clock,
    history_frames=bundle.history_frames(),
    observation_width=99,
    goal_width=bundle.goal_width(),
    action_width=29,
    maximum_sensor_age_ms~,
    reference=(execution, step, previous, now) => {
      let frame = reference(execution, step, now)
      let (observation, captured_at_ms) = sensor.read(
        previous[:],
        frame.body_to_world[:],
      )
      {
        observation,
        goals: frame.goals,
        captured_at_ms,
        complete: frame.complete,
      }
    },
    predict=(history, goals) => {
      let actions = actor.forward_embedded(history, goals)
      commands.val = Some(mapping.commands(actions[:]))
      actions
    },
    sink=_ => {
      guard commands.val is Some(frame) else {
        fail("actor command frame missing")
      }
      publish(frame[:])
    },
    stop=() => {
      commands.val = None
      stop()
    },
  )
}
