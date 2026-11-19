///|
/// Optional native ATen CPU generator. The plugin is explicitly loaded, so
/// ordinary MoonBit builds have no LibTorch link dependency.
pub type Generator

///|
pub suberror RngError {
  Invalid(String)
}

///|
#borrow(adapter)
extern "c" fn open_native(adapter : Bytes, seed : Int64) -> Generator = "moonrobo_torch_rng_open"

///|
#borrow(generator)
extern "c" fn error_native(generator : Generator) -> Bytes = "moonrobo_torch_rng_error"

///|
#borrow(generator)
extern "c" fn normal_native(generator : Generator, count : Int32) -> Int32 = "moonrobo_torch_rng_normal"

///|
#borrow(generator)
extern "c" fn indices_native(
  generator : Generator,
  high : Int32,
  count : Int32,
) -> Int32 = "moonrobo_torch_rng_indices"

///|
#borrow(generator)
extern "c" fn normal_value(generator : Generator, index : Int32) -> Double = "moonrobo_torch_rng_normal_value"

///|
#borrow(generator)
extern "c" fn index_value(generator : Generator, index : Int32) -> Int32 = "moonrobo_torch_rng_index_value"

///|
#borrow(generator)
extern "c" fn state_native(generator : Generator) -> Bytes = "moonrobo_torch_rng_state"

///|
#borrow(generator, state)
extern "c" fn restore_native(generator : Generator, state : Bytes) -> Int32 = "moonrobo_torch_rng_restore"

///|
#borrow(generator)
extern "c" fn version_native(generator : Generator) -> Bytes = "moonrobo_torch_rng_version"

///|
fn Generator::check(self : Generator, status : Int32) -> Unit raise RngError {
  if status != 0 {
    raise Invalid(@utf8.decode_lossy(error_native(self)))
  }
}

///|
pub fn Generator::open(
  adapter : String,
  seed : Int64,
) -> Generator raise RngError {
  let result = open_native(@utf8.encode(adapter), seed)
  let error = @utf8.decode_lossy(error_native(result))
  if error != "" {
    raise Invalid(error)
  }
  result
}

///|
/// One actual at::randn({count}, generator, CPU Float) call, then lossless Float→Double.
/// Keep batch counts/order identical to the Python call for strict replay.
pub fn Generator::normal(
  self : Generator,
  count : Int32,
) -> Array[Double] raise RngError {
  if count < 0 {
    raise Invalid("normal count must be nonnegative")
  }
  self.check(normal_native(self, count))
  Array::makei(count, i => normal_value(self, i))
}

///|
/// One actual at::randint(high,{count},generator,CPU Long) call.
pub fn Generator::indices(
  self : Generator,
  high : Int32,
  count : Int32,
) -> Array[Int32] raise RngError {
  if high <= 0 || count < 0 {
    raise Invalid("positive high and nonnegative count required")
  }
  self.check(indices_native(self, high, count))
  Array::makei(count, i => index_value(self, i))
}

///|
pub fn Generator::state(self : Generator) -> Bytes raise RngError {
  let bytes = state_native(self)
  let error = @utf8.decode_lossy(error_native(self))
  if error != "" {
    raise Invalid(error)
  }
  bytes
}

///|
pub fn Generator::restore(
  self : Generator,
  state : Bytes,
) -> Unit raise RngError {
  self.check(restore_native(self, state))
}

///|
pub fn Generator::version(self : Generator) -> String {
  @utf8.decode_lossy(version_native(self))
}
