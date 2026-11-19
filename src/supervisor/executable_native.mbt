///|
#borrow(path)
extern "c" fn executable_native(path : Bytes) -> Bool = "moonrobo_supervisor_executable"

///|
fn executable_file(path : String) -> Bool {
  !path.contains("\u{0}") && executable_native(@utf8.encode(path + "\u{0}"))
}

///|
#borrow(path)
extern "c" fn readable_native(path : Bytes) -> Bool = "moonrobo_supervisor_readable_file"

///|
fn readable_file(path : String) -> Bool {
  !path.contains("\u{0}") && readable_native(@utf8.encode(path + "\u{0}"))
}
