///|
pub type Reader

///|
pub type Writer

///|
pub type AdviceFile

///|
#borrow(path)
extern "c" fn advice_file_open(path : Bytes) -> AdviceFile = "mr_motion_advice_file_open"

///|
#borrow(file)
extern "c" fn advice_file_error(file : AdviceFile) -> Bytes = "mr_motion_advice_file_error"

///|
#borrow(file)
extern "c" fn advice_file_size(file : AdviceFile) -> Int64 = "mr_motion_advice_file_size"

///|
#borrow(file)
extern "c" fn advice_file_read_at(
  file : AdviceFile,
  offset : Int64,
  count : Int32,
) -> Bytes = "mr_motion_advice_file_read_at"

///|
#borrow(file)
extern "c" fn advice_file_dontneed(file : AdviceFile) -> Int32 = "mr_motion_advice_file_dontneed"

///|
#borrow(file)
extern "c" fn advice_file_close(file : AdviceFile) -> Unit = "mr_motion_advice_file_close"

///|
pub fn AdviceFile::open(path : String) -> AdviceFile raise {
  let file = advice_file_open(@utf8.encode(path))
  let error = @utf8.decode(advice_file_error(file))
  guard error == "" else { fail(error) }
  file
}

///|
pub fn AdviceFile::size(self : AdviceFile) -> Int64 {
  advice_file_size(self)
}

///|
pub fn AdviceFile::read_at(
  self : AdviceFile,
  offset : Int64,
  count : Int32,
) -> Bytes raise {
  guard offset >= 0L &&
    count > 0 &&
    count <= 65536 &&
    offset <= self.size() - count.to_int64() else {
    fail("invalid motion advice read range")
  }
  let bytes = advice_file_read_at(self, offset, count)
  guard bytes.length() == count else {
    fail(@utf8.decode(advice_file_error(self)))
  }
  bytes
}

///|
/// Returns 0 when advised, 1 when unsupported, or 2 when the kernel rejected
/// the hint. A changed file size or type after hashing is fatal.
pub fn AdviceFile::dontneed(self : AdviceFile) -> Int32 raise {
  let status = advice_file_dontneed(self)
  guard status != 3 else { fail(self.error()) }
  status
}

///|
pub fn AdviceFile::error(self : AdviceFile) -> String raise {
  @utf8.decode(advice_file_error(self))
}

///|
pub fn AdviceFile::close(self : AdviceFile) -> Unit {
  advice_file_close(self)
}

///|
extern "c" fn reader_new() -> Reader = "mr_motion_reader_new"

///|
#borrow(reader, path, row)
extern "c" fn reader_read(
  reader : Reader,
  path : Bytes,
  index : Int32,
  row : FixedArray[Double],
) -> Int32 = "mr_motion_reader_read"

///|
#borrow(reader)
extern "c" fn reader_error(reader : Reader) -> Bytes = "mr_motion_reader_error"

///|
#borrow(path)
extern "c" fn writer_open(path : Bytes) -> Writer = "mr_motion_writer_open"

///|
#borrow(writer, row)
extern "c" fn writer_write(writer : Writer, row : FixedArray[Double]) -> Int32 = "mr_motion_writer_write"

///|
#borrow(writer)
extern "c" fn writer_finish(writer : Writer) -> Int32 = "mr_motion_writer_finish"

///|
#borrow(writer)
extern "c" fn writer_error(writer : Writer) -> Bytes = "mr_motion_writer_error"

///|
pub fn Reader::new() -> Reader {
  reader_new()
}

///|
pub fn Reader::read(
  self : Reader,
  path : String,
  index : Int32,
  width : Int32,
) -> Array[Double] raise {
  guard width > 0 && width <= 76 && index >= 0 else {
    fail("invalid motion row")
  }
  let row = FixedArray::make(width, 0.0)
  guard reader_read(self, @utf8.encode(path), index, row) == 0 else {
    fail(@utf8.decode(reader_error(self)))
  }
  Array::makei(width, i => row[i])
}

///|
pub fn Writer::open(path : String) -> Writer raise {
  let writer = writer_open(@utf8.encode(path))
  let error = @utf8.decode(writer_error(writer))
  guard error == "" else { fail(error) }
  writer
}

///|
pub fn Writer::write(self : Writer, row : Array[Double]) -> Unit raise {
  guard row.length() > 0 && row.length() <= 76 else {
    fail("invalid motion row width")
  }
  guard writer_write(self, FixedArray::makei(row.length(), i => row[i])) == 0 else {
    fail(@utf8.decode(writer_error(self)))
  }
}

///|
pub fn Writer::finish(self : Writer) -> Unit raise {
  guard writer_finish(self) == 0 else { fail(@utf8.decode(writer_error(self))) }
}
