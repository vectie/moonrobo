///|
/// The loader is GC owned; close also releases the adapter deterministically.
priv type Preparation

///|
#borrow(adapter, library, source)
extern "c" fn open_model(
  adapter : Bytes,
  library : Bytes,
  source : Bytes,
) -> Preparation = "moonrobo_prepared_model_open"

///|
#borrow(adapter, source, wire)
extern "c" fn open_usd(
  adapter : Bytes,
  source : Bytes,
  wire : Bytes,
) -> Preparation = "moonrobo_prepared_usd_open"

///|
#borrow(handle)
extern "c" fn preparation_error(handle : Preparation) -> Bytes = "moonrobo_prepared_error"

///|
#borrow(handle)
extern "c" fn preparation_json(handle : Preparation) -> Bytes = "moonrobo_prepared_json"

///|
#borrow(handle)
extern "c" fn preparation_mjb(handle : Preparation) -> Bytes = "moonrobo_prepared_mjb"

///|
#borrow(handle)
extern "c" fn preparation_close(handle : Preparation) -> Unit = "moonrobo_prepared_close"

///|
fn Preparation::check(self : Preparation) -> Unit raise {
  let error = @utf8.decode(preparation_error(self))
  guard error == "" else { fail(error) }
}

///|
fn Preparation::json(self : Preparation, format : String) -> Json raise {
  self.check()
  let json = @json.parse(@utf8.decode(preparation_json(self)))
  guard json is { "format": String(actual), .. } && actual == format else {
    fail("native preparation descriptor format mismatch")
  }
  json
}

///|
async fn explicit_file(path : String) -> String {
  guard !path.is_empty() && !path.contains("\u{0}") else {
    fail("explicit NUL-free native preparation file path required")
  }
  let resolved = @fs.realpath(path)
  guard @fs.kind(resolved) is Regular else {
    fail("native preparation input is not a regular file: " + resolved)
  }
  resolved
}

///|
async fn file_sha(path : String) -> String {
  @artifacts.sha256(@fs.read_file(path).binary())
}
