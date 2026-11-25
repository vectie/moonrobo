///|
priv struct StickCalibration {
  controller : String
  operator_confirmed_neutral : Bool
  x_min : Int32
  x_center : Int32
  x_max : Int32
  y_min : Int32
  y_center : Int32
  y_max : Int32
} derive(Debug, ToJson, FromJson)

///|
priv struct Joystick {
  device : JoyDevice
  calibration : StickCalibration
  buttons : Bool
}

///|
fn factory_stick_calibration() -> StickCalibration {
  {
    controller: "98:B6:E9:20:21:41",
    operator_confirmed_neutral: false,
    x_min: -1000,
    x_center: 0,
    x_max: 1000,
    y_min: -1000,
    y_center: 0,
    y_max: 1000,
  }
}

///|
fn validate_stick_calibration(c : StickCalibration) -> Unit raise NeckError {
  guard c.controller == "98:B6:E9:20:21:41" && c.operator_confirmed_neutral else {
    raise Rejected(
      "Stick calibration needs this controller and explicit neutral confirmation",
    )
  }
  for
    (minimum, center, maximum) in [
      (c.x_min, c.x_center, c.x_max),
      (c.y_min, c.y_center, c.y_max),
    ] {
    guard minimum >= -1000 &&
      maximum <= 1000 &&
      center >= -500 &&
      center <= 500 &&
      minimum < center &&
      center < maximum &&
      center - minimum >= 300 &&
      maximum - center >= 300 else {
      raise Rejected(
        "Stick calibration has reversed, narrow or implausible travel",
      )
    }
  }
}

///|
fn load_stick_calibration(required : Bool) -> StickCalibration raise {
  let path = "/home/elf/moonrobo-neck/joycon-calibration.json"
  if !@fs.path_exists(path) {
    guard !required else {
      raise Rejected(
        "Physical joystick sessions require a saved, confirmed calibration",
      )
    }
    return factory_stick_calibration()
  }
  let c : StickCalibration = @json.from_json(
    @json.parse(@fs.read_file_to_string(path)),
  )
  validate_stick_calibration(c)
  c
}

///|
fn correct_stick_axis(
  value : Int32,
  minimum : Int32,
  center : Int32,
  maximum : Int32,
) -> Int32 {
  // Saturate input travel only. Servo targets still use their independent,
  // fixed absolute envelope and one-tick rate guard.
  if value < center {
    Int32::max(-1000, (value - center) * 1000 / (center - minimum))
  } else {
    Int32::min(1000, (value - center) * 1000 / (maximum - center))
  }
}
