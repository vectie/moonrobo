///|
#borrow(nccl, cudart)
extern "c" fn open_runtime(nccl : Bytes, cudart : Bytes) -> Int32 = "mr_nccl_probe_open"

///|
extern "c" fn new_id() -> Bytes = "mr_nccl_probe_id"

///|
extern "c" fn last_error() -> Bytes = "mr_nccl_probe_error"

///|
#borrow(id)
extern "c" fn allreduce(rank : Int32, id : Bytes, elements : Int32) -> Bytes = "mr_nccl_probe_run"

///|
/// rank 0 publishes an ID and remains alive while rank 1 receives its copy.
/// Root orchestration transfers the ID file; this command never opens SSH.
async fn main {
  let args = @env.args()
  guard args.length() == 6 else {
    fail(
      "usage: nccl-probe RANK(0|1) ABSOLUTE_NEW_ID_FILE ABSOLUTE_LIBNCCL ABSOLUTE_LIBCUDART FLOAT_ELEMENTS(1..2097152)",
    )
  }
  let rank = @string.parse_int(args[1])
  let path = args[2]
  let elements = @string.parse_int(args[5])
  guard (rank == 0 || rank == 1) && elements > 0 && elements <= 2097152 else {
    fail(
      "exactly two ranks; combined host/device probe buffers must be <=16 MiB",
    )
  }
  for value in [path, args[3], args[4]] {
    guard value.has_prefix("/") && !value.contains("\u{0000}") else {
      fail("ID and library paths must be absolute and contain no NUL")
    }
  }
  if rank == 0 && @fs.exists(path) {
    fail("ID file already exists; use a new path for this invocation")
  }
  guard open_runtime(@utf8.encode(args[3]), @utf8.encode(args[4])) == 0 else {
    fail(@utf8.decode_lossy(last_error()))
  }
  let id = if rank == 0 {
    let value = new_id()
    guard value.length() == 128 else { fail(@utf8.decode_lossy(last_error())) }
    let temporary = path + ".partial"
    @fs.write_file(temporary, value, create_mode=CreateNew, permission=0o600)
    @fs.rename(temporary, path, replace=false)
    println("NCCL_ID_READY " + path)
    value
  } else {
    guard @fs.kind(path, follow_symlink=false) == Regular else {
      fail("rank 1 requires a regular 128-byte ID file")
    }
    let file = @fs.open(path, mode=ReadOnly)
    defer file.close()
    guard file.size() == 128L else {
      fail("NCCL ID file must be exactly 128 bytes")
    }
    file.read_exactly_at(128, position=0L)
  }
  let report = allreduce(rank, id, elements)
  guard report.length() > 0 else { fail(@utf8.decode_lossy(last_error())) }
  println(@json.parse(@utf8.decode_lossy(report)).stringify(indent=2))
}
