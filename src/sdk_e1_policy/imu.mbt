///|
/// All matrices are row-major, right-handed rotations. Calibration is explicit:
/// no vendor quaternion order, direction, gyro frame or units are assumed.
pub(all) struct ImuCalibration {
  quaternion_order : String
  orientation_direction : String
  gyro_frame : String
  gyro_to_radians : Double
  sensor_to_body : Array[Double]
  world_to_actor_world : Array[Double]
} derive(FromJson)

///|
pub extend ImuCalibration with @json.FromJson::{from_json}

///|
pub struct Imu {
  priv order : String
  priv inverse : Bool
  priv gyro_frame : String
  priv gyro_scale : Double
  priv mount : Array[Double]
  priv world : Array[Double]
}

///|
pub struct ImuFeatures {
  priv gyro : Array[Double]
  priv down : Array[Double]
  priv reference : Array[Double]
}

///|
fn transpose(matrix : ArrayView[Double]) -> Array[Double] {
  Array::makei(9, i => matrix[i % 3 * 3 + i / 3])
}

///|
fn multiply(a : ArrayView[Double], b : ArrayView[Double]) -> Array[Double] {
  Array::makei(9, i => {
    let r = i / 3 * 3
    let c = i % 3
    a[r] * b[c] + a[r + 1] * b[3 + c] + a[r + 2] * b[6 + c]
  })
}

///|
fn transform(
  matrix : ArrayView[Double],
  vector : ArrayView[Double],
) -> Array[Double] {
  Array::makei(3, r => {
    matrix[r * 3] * vector[0] +
    matrix[r * 3 + 1] * vector[1] +
    matrix[r * 3 + 2] * vector[2]
  })
}

///|
fn rotation(matrix : ArrayView[Double]) -> Bool {
  if matrix.length() != 9 || !matrix.all(finite) {
    return false
  }
  let product = multiply(matrix, transpose(matrix)[:])
  let determinant = matrix[0] * (matrix[4] * matrix[8] - matrix[5] * matrix[7]) -
    matrix[1] * (matrix[3] * matrix[8] - matrix[5] * matrix[6]) +
    matrix[2] * (matrix[3] * matrix[7] - matrix[4] * matrix[6])
  for i in 0..<9 {
    if (product[i] - (if i / 3 == i % 3 { 1.0 } else { 0.0 })).abs() > 1.0e-6 {
      return false
    }
  }
  (determinant - 1.0).abs() <= 1.0e-6
}

///|
pub fn Imu::new(calibration : ImuCalibration) -> Self raise {
  guard ["wxyz", "xyzw"].contains(calibration.quaternion_order) &&
    ["sensor_to_world", "world_to_sensor"].contains(
      calibration.orientation_direction,
    ) &&
    ["sensor", "body", "world"].contains(calibration.gyro_frame) &&
    finite(calibration.gyro_to_radians) &&
    calibration.gyro_to_radians > 0.0 &&
    rotation(calibration.sensor_to_body[:]) &&
    rotation(calibration.world_to_actor_world[:]) else {
    fail("unsupported or invalid IMU frame calibration")
  }
  {
    order: calibration.quaternion_order,
    inverse: calibration.orientation_direction == "world_to_sensor",
    gyro_frame: calibration.gyro_frame,
    gyro_scale: calibration.gyro_to_radians,
    mount: calibration.sensor_to_body.copy(),
    world: calibration.world_to_actor_world.copy(),
  }
}

///|
/// Reference rotation maps the reference body into the same actor world used
/// by calibration. Quaternion magnitude is normalized; zero/nonfinite is invalid.
pub fn Imu::decode(
  self : Self,
  orientation : ArrayView[Double],
  gyro : ArrayView[Double],
  reference_body_to_world : ArrayView[Double],
) -> ImuFeatures raise {
  guard orientation.length() == 4 &&
    orientation.all(finite) &&
    gyro.length() == 3 &&
    gyro.all(finite) &&
    reference_body_to_world.length() == 9 &&
    reference_body_to_world.all(finite) else {
    fail("invalid IMU/reference dimensions or finite values")
  }
  let scale = orientation.fold(init=0.0, (largest, value) => {
    largest.max(value.abs())
  })
  guard scale > 0.0 else { fail("zero IMU quaternion") }
  let norm = orientation
    .fold(init=0.0, (sum, value) => {
      let scaled = value / scale
      sum + scaled * scaled
    })
    .sqrt()
  let q = orientation.map(value => value / scale / norm)
  let (w, x, y, z) = if self.order == "wxyz" {
    (q[0], q[1], q[2], q[3])
  } else {
    (q[3], q[0], q[1], q[2])
  }
  let measured = [
    1.0 - 2.0 * (y * y + z * z),
    2.0 * (x * y - w * z),
    2.0 * (x * z + w * y),
    2.0 * (x * y + w * z),
    1.0 - 2.0 * (x * x + z * z),
    2.0 * (y * z - w * x),
    2.0 * (x * z - w * y),
    2.0 * (y * z + w * x),
    1.0 - 2.0 * (x * x + y * y),
  ]
  let sensor_to_world = if self.inverse {
    transpose(measured[:])
  } else {
    measured
  }
  let body_to_world = multiply(
    multiply(self.world[:], sensor_to_world[:])[:],
    transpose(self.mount[:])[:],
  )
  let body_gyro = match self.gyro_frame {
    "sensor" => transform(self.mount[:], gyro)
    "body" => gyro.to_owned()
    _ =>
      transform(
        transpose(body_to_world[:])[:],
        transform(self.world[:], gyro)[:],
      )
  }
  let relative = multiply(
    transpose(body_to_world[:])[:],
    reference_body_to_world,
  )
  let result : ImuFeatures = {
    gyro: body_gyro.map(value => value * self.gyro_scale),
    down: [-body_to_world[6], -body_to_world[7], -body_to_world[8]],
    // Training mat_to_6d is row-interleaved, not column-concatenated.
    reference: [
      relative[0],
      relative[1],
      relative[3],
      relative[4],
      relative[6],
      relative[7],
    ],
  }
  guard result.gyro.all(finite) &&
    result.down.all(finite) &&
    result.reference.all(finite) else {
    fail("IMU conversion overflow")
  }
  result
}

///|
pub fn ImuFeatures::body_gyro(self : Self) -> ReadOnlyArray[Double] {
  ReadOnlyArray::from_array(self.gyro)
}

///|
pub fn ImuFeatures::gravity(self : Self) -> ReadOnlyArray[Double] {
  ReadOnlyArray::from_array(self.down)
}

///|
pub fn ImuFeatures::reference_orientation(self : Self) -> ReadOnlyArray[Double] {
  ReadOnlyArray::from_array(self.reference)
}
