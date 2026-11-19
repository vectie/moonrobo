///|
#borrow(handle, name, output)
extern "c" fn audit_view_native(
  handle : NativeHandle,
  name : Bytes,
  output : FixedArray[Double],
) -> Bool = "mr_mbt_apic_audit_view"

///|
#borrow(handle, name, worlds, output)
extern "c" fn audit_view_selected_native(
  handle : NativeHandle,
  name : Bytes,
  worlds : FixedArray[Int32],
  output : FixedArray[Double],
) -> Bool = "mr_mbt_apic_audit_view_selected"

///|
#borrow(handle, worlds, output)
extern "c" fn audit_read_selected_native(
  handle : NativeHandle,
  worlds : FixedArray[Int32],
  output : FixedArray[Double],
) -> Bool = "mr_mbt_apic_audit_read_selected"

///|
#borrow(handle)
extern "c" fn audit_capacity_native(
  handle : NativeHandle,
  maximum_worlds : Int32,
) -> Bool = "mr_mbt_apic_audit_capacity_v1"

///|
fn NativeBatch::prepare_audit_capacity(self : NativeBatch) -> Unit raise {
  match self.manifest.profile() {
    Initial => () // Retain compatibility with the existing optional audit ABI.
    Paper4096 => checked(self.handle, audit_capacity_native(self.handle, 4096))
  }
}

///|
#borrow(handle)
extern "c" fn audit_free_native(handle : NativeHandle) -> Int64 = "mr_mbt_apic_audit_free_bytes"

///|
/// Creates only a CUDA context/Warp runtime to query current free device memory;
/// no physics graphs are loaded. Called before the bounded audit load.
pub fn audit_device_free_bytes(
  library : String,
  device_id~ : Int32 = 0,
) -> Int64 raise {
  guard device_id >= 0 else { fail("negative audit CUDA device") }
  let handle = open_native(c_string(library), device_id, 2)
  defer close_native(handle)
  guard @utf8.decode_lossy(error_native(handle)) == "" else {
    fail(
      "native APIC memory query: " + @utf8.decode_lossy(error_native(handle)),
    )
  }
  let free = audit_free_native(handle)
  checked(handle, free > 0L)
  free
}

///|
/// Inspect only a temporary two-world native handle with no loaded graphs.
/// Paper explicitly configures the optional selected-audit capacity and checks
/// its required symbols before reading CUDA free memory. This is capability
/// negotiation, not a physics load or a memory-peak measurement. The temporary
/// capacity field is discarded when the handle is closed.
pub async fn inspect_runtime_library(
  adapter_library : String,
  device_id~ : Int32 = 0,
  capacity_profile~ : @capacity.CapacityProfile = Initial,
) -> Json {
  guard device_id >= 0 else { fail("negative inspection CUDA device") }
  let (identity, digest) = validated_adapter(adapter_library)
  assert_bundle_identity(identity)
  let handle = open_native(c_string(identity.path), device_id, 2)
  defer close_native(handle)
  checked(handle, @utf8.decode_lossy(error_native(handle)) == "")
  let paper = capacity_profile == @capacity.Paper4096
  if paper {
    checked(handle, audit_capacity_native(handle, 4096))
  }
  let free = audit_free_native(handle)
  checked(handle, free > 0L)
  assert_bundle_identity(identity)
  {
    "format": "moonrobo.apic-runtime-inspection.v1",
    "adapter_library": Json(identity.path),
    "adapter_library_sha256": Json(digest),
    "cuda_device_index": Json(device_id),
    "probe_num_envs": 2,
    "capacity_profile": Json(capacity_profile.name()),
    "cuda_free_bytes": Json(free),
    "cuda_total_bytes": Json::null(),
    "paper_selected_audit_capacity_checked": Json(paper),
    "paper_selected_audit_capacity_confirmed": Json(paper),
    "no_graphs_loaded": true,
    "physics_validated": false,
  }
}

///|
#borrow(handle, binding, indices, output)
extern "c" fn audit_values_native(
  handle : NativeHandle,
  binding : Bytes,
  indices : FixedArray[Int64],
  output : FixedArray[Double],
) -> Bool = "mr_mbt_apic_audit_values"

///|
pub(all) struct AuditReadback {
  state71 : Array[Array[Double]]
  root_pose : Array[Array[Double]]
  root_com_velocity : Array[Array[Double]]
  root_com_local : Array[Array[Double]]
  joint_position : Array[Array[Double]]
  joint_velocity : Array[Array[Double]]
  shape_friction : Array[Array[Double]]
  torso_com : Array[Array[Double]]
  ground_friction : Array[Double]
} derive(ToJson, FromJson)

///|
pub fn NativeBatch::refresh(self : NativeBatch) -> Unit raise {
  checked(self.handle, operation_native(self.handle, 1))
}

///|
fn finite_audit(values : FixedArray[Double]) -> Unit raise {
  guard values.all(v => !v.is_nan() && !v.is_inf()) else {
    fail("nonfinite APIC audit readback")
  }
}

///|
fn NativeBatch::audit_view(
  self : NativeBatch,
  name : String,
  width : Int32,
) -> Array[Array[Double]] raise {
  let values = FixedArray::make(2 * width, 0.0)
  checked(self.handle, audit_view_native(self.handle, c_string(name), values))
  finite_audit(values)
  Array::makei(2, i => Array::makei(width, j => values[i * width + j]))
}

///|
fn NativeBatch::audit_values(
  self : NativeBatch,
  binding : String,
  indices : Array[Int32],
) -> Array[Double] raise {
  guard !indices.is_empty() && indices.length() <= 4096 else {
    fail("APIC property audit requires 1..4096 scalar indices")
  }
  let output = FixedArray::make(indices.length(), 0.0)
  checked(
    self.handle,
    audit_values_native(
      self.handle,
      c_string(binding),
      FixedArray::makei(indices.length(), i => indices[i].to_int64()),
      output,
    ),
  )
  finite_audit(output)
  Array::makei(output.length(), i => output[i])
}

///|
/// Exactly two worlds, primitive registered properties only. No scene clone,
/// mutation, SDK getter or graph launch occurs while reading this snapshot.
pub fn NativeBatch::audit_readback(self : NativeBatch) -> AuditReadback raise {
  guard self.manifest.num_envs == 2 else {
    fail("bounded APIC audit requires exactly two worlds")
  }
  let flat = FixedArray::make(142, 0.0)
  checked(self.handle, read_native(self.handle, flat))
  finite_audit(flat)
  let maps = self.manifest.context_writes
  {
    state71: Array::makei(2, i => Array::makei(71, j => flat[i * 71 + j])),
    root_pose: self.audit_view("root_pose", 7),
    root_com_velocity: self.audit_view("root_com_velocity", 6),
    root_com_local: self.audit_view("root_com_local", 3),
    joint_position: self.audit_view("joint_position", 29),
    joint_velocity: self.audit_view("joint_velocity", 29),
    shape_friction: maps.shape_friction.indices.map(indices => {
      self.audit_values(maps.shape_friction.binding, indices)
    }),
    torso_com: maps.torso_com.indices.map(indices => {
      self.audit_values(maps.torso_com.binding, indices)
    }),
    ground_friction: self.audit_values(
      maps.ground_friction.binding,
      maps.ground_friction.indices,
    ),
  }
}

///|
pub fn NativeBatch::audit_layout(self : NativeBatch) -> Json {
  {
    "num_envs": self.manifest.num_envs,
    "env_origins": Json(self.manifest.env_origins),
    "torso_com_base": Json(self.manifest.context_writes.torso_com.base),
  }
}

///|
/// Validates the small audit boundary before allocating any native staging.
pub fn validate_audit_worlds(
  num_envs : Int32,
  worlds : Array[Int32],
  capacity_profile~ : @capacity.CapacityProfile = Initial,
) -> Unit raise {
  guard num_envs >= 1 &&
    num_envs <= capacity_profile.limits().max_environments &&
    worlds.length() >= 1 &&
    worlds.length() <= 3 else {
    fail("selected APIC audit exceeds capacity profile or 1..3 selected rows")
  }
  for i, world in worlds {
    guard world >= 0 && world < num_envs && !worlds[:i].contains(world) else {
      fail("invalid or duplicate selected APIC world")
    }
  }
}

///|
fn NativeBatch::audit_selected_view(
  self : NativeBatch,
  name : String,
  width : Int32,
  worlds : Array[Int32],
) -> Array[Array[Double]] raise {
  let output = FixedArray::make(worlds.length() * width, 0.0)
  checked(
    self.handle,
    audit_view_selected_native(
      self.handle,
      c_string(name),
      FixedArray::makei(worlds.length(), i => worlds[i]),
      output,
    ),
  )
  finite_audit(output)
  Array::makei(worlds.length(), i => {
    Array::makei(width, j => output[i * width + j])
  })
}

///|
/// Additive v2 readback. Only selected primitive rows cross the device boundary.
/// Each scalar-property row is capped at 4096 values and copied in 1024-value
/// chunks. The original two-world API and diagnostic ABI remain unchanged.
pub fn NativeBatch::audit_readback_selected(
  self : NativeBatch,
  worlds : Array[Int32],
) -> AuditReadback raise {
  validate_audit_worlds(
    self.manifest.num_envs,
    worlds,
    capacity_profile=self.manifest.profile(),
  )
  let maps = self.manifest.context_writes
  for world in worlds {
    guard maps.shape_friction.indices[world].length() <= 4096 &&
      maps.torso_com.indices[world].length() == 3 else {
      fail("selected APIC context audit row exceeds bound")
    }
  }
  guard maps.ground_friction.indices.length() <= 4096 else {
    fail("selected APIC ground audit row exceeds bound")
  }
  self.prepare_audit_capacity()
  let output = FixedArray::make(worlds.length() * 71, 0.0)
  checked(
    self.handle,
    audit_read_selected_native(
      self.handle,
      FixedArray::makei(worlds.length(), i => worlds[i]),
      output,
    ),
  )
  finite_audit(output)
  {
    state71: Array::makei(worlds.length(), i => {
      Array::makei(71, j => output[i * 71 + j])
    }),
    root_pose: self.audit_selected_view("root_pose", 7, worlds),
    root_com_velocity: self.audit_selected_view("root_com_velocity", 6, worlds),
    root_com_local: self.audit_selected_view("root_com_local", 3, worlds),
    joint_position: self.audit_selected_view("joint_position", 29, worlds),
    joint_velocity: self.audit_selected_view("joint_velocity", 29, worlds),
    shape_friction: worlds.map(world => {
      self.audit_chunked_values(
        maps.shape_friction.binding,
        maps.shape_friction.indices[world],
      )
    }),
    torso_com: worlds.map(world => {
      self.audit_chunked_values(
        maps.torso_com.binding,
        maps.torso_com.indices[world],
      )
    }),
    ground_friction: self.audit_chunked_values(
      maps.ground_friction.binding,
      maps.ground_friction.indices,
    ),
  }
}

///|
fn NativeBatch::audit_chunked_values(
  self : NativeBatch,
  binding : String,
  indices : Array[Int32],
) -> Array[Double] raise {
  guard !indices.is_empty() && indices.length() <= 4096 else {
    fail("selected APIC property audit requires 1..4096 scalars")
  }
  let result : Array[Double] = []
  for offset = 0; offset < indices.length(); {
    let end = (offset + 1024).min(indices.length())
    result.append(self.audit_values(binding, indices[offset:end].to_owned()))
    continue end
  }
  result
}

///|
pub fn NativeBatch::audit_layout_selected(
  self : NativeBatch,
  worlds : Array[Int32],
) -> Json raise {
  validate_audit_worlds(
    self.manifest.num_envs,
    worlds,
    capacity_profile=self.manifest.profile(),
  )
  {
    "num_envs": self.manifest.num_envs,
    "selected_worlds": Json(worlds),
    "env_origins": Json(worlds.map(world => self.manifest.env_origins[world])),
    "torso_com_base": Json(
      worlds.map(world => self.manifest.context_writes.torso_com.base[world]),
    ),
  }
}

///|
/// Reads only the real, named input views present in the captured manifest.
/// The old bundle contains no named solver/control-output views, so those are
/// explicitly unavailable; shared memory IDs are never guessed.
pub fn NativeBatch::audit_diagnostics(self : NativeBatch) -> Json raise {
  guard self.manifest.num_envs == 2 else {
    fail("bounded APIC diagnostics require exactly two worlds")
  }
  let inputs : Map[String, Json] = Map([])
  for
    (name, width) in [
      ("targets", 29),
      ("reset_pose", 7),
      ("reset_velocity", 6),
      ("reset_joint_position", 29),
      ("reset_joint_velocity", 29),
      ("reset_mask", 1),
    ] {
    inputs[name] = Json(self.audit_view(name, width))
  }
  let unavailable : Json = {
    "available": false,
    "reason": "current bundle has no semantic view; shared memory IDs are not inferred",
  }
  { "inputs": Json(inputs), "sdk_commands": unavailable, "solver": unavailable }
}
