///|
/// Explicit offline execution configuration. Parsing/validation never executes
/// CUDA; execute does. All paths point to existing bytes with explicit SHA pins.
pub(all) struct ModuleInput {
  id : String
  directory : String
  manifest_sha256 : String
} derive(FromJson, ToJson)

///|
pub(all) struct BufferInput {
  name : String
  path : String
  sha256 : String
  scalar_type : String
} derive(FromJson, ToJson)

///|
/// Imports the actual finalizer's layout.json and exact raw array files.
pub(all) struct HostImport {
  prefix : String
  directory : String
  manifest_sha256 : String
} derive(FromJson, ToJson)

///|
pub(all) struct Command {
  operation : String
  parameters : Json
} derive(FromJson, ToJson)

///|
pub(all) struct Config {
  dispatch_plugin : String
  writer_plugin : String
  warp_library : String
  device_ordinal : Int32
  architecture : Int32
  modules : Array[ModuleInput]
  buffers : Array[BufferInput]
  host_imports : Array[HostImport]
  program : Array[Command]
  mode : String
  launch_captured_graph : Bool
  output : String
} derive(FromJson, ToJson)

///|
pub(all) struct View {
  buffer : String
  dtype : String
  shape : Array[Int32]
  byte_strides : Array[Int32]
  offset_bytes : UInt64
} derive(FromJson, ToJson)

///|
pub(all) struct Launch {
  module : String
  entry : String
  arguments : Map[String, Json]
} derive(FromJson, ToJson)

///|
pub(all) struct Copy {
  source : String
  source_offset : UInt64
  destination : String
  destination_offset : UInt64
  count_bytes : UInt64
} derive(FromJson, ToJson)

///|
pub(all) struct Zero {
  buffer : String
  offset_bytes : UInt64
  count_bytes : UInt64
} derive(FromJson, ToJson)

///|
struct Branch {
  condition : View
  on_true : Array[Command]
  on_false : Array[Command]
} derive(FromJson)

///|
struct Loop {
  condition : View
  body : Array[Command]
} derive(FromJson)

///|
pub(all) struct HostBuffer {
  name : String
  scalar_type : String
  bytes : Bytes
}

///|
struct Parameter {
  name : String
  c_type : String
  kind : String
  dtype : String
  rank : Int32
  access : String
} derive(FromJson, ToJson)

///|
struct Entry {
  key : String
  forward : String
  shape : Array[Int32]
  parameters : Array[Parameter]
}

///|
struct LaunchPolicy {
  block_dim : Int32
  forward_smem : Int32
  backward_smem : Int32
  grid_stride : Bool
  coord_mult : Int32
} derive(FromJson, ToJson)

///|
struct Module {
  id : String
  kind : String
  request : Json
  manifest : Bytes
  manifest_sha256 : String
  source : Bytes
  source_name : String
  source_sha256 : String
  image : Bytes
  image_kind : String
  image_sha256 : String
  specialization_sha256 : String
  entries : Map[String, Entry]
  policy : LaunchPolicy
  notice : Bytes?
}

///|
enum Argument {
  Array(View, Int32)
  Int32(Int32)
  Boolean(Bool)
  Float32(Float)
  Float64(Double)
}

///|
struct Call {
  module : String
  entry : Entry
  arguments : Array[Argument]
  named : Map[String, View]
}

///|
enum Op {
  Kernel(Call)
  CopyBytes(Copy)
  ZeroBytes(Zero)
  If(View, Array[Op], Array[Op])
  While(View, Array[Op])
}

///|
struct Prepared {
  modules : Map[String, Module]
  buffers : Map[String, HostBuffer]
  program : Array[Op]
  narrowphase : Call?
  convergence : Array[Call]
  convex : Call?
  convex_contacts : Call?
  tiles : Array[Call]
  sticky_status : Array[StickyStatus]
  line_flags : Array[StickyStatus]
  dispatch_plugin : String
  writer_plugin : String
  warp_library : String
}

///|
/// Persistent per-world native solver failure state, shared only by kernels
/// authenticated as belonging to one concrete module specialization.
struct StickyStatus {
  module : String
  view : View
}

///|
fn fields(value : Json, allowed : Array[String]) -> Map[String, Json] raise {
  guard value is Object(items) &&
    items.length() == allowed.length() &&
    items.keys().all(key => allowed.contains(key)) else {
    fail("GPU pipeline object contains missing or unknown fields")
  }
  items
}

///|
fn field(value : Json, key : String) -> Json raise {
  guard value is Object(items) && items.get(key) is Some(result) else {
    fail("GPU pipeline missing field: " + key)
  }
  result
}

///|
fn text(value : Json, key : String) -> String raise {
  @json.from_json(field(value, key))
}

///|
fn identifier(value : String) -> Bool {
  !value.is_empty() &&
  value.length() <= 128 &&
  value
  .iter()
  .all(c => {
    (c >= 'a' && c <= 'z') ||
    (c >= 'A' && c <= 'Z') ||
    (c >= '0' && c <= '9') ||
    c == '_' ||
    c == '-' ||
    c == '.'
  })
}

///|
/// Strict top-level and nested pipeline records. Program payloads are strictly
/// checked by their typed decoder before any native resource is initialized.
pub fn decode_config(value : Json) -> Config raise {
  ignore(
    fields(value, [
      "dispatch_plugin", "writer_plugin", "warp_library", "device_ordinal", "architecture",
      "modules", "buffers", "host_imports", "program", "mode", "launch_captured_graph",
      "output",
    ]),
  )
  let config : Config = @json.from_json(value)
  guard field(value, "modules") is Array(modules) &&
    field(value, "buffers") is Array(buffers) &&
    field(value, "host_imports") is Array(imports) else {
    fail("GPU pipeline input records must be arrays")
  }
  for item in modules {
    ignore(fields(item, ["id", "directory", "manifest_sha256"]))
  }
  for item in buffers {
    ignore(fields(item, ["name", "path", "sha256", "scalar_type"]))
  }
  for item in imports {
    ignore(fields(item, ["prefix", "directory", "manifest_sha256"]))
  }
  check_commands(field(value, "program"), 0, Ref(0))
  config
}

///|
fn check_commands(
  value : Json,
  depth : Int32,
  count : Ref[Int32],
) -> Unit raise {
  guard depth <= 32 && value is Array(commands) else {
    fail("GPU pipeline command nesting exceeds 32 or is not an array")
  }
  for command in commands {
    count.val += 1
    guard count.val <= 4096 else {
      fail("GPU pipeline exceeds 4096 static commands")
    }
    ignore(fields(command, ["operation", "parameters"]))
    let parameters = field(command, "parameters")
    match text(command, "operation") {
      "launch" => ignore(fields(parameters, ["module", "entry", "arguments"]))
      "copy" =>
        ignore(
          fields(parameters, [
            "source", "source_offset", "destination", "destination_offset", "count_bytes",
          ]),
        )
      "zero" =>
        ignore(fields(parameters, ["buffer", "offset_bytes", "count_bytes"]))
      "if" => {
        ignore(fields(parameters, ["condition", "on_true", "on_false"]))
        ignore(strict_view(field(parameters, "condition")))
        check_commands(field(parameters, "on_true"), depth + 1, count)
        check_commands(field(parameters, "on_false"), depth + 1, count)
      }
      "while" => {
        ignore(fields(parameters, ["condition", "body"]))
        ignore(strict_view(field(parameters, "condition")))
        check_commands(field(parameters, "body"), depth + 1, count)
      }
      _ => fail("unknown GPU pipeline operation")
    }
  }
}

///|
fn finite(value : Double) -> Bool {
  !value.is_nan() && !value.is_inf()
}

///|
fn scalar_width(dtype : String) -> Int32 raise {
  match dtype {
    "bool" => 1
    "int32" | "float32" => 4
    "int64" | "uint64" | "float64" => 8
    _ => fail("unsupported owned primitive GPU buffer type")
  }
}

///|
/// Tags are translated without converting or repacking any input byte.
pub fn host_scalar_type(tag : String) -> String raise {
  match tag {
    "i32" => "int32"
    "i64" => "int64"
    "u64" => "uint64"
    "f32" => "float32"
    "f64" => "float64"
    "bool" => "bool"
    _ => fail("unsupported finalized scalar tag")
  }
}

///|
fn element(dtype : String) -> (String, Int32) raise {
  match dtype {
    "bool" => ("bool", 1)
    "int32" => ("int32", 4)
    "int64" => ("int64", 8)
    "float32" => ("float32", 4)
    "float64" => ("float64", 8)
    "vec2i" => ("int32", 8)
    "vec2f" => ("float32", 8)
    "vec3f" => ("float32", 12)
    "vec4f" => ("float32", 16)
    "vec5f" => ("float32", 20)
    "mat33f" => ("float32", 36)
    "transformf" => ("float32", 28)
    "spatial_vectorf" => ("float32", 24)
    _ => fail("unsupported generated kernel dtype")
  }
}
