///|
/// Explicit experimental controller settings. Limits describe this deployment,
/// not inferred hardware specifications or a modification of the saved actor.
pub(all) struct Settings {
  lower_rad : Array[Double]
  upper_rad : Array[Double]
  maximum_speed_rad_s : Array[Double]
  response_ms : Int32
  engage_ms : Int32
  policy_authority : Double
} derive(FromJson)

///|
pub extend Settings with @json.FromJson::{from_json}

///|
fn finite(x : Double) -> Bool {
  x - x == 0.0
}

///|
pub fn Settings::validate(self : Self) -> Unit raise {
  guard self.lower_rad.length() == 2 &&
    self.upper_rad.length() == 2 &&
    self.maximum_speed_rad_s.length() == 2 &&
    self.response_ms >= 20 &&
    self.engage_ms >= 20 &&
    finite(self.policy_authority) &&
    self.policy_authority > 0.0 &&
    self.policy_authority <= 1.0 else {
    fail("invalid elbow adapter dimensions, timing or authority")
  }
  for i in 0..<2 {
    guard finite(self.lower_rad[i]) &&
      finite(self.upper_rad[i]) &&
      finite(self.maximum_speed_rad_s[i]) &&
      self.lower_rad[i] < self.upper_rad[i] &&
      self.lower_rad[i] >= -2.2689280275926285 &&
      self.upper_rad[i] <= 0.0 &&
      self.maximum_speed_rad_s[i] > 0.0 else {
      fail("elbow adapter range or speed invalid")
    }
  }
}

///|
/// No SDK, inference or autonomous fallback is owned by this pure adapter.
pub struct Adapter {
  priv settings : Settings
  priv hold : Array[@low.MotorCommand]
  priv mut commands : Array[@low.MotorCommand]
  priv mut last_ms : Int64?
}

///|
pub(all) struct Step {
  commands : Array[@low.MotorCommand]
  raw_elbow_rad : Array[Double]
  requested_elbow_rad : Array[Double]
  bounded_elbow_rad : Array[Double]
  rate_limited : Array[Bool]
  authority : Double
}

///|
pub fn Adapter::new(
  settings : Settings,
  hold : ArrayView[@low.MotorCommand],
) -> Self raise {
  settings.validate()
  guard hold.length() == 24 &&
    hold.all(m => {
      finite(m.position) &&
      finite(m.kp) &&
      finite(m.kd) &&
      m.kp >= 0.0 &&
      m.kd >= 0.0 &&
      m.velocity == 0.0 &&
      m.torque == 0.0
    }) else {
    fail("complete stationary finite hold required")
  }
  for i, slot in [3, 14] {
    guard hold[slot].position >= settings.lower_rad[i] &&
      hold[slot].position <= settings.upper_rad[i] &&
      hold[slot].kp > 0.0 else {
      fail("current elbow pose outside configured deployment range")
    }
  }
  {
    settings: {
      ..settings,
      lower_rad: settings.lower_rad.copy(),
      upper_rad: settings.upper_rad.copy(),
      maximum_speed_rad_s: settings.maximum_speed_rad_s.copy(),
    },
    hold: hold.to_owned(),
    commands: hold.to_owned(),
    last_ms: None,
  }
}

///|
/// A policy tick consumes new inference. Baseline/return are explicit handover
/// phases, never substitutes after an inference error. Filtering uses elapsed
/// host time; callers must still enforce sensor and inference freshness.
pub fn Adapter::preview(
  self : Self,
  nominal : ArrayView[@low.MotorCommand],
  now_ms : Int64,
  policy_elapsed_ms : Int64,
  phase : String,
) -> Step raise {
  guard nominal.length() == 24 &&
    nominal.all(m => finite(m.position)) &&
    now_ms >= 0L &&
    policy_elapsed_ms >= 0L &&
    (phase == "baseline" || phase == "policy" || phase == "return") else {
    fail("invalid inferred command or actor phase")
  }
  let dt = match self.last_ms {
    None => 0L
    Some(last) => {
      guard now_ms > last && now_ms - last <= 40L else {
        fail("actor adapter tick gap or reversal")
      }
      now_ms - last
    }
  }
  let u = (policy_elapsed_ms.to_double() / self.settings.engage_ms.to_double()).min(
    1.0,
  )
  let authority = if phase == "policy" {
    self.settings.policy_authority * u * u * u * (10.0 + u * (-15.0 + 6.0 * u))
  } else {
    0.0
  }
  let raw = [nominal[3].position, nominal[14].position]
  let requested = Array::makei(2, i => {
    self.hold[if i == 0 { 3 } else { 14 }].position +
    authority * (raw[i] - self.hold[if i == 0 { 3 } else { 14 }].position)
  })
  let bounded = Array::makei(2, i => {
    requested[i].max(self.settings.lower_rad[i]).min(self.settings.upper_rad[i])
  })
  let limited = Array::make(2, false)
  let result = self.hold.copy()
  for i, slot in [3, 14] {
    let desired = bounded[i]
    let delta = (desired - self.commands[slot].position) *
      dt.to_double() /
      (self.settings.response_ms.to_double() + dt.to_double())
    let maximum = self.settings.maximum_speed_rad_s[i] * dt.to_double() / 1000.0
    let shift = if phase == "return" &&
      (desired - self.commands[slot].position).abs() <= maximum {
      desired - self.commands[slot].position
    } else {
      delta.max(-maximum).min(maximum)
    }
    limited[i] = shift != delta && phase == "policy"
    result[slot] = {
      ..self.hold[slot],
      position: self.commands[slot].position + shift,
    }
  }
  {
    commands: result,
    raw_elbow_rad: raw,
    requested_elbow_rad: requested,
    bounded_elbow_rad: bounded,
    rate_limited: limited,
    authority,
  }
}

///|
/// Commit a proposal. `preview` evaluates counterfactual predictions against
/// this same command state without changing its clock or any motor target.
pub fn Adapter::next(
  self : Self,
  nominal : ArrayView[@low.MotorCommand],
  now_ms : Int64,
  policy_elapsed_ms : Int64,
  phase : String,
) -> Step raise {
  let step = self.preview(nominal, now_ms, policy_elapsed_ms, phase)
  self.commands = step.commands.copy()
  self.last_ms = Some(now_ms)
  step
}

///|
pub fn Adapter::returned(self : Self) -> Bool {
  [3, 14].all(slot => self.commands[slot].position == self.hold[slot].position)
}
