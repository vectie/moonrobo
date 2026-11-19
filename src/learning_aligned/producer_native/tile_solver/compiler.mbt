///|
priv type Backend

///|
fn text(value : String) -> Bytes raise TileError {
  guard !value.is_empty() && !value.contains("\u{0}") else {
    raise Invalid("nonempty NUL-free native compilation input required")
  }
  @utf8.encode(value)
}

///|
#borrow(path)
extern "c" fn open_raw(path : Bytes) -> Backend = "mr_tile_open"

///|
#borrow(backend)
extern "c" fn error_raw(backend : Backend) -> Bytes = "mr_tile_error"

///|
#borrow(backend)
extern "c" fn mathdx_version_raw(backend : Backend) -> Bytes = "mr_tile_mathdx_version"

///|
#borrow(backend)
extern "c" fn close_raw(backend : Backend) -> Unit = "mr_tile_close"

///|
#borrow(backend, fatbin, ltoir, symbol)
extern "c" fn solver_raw(
  backend : Backend,
  fatbin : Bytes,
  ltoir : Bytes,
  symbol : Bytes,
  arch : Int32,
  size : Int32,
  nrhs : Int32,
  solve : Int32,
  precision : Int32,
  threads : Int32,
) -> Int32 = "mr_tile_solver"

///|
#borrow(backend, source, native, includes, output, ltoirs, fatbin)
extern "c" fn program_raw(
  backend : Backend,
  source : Bytes,
  native : Bytes,
  includes : FixedArray[Bytes],
  output : Bytes,
  arch : Int32,
  ltoirs : FixedArray[Bytes],
  fatbin : Bytes,
) -> Int32 = "mr_tile_program"

///|
fn checked(backend : Backend, result : Int32) -> Unit raise TileError {
  let error = @utf8.decode_lossy(error_raw(backend))
  guard result == 1 && error.is_empty() else {
    raise Native(
      if error.is_empty() {
        "native tile compilation failed"
      } else {
        error
      },
    )
  }
}
