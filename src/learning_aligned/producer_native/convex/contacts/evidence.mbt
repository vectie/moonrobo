///|
fn source_sha(file : String) -> String raise {
  match file {
    "collision_primitive.py" =>
      "0896a97ff122639ffc8c583d5edcb4f64ca3fd27210989e3b736039000327e28"
    "collision_primitive_core.py" =>
      "4638635965216a19e52a910bccb4a92ad955036eb0525acf7b0ab78dc9f93f5b"
    "collision_gjk.py" =>
      "c288f8f37e4b7f8f9e0e48a92a46c3eee0d0efc6dd7fac65bba2522e11f39e48"
    "collision_convex.py" =>
      "3fd288f0cab3f5f444924d724362fd2cd2eab1281ab2dcb6bc3b48b9b3f30b92"
    "collision_core.py" =>
      "55bfdc244254624d61c228d70d4fd4dc0d2d6af60af40c6e8ed16e47315e2ea6"
    "math.py" =>
      "d08e978993c3d3b5d3f16cb96af94beff519a60a5ea827134b388f30c3a6756c"
    "types.py" =>
      "5ff63b8186bafba2e2d51d5aae84875fb289411d9984f4e06b51813ea088491b"
    _ => raise Unsupported::Invalid("unknown pinned convex contact source")
  }
}

///|
fn definition(source : String, name : String) -> String raise {
  let lines = source.split("\n").map(s => s.to_owned()).collect()
  guard lines.find_index(line => line.has_prefix("def " + name + "("))
    is Some(start) else {
    raise Unsupported::Invalid("source definition missing: " + name)
  }
  let mut end = lines.length()
  let mut header_done = lines[start].trim().has_suffix(":")
  for i in (start + 1)..<lines.length() {
    if !header_done {
      if lines[i].trim().has_suffix(":") {
        header_done = true
      }
      continue
    }
    if !lines[i].trim().is_empty() &&
      !lines[i].has_prefix(" ") &&
      !lines[i].has_prefix("\t") {
      end = i
      break
    }
  }
  guard header_done else {
    raise Unsupported::Invalid("unterminated source definition")
  }
  while end > start && lines[end - 1].trim().is_empty() {
    end -= 1
  }
  lines[start:end].to_array().join("\n") + "\n"
}

///|
fn definition_names(source : String) -> Array[String] {
  let names = []
  for line in source.split("\n") {
    if line.strip_prefix("def ") is Some(tail) {
      names.push(tail.split("(").next().unwrap().trim().to_owned())
    }
  }
  names
}

///|
async fn header_paths(
  root : String,
  relative : String,
  paths : Array[String],
) -> Unit {
  let directory = if relative.is_empty() { root } else { root + "/" + relative }
  for name in @fs.readdir(directory, sort=true) {
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
          raise Unsupported::Invalid(
            "native header symlink/special file refused",
          )
        }
    }
  }
}

///|
async fn write_nested(root : String, relative : String, bytes : Bytes) -> Unit {
  let parts = relative.split("/").map(p => p.to_owned()).collect()
  guard !parts.is_empty() &&
    parts.all(p => !p.is_empty() && p != "." && p != "..") else {
    raise Unsupported::Invalid("unsafe contact snapshot path")
  }
  let mut directory = root
  if !@fs.exists(directory) {
    @fs.mkdir(directory, recursive=true)
  }
  for i in 0..<(parts.length() - 1) {
    directory += "/" + parts[i]
    if !@fs.exists(directory) {
      @fs.mkdir(directory)
    }
  }
  @fs.write_file(root + "/" + relative, bytes, create_mode=CreateNew)
}

///|
fn compile_options(
  options : Array[String],
  kind : String,
) -> Array[String] raise {
  let architectures = options.filter(o => {
    o.has_prefix("--gpu-architecture=") || o.has_prefix("-arch=")
  })
  guard architectures.length() == 1 &&
    (
      (kind == "ptx" && architectures[0].contains("=compute_")) ||
      (kind == "cubin" && architectures[0].contains("=sm_"))
    ) else {
    raise Unsupported::Invalid(
      "one explicit matching compute_/PTX or sm_/CUBIN target required",
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
