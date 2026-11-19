///|
/// A browser/portable build cannot prove host executable permissions.
fn executable_file(_path : String) -> Bool {
  false
}

///|
fn readable_file(_path : String) -> Bool {
  false
}
