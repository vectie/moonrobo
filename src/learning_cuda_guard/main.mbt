///|
extern "c" fn capability() -> Int32 = "mr_cuda_guard_capability"

///|
extern "c" fn open_native(device : Int32) -> Int32 = "mr_cuda_guard_open"

///|
#borrow(output)
extern "c" fn sample_native(output : FixedArray[Int64]) -> Int32 = "mr_cuda_guard_sample"

///|
extern "c" fn close_native() -> Int32 = "mr_cuda_guard_close"

///|
#borrow(output)
extern "c" fn error_native(output : FixedArray[Byte]) -> Int32 = "mr_cuda_guard_error"

///|
extern "c" fn flush() -> Unit = "mr_cuda_guard_flush"

///|
fn check(status : Int32) -> Unit raise {
  if status != 0 {
    let bytes : FixedArray[Byte] = FixedArray::make(1024, b'\x00')
    let count = error_native(bytes)
    fail(@utf8.decode(Bytes::makei(count, i => bytes[i])))
  }
}

///|
fn sample() -> (Int64, Int64) raise {
  let values : FixedArray[Int64] = FixedArray::make(2, 0L)
  check(sample_native(values))
  (values[0], values[1])
}

///|
async fn main {
  let args = @env.args()
  if args is [_, "--capabilities"] {
    println(
      (
        {
          "format": "moonrobo.cuda-guard-capabilities.v1",
          "cuda13_header": Json(capability() == 1),
          "libtorch_loaded": false,
          "cuda_initialized": false,
        } : Json).stringify(),
    )
    return
  }
  guard args is [_, "--watch", stop_file] &&
    stop_file.has_prefix("/") &&
    !stop_file.contains("..") &&
    stop_file.all(c => {
      c is ('a'..<='z' | 'A'..<='Z' | '0'..<='9' | '/' | '_' | '-' | '.')
    }) else {
    fail(
      "usage: cuda-memory-guard --watch ABSOLUTE_FRESH_STOP_FILE; or --capabilities",
    )
  }
  guard !@fs.exists(stop_file) else {
    fail("CUDA guard stop file must initially be absent")
  }
  let started = @async.now()
  let mut closed = false
  check(open_native(0))
  defer (if !closed { ignore(close_native()) })
  let mut sequence = 0
  for ;; {
    let elapsed = @async.now() - started
    guard elapsed <= 1860000L && sequence <= 7440 else {
      fail("CUDA guard lifetime bound exceeded")
    }
    let (free_bytes, total_bytes) = sample()
    let safe = free_bytes >= 17179869184L
    println(
      (
        {
          "format": "moonrobo.cuda-memory-guard.v1",
          "state": if !safe {
            "breach"
          } else if sequence == 0 {
            "ready"
          } else {
            "sample"
          },
          "sequence": Json(sequence),
          "elapsed_ms": Json(elapsed),
          "cuda_free_bytes": Json(free_bytes),
          "cuda_total_bytes": Json(total_bytes),
          "minimum_free_bytes": "17179869184",
          "context_overhead_included": true,
        } : Json).stringify(),
    )
    flush()
    guard safe else { fail("CUDA memory guard breached 16 GiB headroom") }
    if @fs.exists(stop_file) {
      check(close_native())
      closed = true
      println(
        (
          {
            "format": "moonrobo.cuda-memory-guard.v1",
            "state": "closed",
            "sequence": Json(sequence + 1),
            "elapsed_ms": Json(@async.now() - started),
            "context_released": true,
          } : Json).stringify(),
      )
      flush()
      return
    }
    sequence += 1
    @async.sleep(250)
  }
}
