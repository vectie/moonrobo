///|
/// Same declared stream as the native physics CLI; this tests the seeded
/// contract, not equivalence to NumPy PCG64's integer-seed sequence.
fn seeded_offsets(names : Array[String], seed : Int32) -> Array[Double] raise {
  let rng = @random.Rand::chacha8(
    seed=Bytes::from_array(
      @crypto.sha256(@utf8.encode("moonrobo:\{seed}:1729")),
    ),
  )
  let uniform = Array::makei(names.length(), _ => rng.double() * 2 - 1)
  @learning_physics.pose_offset(names, 0.04, 0.08, 0.12, uniform)
}

///|
test "pose offsets repeat by seed and cover every joint group bound" {
  let names = [
    "left_hip_pitch_joint", "waist_yaw_joint", "left_shoulder_pitch_joint", "right_wrist_yaw_joint",
  ]
  let first = seeded_offsets(names, 0)
  assert_eq(first, seeded_offsets(names, 0))
  let limits = [0.04, 0.08, 0.12, 0.12]
  let samples = Array::makei(12, seed => seeded_offsets(names, seed))
  for sample in samples {
    for i, value in sample {
      assert_true(value.abs() <= limits[i])
    }
  }
  for coordinate in 0..<names.length() {
    let mut minimum = samples[0][coordinate]
    let mut maximum = minimum
    for sample in samples {
      if sample[coordinate] < minimum {
        minimum = sample[coordinate]
      }
      if sample[coordinate] > maximum {
        maximum = sample[coordinate]
      }
    }
    assert_true(maximum - minimum > 0.01)
  }
}

///|
test "invalid pose amplitudes are rejected" {
  let rejected = try
    @learning_physics.pose_offset(["waist_yaw_joint"], 0.04, 0.0 / 0.0, 0.12, [
      0.25,
    ])
  catch {
    _ => true
  } noraise {
    _ => false
  }
  assert_true(rejected)
}
