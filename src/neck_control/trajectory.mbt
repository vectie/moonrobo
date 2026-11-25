///|
#derive(ToJson)
priv struct Waypoint {
  label : String
  targets : Array[Int32]
}

///|
fn next_goal(current : Int32, desired : Int32) -> Int32 {
  current +
  Int32::max(
    -maximum_step_ticks,
    Int32::min(maximum_step_ticks, desired - current),
  )
}

///|
// Only this explicit action returns to the captured starting pose. A fault
// aborts the remaining path, including that return; shutdown never replays it.
fn movement_waypoints(
  action : Action,
  before : Array[Feedback],
) -> Array[Waypoint] raise NeckError {
  validate_action(action)
  guard before.length() == 2 && before[0].id == 7 && before[1].id == 8 else {
    raise Rejected("Need both ordered neck axes for trajectory")
  }
  let path : Array[Waypoint] = []
  match action {
    Sweep(degrees) => {
      let center = [home(7), home(8)]
      path.push({ label: "center-before", targets: center.copy(), })
      for
        (direction, label) in [
          (Left, "left"),
          (Up, "up"),
          (Right, "right"),
          (Down, "down"),
        ] {
        path.push({
          label,
          targets: [
            target(Jog(direction, degrees), 7, home(7)),
            target(Jog(direction, degrees), 8, home(8)),
          ],
        })
        path.push({ label: "center-after-" + label, targets: center.copy(), })
      }
      path.push({
        label: "starting-pose",
        targets: before.map(f => f.position),
      })
    }
    _ =>
      path.push({
        label: "target",
        targets: before.map(f => target(action, f.id, f.position)),
      })
  }
  for waypoint in path {
    for i, id in [7, 8] {
      guard inside(id, before[i].position) && inside(id, waypoint.targets[i]) else {
        raise Rejected("Trajectory endpoint outside commissioned envelope")
      }
    }
  }
  path
}

///|
// No accumulated motion credit: a delayed loop can issue only one bounded
// step from its most recent input, never a burst to catch up.
fn live_step(rate : Int32) -> (Int32, Int64) {
  let ticks = if rate.abs() > 20 { 2 } else { 1 }
  let interval = Int32::max(
    50,
    (1000 * ticks + rate.abs() - 1) / Int32::max(1, rate.abs()),
  )
  (if rate < 0 { -ticks } else { ticks }, interval.to_int64())
}
