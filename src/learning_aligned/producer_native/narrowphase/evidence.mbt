///|
fn definition(source : String, name : String) -> String raise {
  let lines = source.split("\n").map(s => s.to_owned()).collect()
  let mut start = -1
  for index, line in lines {
    if line.has_prefix("def " + name + "(") {
      guard start == -1 else {
        raise Unsupported::Invalid("duplicate source definition")
      }
      start = index
    }
  }
  guard start >= 0 else {
    raise Unsupported::Invalid("source definition missing: " + name)
  }
  let mut end = lines.length()
  let mut closed = lines[start].trim().has_suffix(":")
  for index in (start + 1)..<lines.length() {
    let line = lines[index]
    if !closed {
      if line.trim().has_suffix(":") {
        closed = true
      }
      continue
    }
    if !line.trim().is_empty() &&
      !line.has_prefix(" ") &&
      !line.has_prefix("\t") {
      end = index
      break
    }
  }
  guard closed else {
    raise Unsupported::Invalid("unterminated source definition")
  }
  while end > start && lines[end - 1].trim().is_empty() {
    end -= 1
  }
  let first = if start > 0 && lines[start - 1].has_prefix("@") {
    start - 1
  } else {
    start
  }
  lines[first:end].to_array().join("\n") + "\n"
}

///|
fn definitions_for(file : String) -> Array[String] {
  match file {
    "collision_primitive.py" =>
      [
        "_primitive_narrowphase", "plane_sphere_wrapper", "sphere_sphere_wrapper",
        "sphere_capsule_wrapper", "plane_capsule_wrapper", "sphere_box_wrapper",
        "plane_box_wrapper", "capsule_capsule_wrapper",
      ]
    "collision_primitive_core.py" =>
      [
        "plane_sphere", "sphere_sphere", "sphere_capsule", "plane_capsule", "sphere_box",
        "plane_box", "capsule_capsule",
      ]
    "collision_core.py" =>
      [
        "write_contact", "contact_margin_gap", "contact_material_params", "contact_params",
        "geom_collision_pair_from_types",
      ]
    "math.py" =>
      [
        "orthogonals", "make_frame", "normalize_with_norm", "closest_segment_point",
        "safe_div",
      ]
    _ => []
  }
}

///|
async fn header_paths(
  root : String,
  relative : String,
  paths : Array[String],
) -> Unit {
  let folder = if relative.is_empty() { root } else { root + "/" + relative }
  for name in @fs.readdir(folder, sort=true) {
    let path = if relative.is_empty() { name } else { relative + "/" + name }
    match @fs.kind(root + "/" + path, follow_symlink=false) {
      Directory => header_paths(root, path, paths)
      Regular =>
        if name.has_suffix(".h") ||
          name.has_suffix(".hpp") ||
          name.has_suffix(".inl") {
          guard paths.length() < 4096 else {
            raise Unsupported::Invalid("too many native headers")
          }
          paths.push(path)
        }
      _ =>
        if name.has_suffix(".h") ||
          name.has_suffix(".hpp") ||
          name.has_suffix(".inl") {
          raise Unsupported::Invalid("header symlink/special file rejected")
        }
    }
  }
}

///|
async fn write_nested(root : String, relative : String, bytes : Bytes) -> Unit {
  let parts = relative.split("/").map(p => p.to_owned()).collect()
  guard !parts.is_empty() &&
    parts.all(p => !p.is_empty() && p != "." && p != "..") else {
    raise Unsupported::Invalid("invalid snapshot path")
  }
  let mut folder = root
  if !@fs.exists(folder) {
    @fs.mkdir(folder, recursive=true)
  }
  for index in 0..<(parts.length() - 1) {
    folder += parts[index] + "/"
    if !@fs.exists(folder) {
      @fs.mkdir(folder)
    }
  }
  @fs.write_file(root + relative, bytes, create_mode=CreateNew)
}

///|
fn compile_options(
  options : Array[String],
  kind : String,
) -> Array[String] raise {
  let architecture = options.filter(o => {
    o.has_prefix("--gpu-architecture=") || o.has_prefix("-arch=")
  })
  guard architecture.length() == 1 &&
    (
      (kind == "ptx" && architecture[0].contains("=compute_")) ||
      (kind == "cubin" && architecture[0].contains("=sm_"))
    ) else {
    raise Unsupported::Invalid(
      "one explicit matching compute_/PTX or sm_/CUBIN architecture required",
    )
  }
  guard !options.any(o => {
    (o.has_prefix("--std=") || o.has_prefix("-std=")) &&
    o != "--std=c++17" &&
    o != "-std=c++17"
  }) else {
    raise Unsupported::Invalid("C++17 required")
  }
  let result = options.copy()
  if !result.contains("--std=c++17") && !result.contains("-std=c++17") {
    result.push("--std=c++17")
  }
  if !result.contains("--device-as-default-execution-space") {
    result.push("--device-as-default-execution-space")
  }
  result
}
