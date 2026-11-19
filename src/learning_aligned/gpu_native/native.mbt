///|
type NativeHandle

///|
#borrow(library)
extern "c" fn open_native(
  library : Bytes,
  device : Int32,
  worlds : Int32,
) -> NativeHandle = "mr_mbt_apic_open"

///|
#borrow(handle)
extern "c" fn error_native(handle : NativeHandle) -> Bytes = "mr_mbt_apic_error"

///|
#borrow(handle)
extern "c" fn close_native(handle : NativeHandle) -> Unit = "mr_mbt_apic_close"

///|
#borrow(handle, path)
extern "c" fn graph_native(
  handle : NativeHandle,
  role : Int32,
  path : Bytes,
) -> Bool = "mr_mbt_apic_graph"

///|
#borrow(handle, name)
extern "c" fn share_native(
  handle : NativeHandle,
  name : Bytes,
  bytes : Int64,
  scalar : Int32,
) -> Bool = "mr_mbt_apic_share"

///|
#borrow(handle, name, binding)
extern "c" fn view_native(
  handle : NativeHandle,
  name : Bytes,
  binding : Bytes,
  offset : Int64,
  row : Int64,
  component : Int64,
  width : Int32,
  scalar : Int32,
) -> Bool = "mr_mbt_apic_view"

///|
#borrow(handle)
extern "c" fn origin_native(
  handle : NativeHandle,
  world : Int32,
  x : Double,
  y : Double,
  z : Double,
) -> Bool = "mr_mbt_apic_origin"

///|
#borrow(handle)
extern "c" fn operation_native(
  handle : NativeHandle,
  operation : Int32,
) -> Bool = "mr_mbt_apic_operation"

///|
#borrow(handle, output)
extern "c" fn read_native(
  handle : NativeHandle,
  output : FixedArray[Double],
) -> Bool = "mr_mbt_apic_read"

///|
#borrow(handle, targets)
extern "c" fn step_native(
  handle : NativeHandle,
  targets : FixedArray[Double],
) -> Bool = "mr_mbt_apic_step"

///|
#borrow(handle, mask, state)
extern "c" fn reset_native(
  handle : NativeHandle,
  mask : FixedArray[Double],
  state : FixedArray[Double],
) -> Bool = "mr_mbt_apic_reset"

///|
#borrow(handle, binding)
extern "c" fn context_native(
  handle : NativeHandle,
  binding : Bytes,
  index : Int64,
  value : Double,
) -> Bool = "mr_mbt_apic_context"

///|
fn c_string(value : String) -> Bytes raise {
  guard !value.contains("\u{0}") else { fail("NUL in native APIC name/path") }
  @utf8.encode(value + "\u{0}")
}

///|
fn checked(handle : NativeHandle, success : Bool) -> Unit raise {
  guard success else {
    fail("native APIC: " + @utf8.decode_lossy(error_native(handle)))
  }
}

///|
/// A real loaded Warp CUDA physics artifact. The library is GC-owned and may
/// also be closed explicitly after the last environment use.
pub struct NativeBatch {
  handle : NativeHandle
  manifest : Manifest
  provenance : Json
}

///|
pub fn NativeBatch::close(self : NativeBatch) -> Unit {
  close_native(self.handle)
}

///|
pub fn NativeBatch::identity(self : NativeBatch) -> Json {
  self.provenance
}

///|
fn NativeBatch::read_states(self : NativeBatch) -> Array[@aligned.State] raise {
  let output = FixedArray::make(self.manifest.num_envs * 71, 0.0)
  checked(self.handle, read_native(self.handle, output))
  guard output.all(v => !v.is_nan() && !v.is_inf()) else {
    fail("nonfinite CUDA physical state")
  }
  Array::makei(self.manifest.num_envs, i => {
    @aligned.unflatten_state(Array::makei(71, j => output[71 * i + j]))
  })
}

///|
fn valid_ids(ids : Array[Int32], n : Int32) -> Unit raise {
  let seen = []
  for id in ids {
    guard id >= 0 && id < n && !seen.contains(id) else {
      fail("native GPU IDs must be unique and in range")
    }
    seen.push(id)
  }
}

///|
fn NativeBatch::reset(
  self : NativeBatch,
  ids : Array[Int32],
  states : Array[@aligned.State],
) -> Unit raise {
  valid_ids(ids, self.manifest.num_envs)
  guard ids.length() == states.length() else {
    fail("one CUDA reset state required per selected world")
  }
  if ids.is_empty() {
    return
  }
  let mask = FixedArray::make(self.manifest.num_envs, 0.0)
  // Masked-out rows remain finite identity states and are never applied by the
  // captured vendor mask setters; no device state read is needed for reset.
  let flat = FixedArray::make(self.manifest.num_envs * 71, 0.0)
  for i in 0..<self.manifest.num_envs {
    flat[71 * i + 3] = 1.0
  }
  for k, id in ids {
    let values = @aligned.flatten_state(states[k])
    guard values.length() == 71 && values.all(v => !v.is_nan() && !v.is_inf()) else {
      fail("invalid CUDA reset state")
    }
    mask[id] = 1.0
    for j in 0..<71 {
      flat[71 * id + j] = values[j]
    }
  }
  checked(self.handle, reset_native(self.handle, mask, flat))
  checked(self.handle, operation_native(self.handle, 1))
}

///|
fn NativeBatch::context(
  self : NativeBatch,
  ids : Array[Int32],
  rows : Array[Array[Double]],
  ground_mu : Double,
) -> Unit raise {
  valid_ids(ids, self.manifest.num_envs)
  guard ids.length() == rows.length() && ground_mu > 0.0 && !ground_mu.is_inf() else {
    fail("invalid CUDA context rows/friction")
  }
  let maps = self.manifest.context_writes
  for k, id in ids {
    let row = rows[k]
    guard row.length() == 33 &&
      row.all(v => !v.is_nan() && !v.is_inf()) &&
      row[0] > 0.0 else {
      fail("invalid 33-dimensional CUDA context")
    }
    for index in maps.shape_friction.indices[id] {
      checked(
        self.handle,
        context_native(
          self.handle,
          c_string(maps.shape_friction.binding),
          index.to_int64(),
          row[0],
        ),
      )
    }
    for j in 0..<3 {
      checked(
        self.handle,
        context_native(
          self.handle,
          c_string(maps.torso_com.binding),
          maps.torso_com.indices[id][j].to_int64(),
          maps.torso_com.base[id][j] + row[30 + j],
        ),
      )
    }
  }
  for index in maps.ground_friction.indices {
    checked(
      self.handle,
      context_native(
        self.handle,
        c_string(maps.ground_friction.binding),
        index.to_int64(),
        ground_mu,
      ),
    )
  }
  checked(self.handle, operation_native(self.handle, 2))
  checked(self.handle, operation_native(self.handle, 1))
}

///|
pub fn NativeBatch::adapter(self : NativeBatch) -> @protocol.BatchAdapter {
  {
    backend: "isaac-newton-mujoco-warp-apic",
    num_envs: self.manifest.num_envs,
    joint_names: self.manifest.joint_names.copy(),
    read_states: () => self.read_states(),
    write_resets: (ids, states) => self.reset(ids, states),
    apply_context: (ids, rows, ground) => self.context(ids, rows, ground),
    step_substeps: (targets, count, dt) => {
      guard count == 4 &&
        dt == 0.005 &&
        targets.length() == self.manifest.num_envs &&
        targets.all(row => {
          row.length() == 29 && row.all(v => !v.is_nan() && !v.is_inf())
        }) else {
        fail(
          "APIC artifact requires finite N by 29 targets and four .005-second substeps",
        )
      }
      let flat = FixedArray::makei(self.manifest.num_envs * 29, i => {
        targets[i / 29][i % 29]
      })
      checked(self.handle, step_native(self.handle, flat))
      // Each native operation already synchronizes its CUDA stream before return.
      // This checks liveness rather than scheduling a second physical operation.
    },
    synchronize: () => {
      guard @utf8.decode_lossy(error_native(self.handle)) == "" else {
        fail("native APIC runtime is closed or has a pending error")
      }
    },
  }
}
