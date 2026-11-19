///|
pub type Oracle

///|
#borrow(library)
extern "c" fn oracle_open(library : Bytes) -> Oracle = "moonrobo_diff_open"

///|
#borrow(handle)
extern "c" fn oracle_error(handle : Oracle) -> Bytes = "moonrobo_diff_error"

///|
#borrow(handle)
extern "c" fn oracle_version(handle : Oracle) -> Bytes = "moonrobo_diff_version"

///|
#borrow(handle)
extern "c" fn oracle_clear(handle : Oracle) -> Unit = "moonrobo_diff_clear_input"

///|
#borrow(handle, name, dtype)
extern "c" fn oracle_begin(
  handle : Oracle,
  name : Bytes,
  dtype : Bytes,
  rank : Int32,
  count : Int32,
) -> Int32 = "moonrobo_diff_begin"

///|
#borrow(handle)
extern "c" fn oracle_shape(
  handle : Oracle,
  index : Int32,
  value : Int32,
) -> Unit = "moonrobo_diff_shape"

///|
#borrow(handle)
extern "c" fn oracle_value(
  handle : Oracle,
  index : Int32,
  value : Double,
) -> Unit = "moonrobo_diff_value"

///|
#borrow(handle)
extern "c" fn oracle_commit(handle : Oracle) -> Int32 = "moonrobo_diff_commit"

///|
#borrow(handle, operation)
extern "c" fn oracle_run(handle : Oracle, operation : Bytes) -> Int32 = "moonrobo_diff_run"

///|
#borrow(handle)
extern "c" fn oracle_count(handle : Oracle) -> Int32 = "moonrobo_diff_count"

///|
#borrow(handle)
extern "c" fn oracle_name(handle : Oracle, index : Int32) -> Bytes = "moonrobo_diff_name"

///|
#borrow(handle)
extern "c" fn oracle_dtype(handle : Oracle, index : Int32) -> Bytes = "moonrobo_diff_dtype"

///|
#borrow(handle)
extern "c" fn oracle_rank(handle : Oracle, index : Int32) -> Int32 = "moonrobo_diff_rank"

///|
#borrow(handle)
extern "c" fn oracle_dim(handle : Oracle, index : Int32, axis : Int32) -> Int32 = "moonrobo_diff_dim"

///|
#borrow(handle)
extern "c" fn oracle_size(handle : Oracle, index : Int32) -> Int32 = "moonrobo_diff_size"

///|
#borrow(handle)
extern "c" fn oracle_get(
  handle : Oracle,
  index : Int32,
  offset : Int32,
) -> Double = "moonrobo_diff_get"

///|
fn Oracle::check(self : Oracle, status : Int32) -> Unit raise {
  guard status == 0 else {
    fail("independent native oracle: " + @utf8.decode_lossy(oracle_error(self)))
  }
}

///|
pub fn Oracle::open(library : String) -> Oracle raise {
  guard !library.is_empty() else {
    fail("explicit LibTorch oracle shared library is required")
  }
  let handle = oracle_open(@utf8.encode(library))
  guard oracle_error(handle).is_empty() else {
    fail(@utf8.decode_lossy(oracle_error(handle)))
  }
  handle
}

///|
pub fn Oracle::version(self : Oracle) -> String {
  @utf8.decode_lossy(oracle_version(self))
}

///|
pub fn Oracle::put(
  self : Oracle,
  name : String,
  array : @artifacts.NumericArray,
) -> Unit raise {
  tensor_valid(name, array)
  self.check(
    oracle_begin(
      self,
      @utf8.encode(name),
      @utf8.encode(array.dtype),
      array.shape.length(),
      array.values.length(),
    ),
  )
  for i, dim in array.shape {
    oracle_shape(self, i, dim)
  }
  for i, value in array.values {
    oracle_value(self, i, value)
  }
  self.check(oracle_commit(self))
}

///|
pub fn Oracle::evaluate(
  self : Oracle,
  operation : String,
  input : Map[String, @artifacts.NumericArray],
) -> Map[String, @artifacts.NumericArray] raise {
  oracle_clear(self)
  for name, array in input {
    self.put(name, array)
  }
  self.check(oracle_run(self, @utf8.encode(operation)))
  let output : Map[String, @artifacts.NumericArray] = {}
  for i in 0..<oracle_count(self) {
    let name = @utf8.decode_lossy(oracle_name(self, i))
    let shape = Array::makei(oracle_rank(self, i), axis => {
      oracle_dim(self, i, axis)
    })
    let array : @artifacts.NumericArray = {
      shape,
      dtype: @utf8.decode_lossy(oracle_dtype(self, i)),
      values: Array::makei(oracle_size(self, i), j => oracle_get(self, i, j)),
    }
    tensor_valid(name, array)
    output[name] = array
  }
  output
}
