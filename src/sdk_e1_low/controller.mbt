///|
priv type Handle

///|
#borrow(path)
extern "c" fn open_native(path : Bytes) -> Handle = "moonrobo_low_open"

///|
#borrow(handle)
extern "c" fn error_native(handle : Handle) -> Bytes = "moonrobo_low_error"

///|
#borrow(handle, values, age)
extern "c" fn capture_native(
  handle : Handle,
  values : FixedArray[Double],
  age : FixedArray[Int64],
) -> Int32 = "moonrobo_low_capture"

///|
#borrow(handle, name)
extern "c" fn index_native(handle : Handle, name : Bytes) -> Int32 = "moonrobo_low_joint_index"

///|
#borrow(handle, values)
extern "c" fn publish_native(
  handle : Handle,
  values : FixedArray[Double],
) -> Int32 = "moonrobo_low_publish"

///|
#borrow(handle)
extern "c" fn close_native(handle : Handle) -> Int32 = "moonrobo_low_close"

///|
/// Single synchronous owner. Opening a real plugin initializes the SDK/DDS.
/// Robot authority and stop behavior are separate from the host connection.
pub struct Controller {
  priv handle : Handle
  priv commands : FixedArray[Double]
}

///|
pub fn Controller::open(library : String) -> Self raise {
  guard library != "" && !library.contains("\u{0000}") else {
    fail("invalid SDK library path")
  }
  let handle = open_native(@utf8.encode(library))
  let error = @utf8.decode_lossy(error_native(handle))
  guard error == "" else { fail(error) }
  { handle, commands: FixedArray::make(120, 0.0), }
}

///|
/// Release this handle. The last supervised handle waits for the SDK worker
/// to exit. Legacy plugins report an unsupported operation.
pub fn Controller::close(self : Self) -> Unit raise {
  guard close_native(self.handle) == 0 else {
    fail(@utf8.decode_lossy(error_native(self.handle)))
  }
}

///|
/// Copies one coherent callback snapshot into reusable storage.
pub fn Controller::capture_into(self : Self, sample : Sample) -> Unit raise {
  sample.valid = false
  guard capture_native(self.handle, sample.values, sample.age) == 0 else {
    fail(@utf8.decode_lossy(error_native(self.handle)))
  }
  sample.valid = true
}

///|
pub fn Controller::joint_index(self : Self, name : String) -> Int32 raise {
  guard name != "" && !name.contains("\u{0000}") else {
    fail("invalid SDK joint name")
  }
  let index = index_native(self.handle, @utf8.encode(name))
  guard index >= 0 && index < 24 else {
    fail(@utf8.decode_lossy(error_native(self.handle)))
  }
  index
}

///|
fn finite(value : Double) -> Bool {
  value == value && value - value == 0.0
}

///|
/// Publish a full frame in SDK slot order; never map/pad actor outputs. Gains
/// must be finite/nonnegative. No MoonBit buffer is retained by the adapter.
pub fn Controller::publish(
  self : Self,
  commands : ArrayView[MotorCommand],
) -> Unit raise {
  guard commands.length() == 24 else {
    fail("SDK low control requires all 24 motor slots")
  }
  for index, command in commands {
    guard finite(command.position) &&
      finite(command.velocity) &&
      finite(command.torque) &&
      finite(command.kp) &&
      finite(command.kd) &&
      command.kp >= 0.0 &&
      command.kd >= 0.0 else {
      fail("invalid motor command or gain")
    }
    let base = index * 5
    self.commands[base] = command.position
    self.commands[base + 1] = command.velocity
    self.commands[base + 2] = command.torque
    self.commands[base + 3] = command.kp
    self.commands[base + 4] = command.kd
  }
  guard publish_native(self.handle, self.commands) == 0 else {
    fail(@utf8.decode_lossy(error_native(self.handle)))
  }
}
