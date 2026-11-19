///|
/// Numeric NPY arrays. Object/pickle arrays are deliberately unsupported.
pub(all) struct NumericArray {
  shape : Array[Int32]
  dtype : String
  values : Array[Double]
} derive(Debug)

///|
fn little(bytes : Bytes, offset : Int32, count : Int32) -> Int32 raise {
  guard offset >= 0 && count >= 0 && offset <= bytes.length() - count else {
    fail("truncated numeric archive")
  }
  let mut value = 0
  for i in 0..<count {
    value = value | (bytes[offset + i].to_int() << (8 * i))
  }
  value
}

///|
fn section(bytes : Bytes, offset : Int32, size : Int32) -> Bytes raise {
  guard offset >= 0 && size >= 0 && offset <= bytes.length() - size else {
    fail("truncated numeric archive")
  }
  bytes[offset:offset + size].to_owned()
}

///|
fn after(value : String, marker : String) -> String raise {
  let parts = value.split(marker).collect()
  guard parts.length() == 2 else { fail("unsupported NumPy header: " + marker) }
  parts[1].to_owned()
}

///|
pub fn decode_npy(bytes : Bytes) -> NumericArray raise {
  guard bytes.length() >= 10 && bytes[0:6] == b"\x93NUMPY" else {
    fail("expected NPY magic")
  }
  let major = bytes[6].to_int()
  guard bytes[7] == 0 && (major == 1 || major == 2 || major == 3) else {
    fail("unsupported NPY version")
  }
  let prefix = if major == 1 { 10 } else { 12 }
  let length = little(bytes, 8, prefix - 8)
  let header = @utf8.decode(section(bytes, prefix, length))
  guard header.contains("'fortran_order': False") else {
    fail("only row-major numeric NPY is supported")
  }
  let dtype = after(header, "'descr': '").split("'").next().unwrap().to_owned()
  let shape_text = after(header, "'shape': (").split(")").next().unwrap()
  let shape : Array[Int32] = []
  let mut count = 1
  for piece in shape_text.split(",") {
    let piece = piece.trim()
    if piece.is_empty() {
      continue
    }
    let size = @string.parse_int(piece)
    guard size >= 0 && (size == 0 || count <= 2147483647 / size) else {
      fail("invalid NPY shape")
    }
    count *= size
    shape.push(size)
  }
  let width = match dtype {
    "<f8" | "<i8" => 8
    "<f4" | "<i4" | "<u4" => 4
    "|b1" | "|u1" | "|i1" => 1
    _ => fail("unsupported NumPy dtype: " + dtype)
  }
  guard count <= 2147483647 / width &&
    prefix <= bytes.length() - length &&
    bytes.length() - prefix - length == count * width else {
    fail("NPY payload shape differs")
  }
  let values : Array[Double] = []
  for i in 0..<count {
    let offset = prefix + length + i * width
    let mut bits = 0L
    for j in 0..<width {
      bits = bits | (bytes[offset + j].to_int().to_int64() << (j * 8))
    }
    let value = match dtype {
      "<f8" => bits.reinterpret_as_double()
      "<f4" => Float::reinterpret_from_int(bits.to_int()).to_double()
      "<i8" => {
        guard bits >= -9007199254740992L && bits <= 9007199254740992L else {
          fail("NPY integer cannot be represented exactly as Double")
        }
        bits.to_double()
      }
      "<i4" => bits.to_int().to_double()
      "|i1" =>
        if bits >= 128 {
          (bits - 256).to_double()
        } else {
          bits.to_double()
        }
      "|b1" => {
        guard bits == 0 || bits == 1 else { fail("invalid NumPy boolean") }
        bits.to_double()
      }
      _ => bits.to_double()
    }
    guard value.abs() <= 1.7976931348623157e308 else {
      fail("nonfinite NPY tensor")
    }
    values.push(value)
  }
  { shape, dtype, values, }
}

///|
fn zip_u64(bytes : Bytes, offset : Int32) -> Int32 raise {
  guard little(bytes, offset + 4, 4) == 0 else {
    fail("ZIP64 value exceeds addressable artifact size")
  }
  let value = little(bytes, offset, 4)
  guard value >= 0 else {
    fail("ZIP64 value exceeds addressable artifact size")
  }
  value
}

///|
/// ZIP/ZIP64 numeric archives bounded by MoonBit's Int-sized byte arrays.
/// No extraction to the filesystem, encryption or multi-disk support.
pub fn decode_zip(bytes : Bytes) -> Map[String, Bytes] raise {
  guard bytes.length() >= 22 else { fail("truncated NPZ") }
  let mut end = bytes.length() - 22
  let minimum = (bytes.length() - 65557).max(0)
  while end >= minimum {
    if little(bytes, end, 4) == 0x06054b50 &&
      end + 22 + little(bytes, end + 20, 2) == bytes.length() {
      break
    }
    end -= 1
  }
  guard end >= minimum else { fail("missing NPZ central directory") }
  guard little(bytes, end + 4, 2) == 0 && little(bytes, end + 6, 2) == 0 else {
    fail("multi-disk NPZ unsupported")
  }
  let mut count = little(bytes, end + 10, 2)
  guard count == little(bytes, end + 8, 2) else {
    fail("multi-disk ZIP entry counts differ")
  }
  let mut offset = little(bytes, end + 16, 4)
  let mut central_size = little(bytes, end + 12, 4)
  let mut central_end = end
  let mut has_zip64 = false
  if end >= 20 && little(bytes, end - 20, 4) == 0x07064b50 {
    guard little(bytes, end - 16, 4) == 0 && little(bytes, end - 4, 4) == 1 else {
      fail("multi-disk ZIP64 unsupported")
    }
    let record = zip_u64(bytes, end - 12)
    guard record <= end - 76 && little(bytes, record, 4) == 0x06064b50 else {
      fail("invalid ZIP64 end record")
    }
    let record_size = zip_u64(bytes, record + 4)
    guard record_size >= 44 && record_size == end - 32 - record else {
      fail("invalid ZIP64 record size")
    }
    guard little(bytes, record + 16, 4) == 0 &&
      little(bytes, record + 20, 4) == 0 else {
      fail("multi-disk ZIP64 unsupported")
    }
    let entries = zip_u64(bytes, record + 32)
    guard entries == zip_u64(bytes, record + 24) else {
      fail("ZIP64 entry counts differ")
    }
    let size64 = zip_u64(bytes, record + 40)
    let offset64 = zip_u64(bytes, record + 48)
    guard (count == 65535 || count == entries) &&
      (central_size == -1 || central_size == size64) &&
      (offset == -1 || offset == offset64) else {
      fail("ZIP/ZIP64 directory metadata differ")
    }
    count = entries
    central_size = size64
    offset = offset64
    central_end = record
    has_zip64 = true
  }
  guard (count != 65535 || has_zip64) &&
    offset >= 0 &&
    central_size >= 0 &&
    offset <= central_end &&
    central_size == central_end - offset else {
    fail("invalid ZIP directory size")
  }
  let central_start = offset
  let result : Map[String, Bytes] = {}
  for _ in 0..<count {
    guard offset >= 0 && offset <= central_end - 46 else {
      fail("truncated NPZ central member")
    }
    guard little(bytes, offset, 4) == 0x02014b50 else {
      fail("invalid NPZ member")
    }
    let flags = little(bytes, offset + 8, 2)
    let method = little(bytes, offset + 10, 2)
    guard (flags & 1) == 0 && (method == 0 || method == 8) else {
      fail("unsupported NPZ compression/encryption")
    }
    let mut packed = little(bytes, offset + 20, 4)
    let mut size = little(bytes, offset + 24, 4)
    let name_len = little(bytes, offset + 28, 2)
    let extra_len = little(bytes, offset + 30, 2)
    let comment_len = little(bytes, offset + 32, 2)
    guard name_len + extra_len + comment_len <= central_end - offset - 46 &&
      little(bytes, offset + 34, 2) == 0 else {
      fail("invalid ZIP member directory fields")
    }
    let name = @utf8.decode(section(bytes, offset + 46, name_len))
    let mut local = little(bytes, offset + 42, 4)
    let extra_start = offset + 46 + name_len
    guard extra_start <= central_end && extra_len <= central_end - extra_start else {
      fail("truncated ZIP extra fields")
    }
    if packed == -1 || size == -1 || local == -1 {
      let mut cursor = extra_start
      let mut found = false
      while cursor < extra_start + extra_len {
        guard cursor <= extra_start + extra_len - 4 else {
          fail("truncated ZIP64 extra field")
        }
        let kind = little(bytes, cursor, 2)
        let length = little(bytes, cursor + 2, 2)
        let last = cursor + 4 + length
        guard last <= extra_start + extra_len else {
          fail("invalid ZIP64 extra field size")
        }
        if kind == 1 {
          cursor += 4
          if size == -1 {
            guard cursor <= last - 8 else { fail("missing ZIP64 member size") }
            size = zip_u64(bytes, cursor)
            cursor += 8
          }
          if packed == -1 {
            guard cursor <= last - 8 else { fail("missing ZIP64 packed size") }
            packed = zip_u64(bytes, cursor)
            cursor += 8
          }
          if local == -1 {
            guard cursor <= last - 8 else {
              fail("missing ZIP64 member offset")
            }
            local = zip_u64(bytes, cursor)
          }
          found = true
          break
        }
        cursor = last
      }
      guard found else { fail("missing ZIP64 member metadata") }
    }
    guard local >= 0 && local <= central_start - 30 else {
      fail("invalid NPZ local offset")
    }
    guard little(bytes, local, 4) == 0x04034b50 else {
      fail("invalid local NPZ header")
    }
    let local_name_len = little(bytes, local + 26, 2)
    guard @utf8.decode(section(bytes, local + 30, local_name_len)) == name &&
      little(bytes, local + 8, 2) == method else {
      fail("NPZ local header differs")
    }
    let start = local + 30 + local_name_len + little(bytes, local + 28, 2)
    guard packed >= 0 &&
      start >= local &&
      start <= central_start &&
      packed <= central_start - start else {
      fail("NPZ payload overlaps directory")
    }
    let compressed = section(bytes, start, packed)
    let payload = if method == 8 {
      decompress(compressed, raw=true)
    } else {
      compressed
    }
    guard payload.length() == size else {
      fail("NPZ uncompressed size differs")
    }
    let crc = crc32(payload)
    for j in 0..<4 {
      guard ((crc >> (j * 8)) & 255U).to_int() ==
        bytes[offset + 16 + j].to_int() else {
        fail("NPZ member checksum differs")
      }
    }
    guard !result.contains(name) else { fail("duplicate ZIP member") }
    result[name] = payload
    offset += 46 + name_len + extra_len + comment_len
  }
  guard offset == central_end else {
    fail("NPZ central directory entry count differs")
  }
  result
}

///|
pub fn decode_npz(bytes : Bytes) -> Map[String, NumericArray] raise {
  let result : Map[String, NumericArray] = {}
  for name, payload in decode_zip(bytes) {
    guard name.has_suffix(".npy") else {
      fail("non-NPY member in numeric archive")
    }
    result[name.strip_suffix(".npy").unwrap().to_owned()] = decode_npy(payload)
  }
  result
}

///|
/// Write portable C-order NPY without pickle or a Python runtime. Float64 is
/// the default; typed archives preserve their declared dtype without narrowing.
pub fn encode_npy(
  shape : Array[Int32],
  values : Array[Double],
  dtype~ : String = "<f8",
) -> Bytes raise {
  let width = match dtype {
    "<f8" | "<i8" => 8
    "<f4" | "<i4" | "<u4" => 4
    "|b1" | "|u1" | "|i1" => 1
    _ => fail("unsupported NumPy output dtype: " + dtype)
  }
  let mut count = 1
  for size in shape {
    guard size >= 0 && (size == 0 || count <= 2147483647 / size) else {
      fail("invalid NPY shape")
    }
    count *= size
  }
  guard count == values.length() && count <= (2147483647 - 65546) / width else {
    fail("NPY shape differs from values")
  }
  let dims = shape.map(n => n.to_string()).join(", ") +
    (if shape.length() == 1 { "," } else { "" })
  let header = "{'descr': '" +
    dtype +
    "', 'fortran_order': False, 'shape': (" +
    dims +
    "), }"
  let padding = (64 - (10 + header.length() + 1) % 64) % 64
  let header = header + String::make(padding, ' ') + "\n"
  guard header.length() < 65536 else {
    fail("NPY header exceeds version 1 limit")
  }
  let output : Array[Byte] = [
    0x93,
    0x4e,
    0x55,
    0x4d,
    0x50,
    0x59,
    1,
    0,
    (header.length() & 255).to_byte(),
    (header.length() >> 8).to_byte(),
  ]
  for byte in @utf8.encode(header) {
    output.push(byte)
  }
  for value in values {
    guard value.abs() <= 1.7976931348623157e308 else {
      fail("nonfinite NPY tensor")
    }
    let bits = match dtype {
      "<f8" => value.reinterpret_as_int64()
      "<f4" => {
        let narrowed = Float::from_double(value)
        guard narrowed.to_double() == value else {
          fail("NPY Float32 output would narrow the supplied value")
        }
        narrowed.reinterpret_as_int().to_int64()
      }
      _ => {
        let (minimum, maximum) = match dtype {
          "<i8" => (-9007199254740992.0, 9007199254740992.0)
          "<i4" => (-2147483648.0, 2147483647.0)
          "<u4" => (0.0, 4294967295.0)
          "|i1" => (-128.0, 127.0)
          "|u1" => (0.0, 255.0)
          _ => (0.0, 1.0)
        }
        guard value.trunc() == value && value >= minimum && value <= maximum else {
          fail("NPY integer/boolean output is out of range or fractional")
        }
        value.to_int64()
      }
    }
    for i in 0..<width {
      output.push(((bits >> (8 * i)).to_int() & 255).to_byte())
    }
  }
  Bytes::from_array(output)
}
