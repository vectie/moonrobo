///|
fn request_packet(
  id : Int32,
  instruction : Int32,
  parameters : Array[Byte],
) -> Bytes {
  let buffer = @buffer.Buffer()
  buffer.write_bytes(b"\xff\xff")
  buffer.write_byte(id.to_byte())
  buffer.write_byte((parameters.length() + 2).to_byte())
  buffer.write_byte(instruction.to_byte())
  let mut sum = id + parameters.length() + 2 + instruction
  for byte in parameters {
    buffer.write_byte(byte)
    sum += byte.to_int()
  }
  buffer.write_byte((255 - (sum & 255)).to_byte())
  buffer.to_bytes()
}

///|
fn response_payload(
  raw : Bytes,
  id : Int32,
  count : Int32,
) -> Bytes raise NeckError {
  guard raw.length() == count + 6 else {
    raise Transport("Truncated or excess serial reply")
  }
  guard raw[0] == 255 &&
    raw[1] == 255 &&
    raw[2].to_int() == id &&
    raw[3].to_int() == count + 2 else {
    raise Transport("Reply ID / header / length mismatch")
  }
  let mut sum = 0
  for i in 2..<raw.length() {
    sum += raw[i].to_int()
  }
  guard (sum & 255) == 255 else { raise Transport("Reply checksum mismatch") }
  guard raw[4] == 0 else {
    raise Rejected("Servo error byte \{raw[4].to_int()}")
  }
  Bytes::from_array(Array::makei(count, i => raw[i + 5]))
}

///|
fn word(data : Bytes, index : Int32) -> Int32 {
  data[index].to_int() + (data[index + 1].to_int() << 8)
}

///|
fn signed_magnitude(value : Int32, sign : Int32) -> Int32 {
  let magnitude = value & (sign - 1)
  if (value & sign) == 0 {
    magnitude
  } else {
    -magnitude
  }
}

///|
fn decode_feedback(
  id : Int32,
  data : Bytes,
  captured_ms : Int64,
) -> Feedback raise NeckError {
  guard data.length() == 38 else {
    raise Transport("Feedback needs registers 33 through 70")
  }
  {
    id,
    captured_ms,
    mode: data[0].to_int(),
    torque: data[7].to_int(),
    acceleration: data[8].to_int(),
    goal: word(data, 9),
    goal_time: word(data, 11),
    speed_limit: word(data, 13),
    torque_limit: word(data, 15),
    position: signed_magnitude(word(data, 23), 32768),
    velocity: signed_magnitude(word(data, 25), 32768),
    load: signed_magnitude(word(data, 27), 1024),
    voltage_tenths: data[29].to_int(),
    temperature: data[30].to_int(),
    status: data[32].to_int(),
    current_raw: signed_magnitude(word(data, 36), 32768),
  }
}

///|
fn validate_identity(id : Int32, bytes : Bytes) -> Unit raise NeckError {
  guard bytes.length() == 34 &&
    bytes[0] == 3 &&
    bytes[1] == 10 &&
    word(bytes, 3) == 777 &&
    bytes[5].to_int() == id &&
    bytes[18] == 12 &&
    bytes[30] == 1 else {
    raise Rejected("Motor identity / firmware / phase / resolution mismatch")
  }
  let expected = match id {
    7 => (933, 3043, 3948)
    8 => (1040, 3204, 1882)
    _ => raise Rejected("Unknown motor")
  }
  guard (word(bytes, 9), word(bytes, 11), word(bytes, 31)) == expected else {
    raise Rejected("Calibration fingerprint changed; explicit review required")
  }
}
