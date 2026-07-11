///|
pub fn moondata_uri(relative : String) -> String {
  "moondata://\{relative}"
}

///|
pub fn moondata_relative_path_is_safe(relative : String) -> Bool {
  if relative == "" ||
    relative.has_prefix("/") ||
    relative.contains("\\") ||
    relative.contains("//") {
    return false
  }
  let parts = relative.split("/").to_array()
  for part in parts {
    if part == "" || part == "." || part == ".." {
      return false
    }
  }
  true
}

///|
pub fn moondata_uri_relative_path(uri : String) -> String? {
  match uri.strip_prefix("moondata://") {
    Some(relative) => {
      let path = relative.to_owned()
      if moondata_relative_path_is_safe(path) {
        Some(path)
      } else {
        None
      }
    }
    None => None
  }
}

///|
pub fn moondata_payload_relative_path_is_allowed(relative : String) -> Bool {
  relative.has_prefix("media/imports/") ||
  relative.has_prefix("media/robot_models/") ||
  relative.has_prefix("media/replays/") ||
  relative.has_prefix("blobs/sha256/") ||
  relative.has_prefix("exports/")
}

///|
pub fn moondata_payload_root(relative : String) -> String {
  if relative.has_prefix("media/imports/") {
    "media/imports"
  } else if relative.has_prefix("media/robot_models/") {
    "media/robot_models"
  } else if relative.has_prefix("media/replays/") {
    "media/replays"
  } else if relative.has_prefix("blobs/sha256/") {
    "blobs/sha256"
  } else if relative.has_prefix("exports/") {
    "exports"
  } else {
    ""
  }
}

///|
pub fn moondata_payload_uri_relative_path(uri : String) -> String? {
  match moondata_uri_relative_path(uri) {
    Some(relative) =>
      if moondata_payload_relative_path_is_allowed(relative) {
        Some(relative)
      } else {
        None
      }
    None => None
  }
}

///|
pub fn moondata_uri_path(root : String, uri : String) -> String? {
  match moondata_uri_relative_path(uri) {
    Some(relative) =>
      if root.has_suffix("/") {
        Some(root + relative)
      } else {
        Some(root + "/" + relative)
      }
    None => None
  }
}
