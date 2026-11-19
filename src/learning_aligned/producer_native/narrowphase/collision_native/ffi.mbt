///|
priv type Handle

///|
#borrow(adapter, library, mjb)
extern "c" fn open_native(
  adapter : Bytes,
  library : Bytes,
  mjb : Bytes,
  capacity : Int32,
) -> Handle = "moonrobo_collision_open"

///|
#borrow(handle)
extern "c" fn error_native(handle : Handle) -> Bytes = "moonrobo_collision_error"

///|
#borrow(handle)
extern "c" fn json_native(handle : Handle) -> Bytes = "moonrobo_collision_json"

///|
#borrow(handle, qpos)
extern "c" fn collide_native(
  handle : Handle,
  qpos : FixedArray[Double],
) -> Int32 = "moonrobo_collision_run"

///|
#borrow(handle)
extern "c" fn close_native(handle : Handle) -> Unit = "moonrobo_collision_close"

///|
/// GC owned explicit MuJoCo CPU/Double collision session. No Newton/Warp state.
pub struct Session {
  priv handle : Handle
}

///|
fn Handle::check(self : Handle) -> Unit raise {
  let error = @utf8.decode(error_native(self))
  guard error == "" else { fail(error) }
}

///|
pub fn Session::open(
  adapter : String,
  library : String,
  mjb : String,
  contact_capacity : Int32,
) -> Session raise {
  guard contact_capacity >= 0 &&
    [adapter, library, mjb].all(p => !p.is_empty() && !p.contains("\u{0}")) else {
    fail(
      "explicit NUL-free native collision paths and nonnegative capacity required",
    )
  }
  let handle = open_native(
    @utf8.encode(adapter),
    @utf8.encode(library),
    @utf8.encode(mjb),
    contact_capacity,
  )
  errdefer close_native(handle)
  handle.check()
  { handle, }
}

///|
/// Execute actual rigid native collision only when explicitly called. qpos uses
/// the MJB's MuJoCo order, with unit wxyz quaternions; no silent normalization.
pub fn Session::collide(self : Session, qpos : Array[Double]) -> Json raise {
  self.handle.check()
  let values = FixedArray::makei(qpos.length(), i => qpos[i])
  let status = collide_native(self.handle, values)
  self.handle.check()
  guard status == 0 else {
    fail("native collision returned unsuccessful status")
  }
  let result = @json.parse(@utf8.decode(json_native(self.handle)))
  guard result is { "format": "moonrobo-mujoco-native-collision-v1", .. } else {
    fail("native collision report format mismatch")
  }
  result
}

///|
pub fn Session::close(self : Session) -> Unit {
  close_native(self.handle)
}
