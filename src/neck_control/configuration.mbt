///|
fn[B : Bus] configuration_snapshot(bus : B) -> Json raise {
  let motors : Array[Json] = []
  for id in [7, 8] {
    let identity = bus.transfer(id, 2, [0, 34], 34, 0L)
    validate_identity(id, identity)
    let factory = bus.transfer(id, 2, [80, 7], 7, 0L)
    guard factory.length() == 7 else {
      raise Transport("Factory diagnostic block needs registers 80 through 86")
    }
    let row : Json = {
      "id": Json(id),
      "phase": Json(identity[18].to_int()),
      "p_coefficient": Json(identity[21].to_int()),
      "d_coefficient": Json(identity[22].to_int()),
      "i_coefficient": Json(identity[23].to_int()),
      "startup_force": Json(identity[24].to_int()),
      "integral_limit": Json(identity[25].to_int()),
      "cw_dead_zone": Json(identity[26].to_int()),
      "ccw_dead_zone": Json(identity[27].to_int()),
      "factory_block_80_86": Json(factory.to_array().map(b => b.to_int())),
      "moving_velocity_threshold": Json(factory[0].to_int()),
      "dts_ms": Json(factory[1].to_int()),
      "velocity_unit_factor": Json(factory[2].to_int()),
      "minimum_speed_limit": Json(factory[3].to_int()),
      "maximum_speed_limit": Json(factory[4].to_int()),
      "maximum_acceleration": Json(factory[5].to_int()),
      "acceleration_multiplier": Json(factory[6].to_int()),
      "feedback": Json(observe(bus, id)),
    }
    bus.event("configuration-readonly", row)
    motors.push(row)
  }
  { "read_only": true, "motors": Json(motors) }
}

///|
/// Fixed read-only diagnostic, available even while a motion fault is latched.
/// It cannot clear a marker, change configuration, or address arbitrary motors.
pub fn read_configuration(log_path : String) -> Json raise {
  guard log_path.has_prefix("/") && !log_path.contains("\u{0}") else {
    raise Rejected("Audit path must be absolute")
  }
  let fd = serial_open(
    @utf8.encode("/dev/serial/by-id/usb-1a86_USB_Single_Serial_5AB0182917-if00"),
  )
  guard fd >= 0 else { raise Transport(@utf8.decode_lossy(native_error())) }
  defer serial_close(fd)
  let bus : Serial = {
    fd,
    log_path,
    run_id: "\{epoch_ms()}-\{clock_ms()}",
    sequence: 0,
    writes: 0,
    joystick: None,
    stick_required: false,
  }
  bus.event("configuration-request-readonly", Json(true))
  configuration_snapshot(bus)
}
