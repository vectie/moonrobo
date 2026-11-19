///|
/// GC-owned loader for the real SDK C++ ABI adapter.
pub type Controller

///|
#borrow(library)
extern "c" fn open_native(library : Bytes) -> Controller = "moonrobo_sdk_open"

///|
#borrow(controller)
extern "c" fn error_native(controller : Controller) -> Bytes = "moonrobo_sdk_error"

///|
#borrow(controller)
extern "c" fn capture_native(controller : Controller) -> Int32 = "moonrobo_sdk_capture"

///|
#borrow(controller)
extern "c" fn value_native(controller : Controller, index : Int32) -> Double = "moonrobo_sdk_value"

///|
#borrow(controller)
extern "c" fn publish_native(
  controller : Controller,
  vertical : Double,
  horizontal : Double,
  action : Int32,
  data : Int32,
) -> Int32 = "moonrobo_sdk_publish"

///|
/// Loading initializes DDS; callers explicitly choose live mode and library path.
pub fn Controller::open(library : String) -> Controller raise BridgeError {
  let controller = open_native(@utf8.encode(library))
  let error = @utf8.decode_lossy(error_native(controller))
  if error != "" {
    raise Invalid(error)
  }
  controller
}

///|
pub fn Controller::snapshot(
  self : Controller,
  frame_id : String,
  captured_at_ms : Int64,
) -> @sdk.SdkE1Snapshot raise BridgeError {
  if capture_native(self) != 0 {
    raise Invalid(@utf8.decode_lossy(error_native(self)))
  }
  {
    frame_id,
    captured_at_ms,
    mode: value_native(self, 170).to_int(),
    telemetry_age_ms: value_native(self, 171).to_int(),
    joints: Array::makei(24, i => {
      motor_id: value_native(self, 6 * i).to_int(),
      position: value_native(self, 6 * i + 1),
      velocity: value_native(self, 6 * i + 2),
      torque: value_native(self, 6 * i + 3),
      error: value_native(self, 6 * i + 4).to_int(),
      temperature: value_native(self, 6 * i + 5).to_int(),
    }),
    imu: Some({
      orientation: Array::makei(4, i => value_native(self, 144 + i)),
      angular_velocity: Array::makei(3, i => value_native(self, 148 + i)),
      linear_acceleration: Array::makei(3, i => value_native(self, 151 + i)),
    }),
    joy: Some({
      axes: Array::makei(2, i => value_native(self, 154 + i)),
      buttons: Array::makei(14, i => value_native(self, 156 + i).to_int()),
    }),
    errors: [],
  }
}

///|
pub fn Controller::publish(
  self : Controller,
  command : @sdk.SdkE1HighControlCommand,
) -> Json raise BridgeError {
  let errors = validate_command(command)
  if !errors.is_empty() {
    raise Invalid(errors.join("; "))
  }
  let action = match command.action {
    "WALK" => 0
    "RUN" => 4
    _ => 12
  }
  if command.data < 0 || command.data > 65535 {
    raise Invalid("SDK data must fit uint16")
  }
  if publish_native(
      self,
      command.vertical,
      command.horizontal,
      action,
      command.data,
    ) !=
    0 {
    raise Invalid(@utf8.decode_lossy(error_native(self)))
  }
  {
    "published": true,
    "intent_id": command.intent_id,
    "action": command.action,
  }
}
