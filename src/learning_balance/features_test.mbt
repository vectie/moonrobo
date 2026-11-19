///|
fn fixture_geometry() -> Kinematics {
  {
    nu: 1,
    bodies: [
      {
        parent: -1,
        position: [0.0, 0.0, 0.0],
        quaternion_wxyz: [1.0, 0.0, 0.0, 0.0],
        com_position: [0.03, 0.04, -0.04],
        mass: 2.0,
        joints: [],
      },
      {
        parent: 0,
        position: [0.2, 0.0, -0.1],
        quaternion_wxyz: [1.0, 0.0, 0.0, 0.0],
        com_position: [0.05, -0.02, -0.1],
        mass: 1.0,
        joints: [
          {
            observation_index: 0,
            axis: [0.0, 1.0, 0.0],
            anchor: [0.04, 0.02, 0.01],
            reference: 0.3,
          },
        ],
      },
    ],
    feet: [
      { body: 0, position: [0.0, 0.1, -0.8], },
      { body: 1, position: [0.0, -0.1, -0.7], },
    ],
  }
}

///|
test "online finite and full observers equal offline prefixes and reset cleanly" {
  let geometry = fixture_geometry()
  let observations = Array::makei(80, fn(i) {
    let t = i.to_double()
    let a = 0.02 * t
    [
      0.3 + 0.1 * @math.sin(0.2 * t),
      0.0,
      @math.sin(a),
      0.0,
      -@math.cos(a),
      0.0,
      1.0,
      0.0,
      0.0,
    ]
  })
  for window in [Some(10), None] {
    let observer = match window {
      Some(n) => BalanceHistory::new(geometry, 0.02, window=n)
      None => BalanceHistory::full_memory(geometry, 0.02)
    }
    let offline = sequence_features(
      geometry,
      observations,
      0.02,
      window,
      GravityGyro,
    )
    for i, row in observations {
      let online = observer.observe(row)
      for j in 0..<6 {
        assert_true(
          (online[j] - offline[i][j]).abs() <=
          1.0e-13 + 1.0e-12 * offline[i][j].abs(),
        )
      }
    }
    let prefix = sequence_features(
      geometry,
      observations[:8].to_owned(),
      0.02,
      window,
      GravityGyro,
    )
    for i, row in prefix {
      for j, x in row {
        assert_true(
          (x - offline[i][j]).abs() <= 1.0e-13 + 1.0e-12 * offline[i][j].abs(),
        )
      }
    }
    let fresh = BalanceHistory::full_memory(geometry, 0.02)
    let first = fresh.observe(observations[20])
    assert_eq([first[3], first[4], first[5]], [0.0, 0.0, 0.0])
  }
}

///|
test "gravity correction aligns adjacent frames without gyro" {
  let gravity = Array::makei(30, fn(i) {
    let a = i.to_double() * 0.014
    [@math.sin(a), 0.0, -@math.cos(a)]
  })
  let transports = observation_transports(
    gravity,
    Array::makei(30, fn(_) { [0.0, 0.0, 0.0] }),
    0.02,
    GravityGyro,
  )
  for i in 1..<30 {
    let predicted = matvec(transports[i], gravity[i - 1])
    for j in 0..<3 {
      assert_true((predicted[j] - gravity[i][j]).abs() <= 1.0e-14)
    }
  }
}
