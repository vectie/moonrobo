// A data-only pickle interpreter. Symbols are allowlisted tokens, never executable globals.
// Layout references: PyTorch serialization notes and torch/_utils.py _rebuild_tensor[_v2].
// https://docs.pytorch.org/docs/stable/notes/serialization.html
// https://github.com/pytorch/pytorch/blob/main/torch/_utils.py

///|
pub(all) enum TorchValue {
  TorchNone
  TorchBool(Bool)
  TorchInt(Int64)
  TorchFloat(Double)
  TorchString(String)
  TorchList(Array[TorchValue])
  TorchDict(Map[String, TorchValue])
  TorchTensor(NumericArray)
} derive(Debug)

///|
pub fn TorchValue::field(self : TorchValue, name : String) -> TorchValue raise {
  guard self is TorchDict(fields) && fields.get(name) is Some(value) else {
    fail("missing Torch checkpoint field: " + name)
  }
  value
}

///|
pub fn TorchValue::tensor(self : TorchValue) -> NumericArray raise {
  guard self is TorchTensor(tensor) else { fail("expected Torch tensor") }
  tensor
}

///|
pub fn TorchValue::plain_json(self : TorchValue) -> Json raise {
  torch_json(self, 0)
}

///|
fn torch_json(
  value : TorchValue,
  depth : Int32,
  budget? : Ref[Int32],
) -> Json raise {
  let budget = budget.unwrap_or(Ref::new(1000000))
  budget.val -= 1
  guard budget.val >= 0 else {
    fail("Torch JSON expansion exceeds resource limit")
  }
  guard depth <= 256 else { fail("Torch JSON nesting exceeds 256") }
  match value {
    TorchNone => Json::null()
    TorchBool(v) => v.to_json()
    TorchInt(v) => {
      guard v >= -9007199254740992L && v <= 9007199254740992L else {
        fail("Torch integer is not exact in JSON numeric representation")
      }
      v.to_double().to_json()
    }
    TorchFloat(v) => {
      guard !v.is_nan() && !v.is_inf() else {
        fail("nonfinite Torch scalar cannot be encoded as JSON")
      }
      v.to_json()
    }
    TorchString(v) => v.to_json()
    TorchList(items) =>
      items.map(v => torch_json(v, depth + 1, budget~)).to_json()
    TorchDict(fields) => {
      let out : Map[String, Json] = Map([])
      for key, v in fields {
        out[key] = torch_json(v, depth + 1, budget~)
      }
      Json::object(out)
    }
    TorchTensor(tensor) => {
      guard tensor.values.all(v => !v.is_nan() && !v.is_inf()) else {
        fail(
          "nonfinite Torch tensor requires explicit caller masking before JSON conversion",
        )
      }
      {
        "shape": tensor.shape.to_json(),
        "dtype": tensor.dtype.to_json(),
        "values": tensor.values.to_json(),
      }
    }
  }
}

///|
priv struct TorchStorage {
  dtype : String
  width : Int32
  bytes : Bytes
  count : Int32
}

///|
priv struct TorchPickleDict {
  fields : Map[String, TorchPickleItem]
  key_kinds : Map[String, String]
  ordered : Bool
}

///|
priv struct TorchNumpyDtype {
  code : String
  mut order : String
}

///|
priv struct TorchNumpyArray {
  mut tensor : NumericArray?
}

///|
priv enum TorchPickleItem {
  PNone
  PBool(Bool)
  PInt(Int64)
  PFloat(Double)
  PString(String)
  PBytes(Bytes)
  PList(Array[TorchPickleItem])
  PTuple(Array[TorchPickleItem])
  PDict(TorchPickleDict)
  PGlobal(String)
  PStorage(TorchStorage)
  PTensor(NumericArray)
  PNumpyDtype(TorchNumpyDtype)
  PNumpyArray(TorchNumpyArray)
  PMark
}

///|
priv struct TorchPickleReader {
  input : Bytes
  entries : Map[String, Bytes]
  root : String
  stack : Array[TorchPickleItem]
  memo : Map[Int32, TorchPickleItem]
  storage_types : Map[String, String]
  mut cursor : Int32
  mut frame_end : Int32?
  mut protocol : Int32
  mut tensor_elements : Int64
}

///|
fn TorchPickleReader::take(self : TorchPickleReader, n : Int32) -> Bytes raise {
  guard n >= 0 && self.cursor >= 0 && n <= self.input.length() - self.cursor else {
    fail("truncated Torch pickle")
  }
  if self.frame_end is Some(end) {
    guard self.cursor + n <= end else {
      fail("pickle opcode crosses FRAME boundary")
    }
  }
  let bytes = self.input[self.cursor:self.cursor + n].to_owned()
  self.cursor += n
  bytes
}

///|
fn TorchPickleReader::byte(self : TorchPickleReader) -> Int32 raise {
  self.take(1)[0].to_int()
}

///|
fn TorchPickleReader::unsigned(
  self : TorchPickleReader,
  width : Int32,
) -> Int64 raise {
  let bytes = self.take(width)
  let mut value = 0L
  for i, b in bytes {
    value = value | (b.to_int().to_int64() << (8 * i))
  }
  value
}

///|
fn TorchPickleReader::length(
  self : TorchPickleReader,
  width : Int32,
) -> Int32 raise {
  let value = self.unsigned(width)
  guard value >= 0L && value <= 2147483647L else {
    fail("Torch pickle length/index exceeds supported bounds")
  }
  value.to_int()
}

///|
fn TorchPickleReader::line(self : TorchPickleReader) -> String raise {
  let start = self.cursor
  for ;; {
    let value = self.byte()
    if value == 10 {
      break
    }
  }
  @utf8.decode(self.input[start:self.cursor - 1].to_owned())
}

///|
fn TorchPickleReader::pop(self : TorchPickleReader) -> TorchPickleItem raise {
  guard self.stack.pop() is Some(value) else {
    fail("Torch pickle stack underflow")
  }
  value
}

///|
fn TorchPickleReader::top(self : TorchPickleReader) -> TorchPickleItem raise {
  guard self.stack.last() is Some(value) else {
    fail("Torch pickle stack underflow")
  }
  value
}

///|
fn TorchPickleReader::marked(
  self : TorchPickleReader,
) -> Array[TorchPickleItem] raise {
  let mut mark = self.stack.length() - 1
  while mark >= 0 {
    if self.stack[mark] is PMark {
      break
    }
    mark -= 1
  }
  guard mark >= 0 else { fail("Torch pickle MARK not found") }
  let items = self.stack[mark + 1:].to_owned()
  while self.stack.length() > mark {
    ignore(self.stack.pop())
  }
  items
}

///|
fn empty_torch_dict(ordered : Bool) -> TorchPickleItem {
  PDict({ fields: Map([]), key_kinds: Map([]), ordered, })
}

///|
fn torch_set(
  dict : TorchPickleDict,
  key : TorchPickleItem,
  value : TorchPickleItem,
) -> Unit raise {
  let (name, kind) = match key {
    PString(s) => (s, "string")
    PInt(n) => (n.to_string(), "integer")
    _ => fail("Torch checkpoint dictionary key must be string or integer")
  }
  if dict.key_kinds.get(name) is Some(previous) {
    guard previous == kind else {
      fail("Torch dictionary string/integer key collision")
    }
  }
  dict.key_kinds[name] = kind
  dict.fields[name] = value
}

///|
fn torch_global(module : String, name : String) -> TorchPickleItem raise {
  let symbol = module + "." + name
  guard [
    "collections.OrderedDict", "torch._utils._rebuild_tensor", "torch._utils._rebuild_tensor_v2",
    "torch._utils._rebuild_parameter", "torch.FloatStorage", "torch.DoubleStorage",
    "torch.LongStorage", "torch.IntStorage", "torch.ByteStorage", "torch.BoolStorage",
    "numpy.core.multiarray._reconstruct", "numpy._core.multiarray._reconstruct",
    "numpy.ndarray", "numpy.dtype", "_codecs.encode",
  ].contains(symbol) else {
    fail("unsupported pickle global: " + symbol)
  }
  PGlobal(symbol)
}

///|
fn torch_int(value : TorchPickleItem) -> Int64 raise {
  guard value is PInt(n) else { fail("expected Torch pickle integer") }
  n
}

///|
fn torch_index(value : TorchPickleItem) -> Int32 raise {
  let n = torch_int(value)
  guard n >= 0L && n <= 2147483647L else {
    fail("Torch tensor size/stride/offset outside supported bounds")
  }
  n.to_int()
}

///|
fn torch_tuple(value : TorchPickleItem) -> Array[TorchPickleItem] raise {
  guard value is PTuple(items) else { fail("expected Torch pickle tuple") }
  items
}

///|
fn torch_empty_hooks(value : TorchPickleItem) -> Unit raise {
  let empty = match value {
    PNone => true
    PDict(dict) => dict.fields.is_empty()
    _ => false
  }
  guard empty else { fail("Torch checkpoint hooks must be absent or empty") }
}

///|
fn TorchPickleReader::persistent(
  self : TorchPickleReader,
  value : TorchPickleItem,
) -> TorchPickleItem raise {
  let tuple = torch_tuple(value)
  guard tuple.length() == 5 &&
    tuple[0] is PString("storage") &&
    tuple[1] is PGlobal(storage_type) &&
    tuple[2] is PString(key) &&
    tuple[3] is PString(location) else {
    fail("unsupported Torch persistent ID")
  }
  guard location == "cpu" ||
    (
      location.has_prefix("cuda:") &&
      !location[5:].is_empty() &&
      location[5:].iter().all(c => c >= '0' && c <= '9')
    ) else {
    fail("unsupported Torch storage device tag: " + location)
  }
  guard !key.is_empty() &&
    !key.contains("/") &&
    !key.contains("\\") &&
    key != "." &&
    key != ".." else {
    fail("invalid Torch storage key")
  }
  let (dtype, width) = match storage_type {
    "torch.FloatStorage" => ("<f4", 4)
    "torch.DoubleStorage" => ("<f8", 8)
    "torch.LongStorage" => ("<i8", 8)
    "torch.IntStorage" => ("<i4", 4)
    "torch.ByteStorage" => ("|u1", 1)
    "torch.BoolStorage" => ("|b1", 1)
    _ => fail("persistent ID requires an allowlisted numeric Torch storage")
  }
  let count = torch_index(tuple[4])
  guard self.entries.get(self.root + "data/" + key) is Some(bytes) else {
    fail("missing Torch storage member: " + key)
  }
  guard count <= 2147483647 / width && bytes.length() == count * width else {
    fail("Torch storage byte length differs from declared element count")
  }
  if self.storage_types.get(key) is Some(previous) {
    guard previous == dtype else { fail("Torch storage alias changes dtype") }
  }
  self.storage_types[key] = dtype
  PStorage({ dtype, width, bytes, count, })
}

///|
fn torch_storage_number(storage : TorchStorage, index : Int32) -> Double raise {
  guard index >= 0 && index < storage.count else {
    fail("Torch tensor view exceeds storage")
  }
  let offset = index * storage.width
  let mut bits = 0L
  for j in 0..<storage.width {
    bits = bits | (storage.bytes[offset + j].to_int().to_int64() << (8 * j))
  }
  match storage.dtype {
    "<f4" => Float::reinterpret_from_int(bits.to_int()).to_double()
    "<f8" => bits.reinterpret_as_double()
    "<i8" => {
      guard bits >= -9007199254740992L && bits <= 9007199254740992L else {
        fail(
          "Torch integer tensor element cannot be represented exactly as Double",
        )
      }
      bits.to_double()
    }
    "<i4" => bits.to_int().to_double()
    "|b1" => {
      guard bits == 0L || bits == 1L else {
        fail("invalid Torch boolean storage value")
      }
      bits.to_double()
    }
    _ => bits.to_double()
  }
}

///|
fn TorchPickleReader::rebuild(
  self : TorchPickleReader,
  args : Array[TorchPickleItem],
) -> TorchPickleItem raise {
  guard args.length() >= 4 && args[0] is PStorage(storage) else {
    fail("Torch tensor rebuild needs numeric storage")
  }
  let offset = torch_index(args[1])
  let shape = torch_tuple(args[2]).map(torch_index)
  let strides = torch_tuple(args[3]).map(torch_index)
  guard shape.length() <= 256 && shape.length() == strides.length() else {
    fail("invalid Torch tensor dimension/stride count")
  }
  let mut count = 1
  for size in shape {
    guard size == 0 || count <= 2147483647 / size else {
      fail("Torch tensor shape product overflows")
    }
    count *= size
  }
  guard count <= 16777216 &&
    self.tensor_elements + count.to_int64() <= 134217728L else {
    fail("Torch checkpoint exceeds numeric tensor materialization limit")
  }
  self.tensor_elements += count.to_int64()
  if count == 0 {
    guard offset <= storage.count else {
      fail("empty Torch tensor offset exceeds storage")
    }
  } else {
    let mut maximum = offset.to_int64()
    for i, size in shape {
      maximum += (size - 1).to_int64() * strides[i].to_int64()
      guard maximum < storage.count.to_int64() else {
        fail("Torch tensor view exceeds storage bounds")
      }
    }
    guard offset < storage.count else {
      fail("Torch tensor offset exceeds storage")
    }
  }
  let values : Array[Double] = []
  for linear in 0..<count {
    let mut remaining = linear
    let mut index = offset
    for step in 0..<shape.length() {
      let axis = shape.length() - step - 1
      let coordinate = remaining % shape[axis]
      remaining /= shape[axis]
      index += coordinate * strides[axis]
    }
    values.push(torch_storage_number(storage, index))
  }
  PTensor({ shape, dtype: storage.dtype, values, })
}

///|
fn numpy_dtype_build(
  dtype : TorchNumpyDtype,
  state : TorchPickleItem,
) -> Unit raise {
  let items = torch_tuple(state)
  guard items.length() == 8 &&
    items[0] is PInt(3L) &&
    items[1] is PString(order) &&
    items[2] is PNone &&
    items[3] is PNone &&
    items[4] is PNone &&
    items[5] is PInt(-1L) &&
    items[6] is PInt(-1L) &&
    items[7] is PInt(0L) else {
    fail(
      "NumPy dtype BUILD permits only primitive version-3 state without fields or metadata",
    )
  }
  guard ["<", "=", "|"].contains(order) else {
    fail("big-endian NumPy pickle data is unsupported")
  }
  guard order != "|" || dtype.code == "u1" || dtype.code == "b1" else {
    fail("multibyte NumPy dtype requires a numeric byte order")
  }
  dtype.order = order
}

///|
fn TorchPickleReader::numpy_array_build(
  self : TorchPickleReader,
  array : TorchNumpyArray,
  state : TorchPickleItem,
) -> Unit raise {
  guard array.tensor is None else {
    fail("NumPy array cannot be rebuilt twice")
  }
  let items = torch_tuple(state)
  guard items.length() == 5 &&
    items[0] is PInt(1L) &&
    items[2] is PNumpyDtype(dtype) &&
    items[3] is PBool(false) &&
    items[4] is PBytes(bytes) else {
    fail("NumPy ndarray BUILD requires version-1 C-order raw numeric data")
  }
  let shape = torch_tuple(items[1]).map(torch_index)
  guard shape.length() <= 256 else {
    fail("NumPy pickle dimension count exceeds 256")
  }
  let mut count = 1
  for size in shape {
    guard size == 0 || count <= 16777216 / size else {
      fail("NumPy array exceeds numeric tensor materialization limit")
    }
    count *= size
  }
  guard count <= 16777216 &&
    self.tensor_elements + count.to_int64() <= 134217728L else {
    fail("NumPy arrays exceed checkpoint materialization limit")
  }
  let (code, width) = match dtype.code {
    "f8" => ("<f8", 8)
    "f4" => ("<f4", 4)
    "i8" => ("<i8", 8)
    "i4" => ("<i4", 4)
    "u1" => ("|u1", 1)
    "b1" => ("|b1", 1)
    _ => fail("unsupported primitive NumPy dtype")
  }
  guard dtype.order == "<" ||
    dtype.order == "=" ||
    (width == 1 && dtype.order == "|") else {
    fail("unsupported NumPy pickle byte order")
  }
  guard bytes.length() == count * width else {
    fail("NumPy pickle raw bytes differ from declared shape")
  }
  self.tensor_elements += count.to_int64()
  let storage : TorchStorage = { dtype: code, width, bytes, count, }
  array.tensor = Some({
    shape,
    dtype: code,
    values: Array::makei(count, i => torch_storage_number(storage, i)),
  })
}

///|
fn TorchPickleReader::reduce(
  self : TorchPickleReader,
  callable : TorchPickleItem,
  arguments : TorchPickleItem,
) -> TorchPickleItem raise {
  guard callable is PGlobal(symbol) else {
    fail("pickle REDUCE target must be allowlisted symbolic global")
  }
  let args = torch_tuple(arguments)
  match symbol {
    "_codecs.encode" => {
      guard args.length() == 2 &&
        args[0] is PString(text) &&
        args[1] is PString("latin1") else {
        fail("pickle byte encoding is restricted to latin1 data")
      }
      let bytes : Array[Byte] = []
      for character in text.iter() {
        let value = character.to_int()
        guard value <= 255 else { fail("invalid latin1 pickle byte") }
        bytes.push(value.to_byte())
      }
      PBytes(Bytes::from_array(bytes))
    }
    "numpy.dtype" => {
      guard args.length() == 3 &&
        args[0] is PString(code) &&
        args[1] is PBool(false) &&
        args[2] is PBool(true) else {
        fail("unsupported numeric NumPy dtype constructor")
      }
      let order = if code.has_prefix("<") ||
        code.has_prefix("=") ||
        code.has_prefix("|") ||
        code.has_prefix(">") {
        code[:1].to_owned()
      } else {
        "="
      }
      let code = if order != "=" || code.has_prefix("=") {
        code[1:].to_owned()
      } else {
        code
      }
      guard ["f8", "f4", "i8", "i4", "u1", "b1"].contains(code) else {
        fail("NumPy pickle dtype is not an allowed primitive numeric type")
      }
      PNumpyDtype({ code, order, })
    }
    "numpy.core.multiarray._reconstruct"
    | "numpy._core.multiarray._reconstruct" => {
      guard args.length() == 3 &&
        args[0] is PGlobal("numpy.ndarray") &&
        args[1] is PTuple(shape) &&
        shape.length() == 1 &&
        shape[0] is PInt(0L) &&
        args[2] is PBytes(b"b") else {
        fail("unsupported NumPy ndarray reconstruction signature")
      }
      PNumpyArray({ tensor: None, })
    }
    "collections.OrderedDict" => {
      let result = empty_torch_dict(true)
      guard result is PDict(dict) else {
        fail("internal dictionary construction")
      }
      if args.length() == 1 {
        let pairs = match args[0] {
          PList(items) | PTuple(items) => items
          _ => fail("OrderedDict constructor requires pairs")
        }
        for pair in pairs {
          let pair = torch_tuple(pair)
          guard pair.length() == 2 else {
            fail("OrderedDict pair must contain key and value")
          }
          torch_set(dict, pair[0], pair[1])
        }
      } else {
        guard args.is_empty() else {
          fail("unsupported OrderedDict constructor")
        }
      }
      result
    }
    "torch._utils._rebuild_tensor" => {
      guard args.length() == 4 else {
        fail("unsupported Torch tensor rebuild signature")
      }
      self.rebuild(args)
    }
    "torch._utils._rebuild_tensor_v2" => {
      guard (args.length() == 6 || args.length() == 7) && args[4] is PBool(_) else {
        fail("unsupported Torch tensor v2 rebuild signature")
      }
      torch_empty_hooks(args[5])
      if args.length() == 7 {
        if args[6] is PDict(metadata) {
          for name, value in metadata.fields {
            guard (name == "conj" || name == "neg") && value is PBool(false) else {
              fail("unsupported active Torch tensor metadata")
            }
          }
        } else {
          guard args[6] is PNone else {
            fail("unsupported Torch tensor metadata")
          }
        }
      }
      self.rebuild(args)
    }
    "torch._utils._rebuild_parameter" => {
      guard args.length() == 3 && args[0] is PTensor(_) && args[1] is PBool(_) else {
        fail("unsupported Torch parameter rebuild signature")
      }
      torch_empty_hooks(args[2])
      args[0]
    }
    _ => fail("pickle global is not an allowed REDUCE constructor")
  }
}

///|
fn torch_output(
  item : TorchPickleItem,
  depth : Int32,
  budget? : Ref[Int32],
) -> TorchValue raise {
  let budget = budget.unwrap_or(Ref::new(1000000))
  budget.val -= 1
  guard budget.val >= 0 else {
    fail("Torch checkpoint expansion exceeds resource limit")
  }
  guard depth <= 256 else {
    fail("Torch checkpoint nesting exceeds 256 or contains a cycle")
  }
  match item {
    PNone => TorchNone
    PBool(v) => TorchBool(v)
    PInt(v) => TorchInt(v)
    PFloat(v) => TorchFloat(v)
    PString(v) => TorchString(v)
    PList(items) | PTuple(items) =>
      TorchList(items.map(v => torch_output(v, depth + 1, budget~)))
    PDict(dict) => {
      let out : Map[String, TorchValue] = Map([])
      for key, v in dict.fields {
        out[key] = torch_output(v, depth + 1, budget~)
      }
      TorchDict(out)
    }
    PTensor(tensor) => TorchTensor(tensor)
    PNumpyArray(array) => {
      guard array.tensor is Some(tensor) else {
        fail("NumPy array has no validated numeric BUILD state")
      }
      TorchTensor(tensor)
    }
    _ => fail("unresolved symbolic/storage object in Torch checkpoint output")
  }
}

///|
fn TorchPickleReader::decode(self : TorchPickleReader) -> TorchValue raise {
  guard self.byte() == 128 else {
    fail("Torch ZIP pickle requires PROTO header")
  }
  self.protocol = self.byte()
  guard self.protocol >= 2 && self.protocol <= 4 else {
    fail("supported Torch pickle protocols are 2, 3 and 4")
  }
  while self.cursor < self.input.length() {
    guard self.stack.length() <= 1000000 && self.memo.length() <= 1000000 else {
      fail("Torch pickle stack/memo exceeds resource limit")
    }
    if self.frame_end is Some(end) && self.cursor == end {
      self.frame_end = None
    }
    let opcode = self.byte()
    match opcode {
      46 => {
        guard self.stack.length() == 1 && self.cursor == self.input.length() else {
          fail("invalid pickle STOP stack or trailing bytes")
        }
        if self.frame_end is Some(end) {
          guard self.cursor == end else {
            fail("pickle STOP precedes FRAME end")
          }
        }
        return torch_output(self.pop(), 0)
      }
      149 => {
        guard self.protocol == 4 && self.frame_end is None else {
          fail("invalid pickle FRAME")
        }
        let size = self.length(8)
        guard size <= self.input.length() - self.cursor else {
          fail("truncated pickle FRAME")
        }
        self.frame_end = Some(self.cursor + size)
      }
      40 => self.stack.push(PMark)
      78 => self.stack.push(PNone)
      136 => self.stack.push(PBool(true))
      137 => self.stack.push(PBool(false))
      74 => self.stack.push(PInt(self.unsigned(4).to_int().to_int64()))
      75 => self.stack.push(PInt(self.unsigned(1)))
      77 => self.stack.push(PInt(self.unsigned(2)))
      138 => {
        let count = self.byte()
        guard count <= 8 else { fail("pickle LONG1 exceeds Int64 range") }
        let bytes = self.take(count)
        let mut bits = 0L
        for i, b in bytes {
          bits = bits | (b.to_int().to_int64() << (8 * i))
        }
        if count > 0 && count < 8 && bytes[count - 1].to_int() >= 128 {
          bits = bits | (-1L << (count * 8))
        }
        self.stack.push(PInt(bits))
      }
      71 => {
        let bytes = self.take(8)
        let mut bits = 0L
        for b in bytes {
          bits = (bits << 8) | b.to_int().to_int64()
        }
        self.stack.push(PFloat(bits.reinterpret_as_double()))
      }
      88 | 140 => {
        let size = if opcode == 88 { self.length(4) } else { self.byte() }
        self.stack.push(PString(@utf8.decode(self.take(size))))
      }
      66 | 67 | 142 => {
        let size = if opcode == 67 {
          self.byte()
        } else {
          self.length(if opcode == 66 { 4 } else { 8 })
        }
        self.stack.push(PBytes(self.take(size)))
      }
      125 => self.stack.push(empty_torch_dict(false))
      93 => self.stack.push(PList([]))
      41 => self.stack.push(PTuple([]))
      100 => {
        let items = self.marked()
        guard items.length() % 2 == 0 else {
          fail("odd pickle DICT key/value count")
        }
        let dict = { fields: Map([]), key_kinds: Map([]), ordered: false, }
        for i in 0..<(items.length() / 2) {
          torch_set(dict, items[i * 2], items[i * 2 + 1])
        }
        self.stack.push(PDict(dict))
      }
      108 => self.stack.push(PList(self.marked()))
      116 => self.stack.push(PTuple(self.marked()))
      133 | 134 | 135 => {
        let count = opcode - 132
        guard self.stack.length() >= count else {
          fail("pickle tuple stack underflow")
        }
        let items = self.stack[self.stack.length() - count:].to_owned()
        for _ in 0..<count {
          ignore(self.stack.pop())
        }
        self.stack.push(PTuple(items))
      }
      115 => {
        let value = self.pop()
        let key = self.pop()
        guard self.top() is PDict(dict) else {
          fail("pickle SETITEM requires dictionary")
        }
        torch_set(dict, key, value)
      }
      117 => {
        let items = self.marked()
        guard items.length() % 2 == 0 && self.top() is PDict(dict) else {
          fail("pickle SETITEMS requires dictionary and key/value pairs")
        }
        for i in 0..<(items.length() / 2) {
          torch_set(dict, items[i * 2], items[i * 2 + 1])
        }
      }
      97 => {
        let value = self.pop()
        guard self.top() is PList(items) else {
          fail("pickle APPEND requires list")
        }
        items.push(value)
      }
      101 => {
        let values = self.marked()
        guard self.top() is PList(items) else {
          fail("pickle APPENDS requires list")
        }
        items.append(values)
      }
      113 | 114 => {
        let index = if opcode == 113 { self.byte() } else { self.length(4) }
        self.memo[index] = self.top()
      }
      104 | 106 => {
        let index = if opcode == 104 { self.byte() } else { self.length(4) }
        guard self.memo.get(index) is Some(value) else {
          fail("undefined Torch pickle memo index")
        }
        self.stack.push(value)
      }
      148 => {
        guard self.protocol == 4 else {
          fail("MEMOIZE requires pickle protocol 4")
        }
        self.memo[self.memo.length()] = self.top()
      }
      99 => {
        let module = self.line()
        let name = self.line()
        self.stack.push(torch_global(module, name))
      }
      147 => {
        guard self.protocol == 4 else {
          fail("STACK_GLOBAL requires pickle protocol 4")
        }
        let name = self.pop()
        let module = self.pop()
        guard name is PString(name) && module is PString(module) else {
          fail("STACK_GLOBAL requires module/name strings")
        }
        self.stack.push(torch_global(module, name))
      }
      81 => self.stack.push(self.persistent(self.pop()))
      82 => {
        let args = self.pop()
        let callable = self.pop()
        self.stack.push(self.reduce(callable, args))
      }
      98 => {
        let state = self.pop()
        match self.top() {
          PDict({ ordered: true, .. }) => {
            guard state is PDict(attrs) else {
              fail("OrderedDict BUILD state must be dictionary")
            }
            for key, value in attrs.fields {
              guard key == "_metadata" && value is PDict(_) else {
                fail("unsupported OrderedDict BUILD state")
              }
              ignore(torch_output(value, 0))
            }
          }
          PNumpyDtype(dtype) => numpy_dtype_build(dtype, state)
          PNumpyArray(array) => self.numpy_array_build(array, state)
          _ =>
            fail(
              "BUILD is restricted to validated numeric NumPy and OrderedDict metadata",
            )
        }
      }
      _ => fail("unsupported Torch pickle opcode: " + opcode.to_string())
    }
  }
  fail("Torch pickle has no STOP")
}

///|
/// Read only numeric tensor checkpoints inside Torch's ZIP format; never execute pickle callables.
/// Individual views are limited to 16M elements and total materialization to 128M elements.
pub fn decode_torch_checkpoint(bytes : Bytes) -> TorchValue raise {
  guard bytes.length() >= 4 && bytes[0:4] == b"PK\x03\x04" else {
    fail("Torch checkpoint must use modern ZIP serialization")
  }
  let entries = decode_zip(bytes)
  let mut root : String? = None
  for name, _ in entries {
    if name == "data.pkl" || name.has_suffix("/data.pkl") {
      guard root is None else { fail("ambiguous Torch ZIP pickle roots") }
      root = Some(name[:name.length() - 8].to_owned())
    }
  }
  guard root is Some(root) && entries.get(root + "data.pkl") is Some(pickle) else {
    fail("Torch ZIP is missing data.pkl")
  }
  if entries.get(root + "byteorder") is Some(order) {
    guard @utf8.decode(order) == "little" else {
      fail("only little-endian Torch storage is supported")
    }
  }
  let reader : TorchPickleReader = {
    input: pickle,
    entries,
    root,
    stack: [],
    memo: Map([]),
    storage_types: Map([]),
    cursor: 0,
    frame_end: None,
    protocol: 0,
    tensor_elements: 0L,
  }
  reader.decode()
}

///|
pub async fn load_torch_checkpoint(
  path : String,
  expected_sha256? : String,
) -> TorchValue {
  let bytes = @fs.read_file(path).binary()
  if expected_sha256 is Some(expected) {
    guard sha256(bytes) == expected else {
      fail("Torch checkpoint SHA256 differs")
    }
  }
  decode_torch_checkpoint(bytes)
}
