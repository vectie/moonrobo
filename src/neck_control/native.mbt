///|
#borrow(path)
extern "c" fn serial_open(path : Bytes) -> Int32 = "moonrobo_neck_open"

///|
extern "c" fn serial_close(fd : Int32) -> Unit = "moonrobo_neck_close"

///|
#borrow(tx)
extern "c" fn serial_exchange(
  fd : Int32,
  tx : Bytes,
  expected : Int32,
  expires_at : Int64,
) -> Bytes = "moonrobo_neck_exchange"

///|
#borrow(path, line)
extern "c" fn audit_append(path : Bytes, line : Bytes) -> Int32 = "moonrobo_neck_audit"

///|
#borrow(path)
extern "c" fn fault_exists(path : Bytes) -> Int32 = "moonrobo_neck_fault_exists"

///|
#borrow(path)
extern "c" fn latch_fault(path : Bytes) -> Int32 = "moonrobo_neck_latch_fault"

///|
#borrow(path)
extern "c" fn clear_fault(path : Bytes) -> Int32 = "moonrobo_neck_clear_fault"

///|
#borrow(path)
extern "c" fn consume_receipt(path : Bytes) -> Int32 = "moonrobo_neck_consume_receipt"

///|
extern "c" fn native_error() -> Bytes = "moonrobo_neck_error"

///|
extern "c" fn clock_ms() -> Int64 = "moonrobo_neck_clock"

///|
pub extern "c" fn epoch_ms() -> Int64 = "moonrobo_neck_epoch"

///|
extern "c" fn sleep_ms(ms : Int32) -> Unit = "moonrobo_neck_sleep"

///|
extern "c" fn interrupted() -> Int32 = "moonrobo_neck_interrupted"

///|
priv type JoyDevice

///|
extern "c" fn joy_open() -> JoyDevice = "moonrobo_joy_open"

///|
#borrow(device)
extern "c" fn joy_valid(device : JoyDevice) -> Int32 = "moonrobo_joy_valid"

///|
#borrow(device)
extern "c" fn joy_event_fd(device : JoyDevice) -> Int32 = "moonrobo_joy_event_fd"

///|
#borrow(device)
extern "c" fn joy_close(device : JoyDevice) -> Unit = "moonrobo_joy_close"

///|
#borrow(device)
extern "c" fn joy_read(device : JoyDevice) -> Bytes = "moonrobo_joy_read"

///|
extern "c" fn joy_error() -> Bytes = "moonrobo_joy_error"

///|
#borrow(device, packet)
extern "c" fn joy_write_setup(device : JoyDevice, packet : Bytes) -> Int32 = "moonrobo_joy_write_setup"

///|
#borrow(device, packet)
extern "c" fn joy_setup_reply(device : JoyDevice, packet : Bytes) -> Bytes = "moonrobo_joy_setup_reply"

///|
#borrow(tx)
extern "c" fn serial_exchange_guarded(
  fd : Int32,
  tx : Bytes,
  expected : Int32,
  expires_at : Int64,
  input_fd : Int32,
) -> Bytes = "moonrobo_neck_exchange_guarded"
