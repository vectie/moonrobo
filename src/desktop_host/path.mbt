///|
fn trim_trailing_slash(path : String) -> String {
  if path.length() > 1 && path.has_suffix("/") {
    path.trim(chars=['/']).to_owned()
  } else {
    path
  }
}

///|
fn strip_query(path : String) -> String {
  match path.find("?") {
    Some(index) => path[:index].to_owned()
    None => path
  }
}

///|
fn request_path_segments(path : String) -> Array[String]? {
  let clean = strip_query(path).trim(chars=['/']).to_owned()
  if clean == "" {
    return Some(["index.html"])
  }
  let segments : Array[String] = []
  for piece in clean.split("/") {
    let segment = piece.to_owned()
    if segment == "" || segment == "." {
      continue
    }
    if segment == ".." || segment.contains("\\") {
      return None
    }
    segments.push(segment)
  }
  if segments.length() == 0 {
    Some(["index.html"])
  } else {
    Some(segments)
  }
}

///|
pub fn request_has_file_extension(path : String) -> Bool {
  match request_path_segments(path) {
    None => false
    Some(segments) =>
      match segments[segments.length() - 1].find(".") {
        Some(_) => true
        None => false
      }
  }
}

///|
pub fn resolve_static_request_path(ui_root : String, path : String) -> String? {
  match request_path_segments(path) {
    None => None
    Some(segments) =>
      Some(trim_trailing_slash(ui_root) + "/" + segments.join("/"))
  }
}

///|
pub fn resolve_robobook_asset_request_path(
  robobook_root : String,
  path : String,
) -> String? {
  let prefix = "/api/robobook/assets/"
  if !path.has_prefix(prefix) {
    return None
  }
  match request_path_segments(path[prefix.length():].to_owned()) {
    None => None
    Some(segments) =>
      if segments.length() == 0 || segments[0] == "index.html" {
        None
      } else {
        Some(trim_trailing_slash(robobook_root) + "/" + segments.join("/"))
      }
  }
}

///|
pub fn fallback_index_path(ui_root : String) -> String {
  trim_trailing_slash(ui_root) + "/index.html"
}

///|
pub fn content_type(path : String) -> String {
  let path = path.to_lower()
  if path.has_suffix(".html") {
    "text/html; charset=utf-8"
  } else if path.has_suffix(".css") {
    "text/css; charset=utf-8"
  } else if path.has_suffix(".js") || path.has_suffix(".mjs") {
    "application/javascript"
  } else if path.has_suffix(".json") {
    "application/json"
  } else if path.has_suffix(".svg") {
    "image/svg+xml"
  } else if path.has_suffix(".png") {
    "image/png"
  } else if path.has_suffix(".jpg") || path.has_suffix(".jpeg") {
    "image/jpeg"
  } else if path.has_suffix(".webp") {
    "image/webp"
  } else if path.has_suffix(".ico") {
    "image/x-icon"
  } else if path.has_suffix(".stl") {
    "model/stl"
  } else if path.has_suffix(".obj") {
    "model/obj"
  } else if path.has_suffix(".dae") {
    "model/vnd.collada+xml"
  } else if path.has_suffix(".glb") {
    "model/gltf-binary"
  } else if path.has_suffix(".gltf") {
    "model/gltf+json"
  } else {
    "application/octet-stream"
  }
}
