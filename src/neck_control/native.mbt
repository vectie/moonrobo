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
