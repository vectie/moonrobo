///|
/// Read a unique value option, rejecting missing and ambiguous values.
pub fn option(arguments : Array[String], name : String) -> String? raise {
  let mut result = None
  for i, value in arguments {
    if value != name {
      continue
    }
    guard result is None &&
      i + 1 < arguments.length() &&
      !arguments[i + 1].has_prefix("--") else {
      fail("missing or repeated native option: " + name)
    }
    result = Some(arguments[i + 1])
  }
  result
}

///|
pub fn required(arguments : Array[String], name : String) -> String raise {
  guard option(arguments, name) is Some(value) else {
    fail("required native option: " + name)
  }
  value
}

///|
/// Native simulation loads exactly the caller-selected C library. Obtaining
/// its location from an installed Python wheel is not interpreter execution,
/// but no interpreter or package discovery process is launched here.
pub fn mujoco_library(arguments : Array[String]) -> String raise {
  let value = match option(arguments, "--library") {
    Some(path) => Some(path)
    None => @env.get_env_var("MOONROBO_MUJOCO_LIBRARY")
  }
  guard value is Some(path) && !path.is_empty() && !path.contains("\u{0}") else {
    fail("provide --library PATH or MOONROBO_MUJOCO_LIBRARY for native MuJoCo")
  }
  path
}

///|
/// Resolve a path as data, preserving explicit absolute paths.
pub fn repository_path(root : String, path : String) -> String {
  if path.has_prefix("/") {
    path
  } else {
    root + "/" + path
  }
}
