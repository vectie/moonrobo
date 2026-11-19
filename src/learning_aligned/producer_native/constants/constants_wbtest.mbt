///|
/// Pending scientific regression sources. No tests/numerical examples are run
/// while the migration's machine availability restriction is active.
fn rejected(work : () -> Unit raise) -> Bool {
  try {
    work()
    false
  } catch {
    _ => true
  }
}

///|
fn near(actual : Double, expected : Double) -> Unit raise {
  assert_true((actual - expected).abs() <= 1.0e-11)
}

///|
test "principal inertia preserves tensor eigenvalues and proper MuJoCo frame" {
  let tensor : @geometry.Basis3 = {
    xx: 3.0,
    xy: 1.0,
    xz: 0.0,
    yx: 1.0,
    yy: 3.0,
    yz: 0.0,
    zx: 0.0,
    zy: 0.0,
    zz: 1.0,
  }
  let result = principal_inertia(tensor)
  near(result.moments.x, 4.0)
  near(result.moments.y, 2.0)
  near(result.moments.z, 1.0)
  let q = result.orientation
  near(q.w * q.w + q.x * q.x + q.y * q.y + q.z * q.z, 1.0)
  let x = result.axes.mul_vec3(@geometry.vec3(1.0, 0.0, 0.0))
  let y = result.axes.mul_vec3(@geometry.vec3(0.0, 1.0, 0.0))
  let z = result.axes.mul_vec3(@geometry.vec3(0.0, 0.0, 1.0))
  near(x.cross(y).dot(z), 1.0)
  assert_true(
    rejected(fn() raise { ignore(principal_inertia({ ..tensor, yx: 2.0, })) }),
  )
  assert_true(
    rejected(fn() raise { ignore(principal_inertia({ ..tensor, zz: -1.0, })) }),
  )
}

///|
test "mapped body update retains sentinel and omitted gravcomp" {
  let old : BodyConstant = {
    mass: 0.0,
    ipos: @geometry.vec3(0.0, 0.0, 0.0),
    inertia: @geometry.vec3(0.0, 0.0, 0.0),
    iquat: { w: 1.0, x: 0.0, y: 0.0, z: 0.0, },
    gravcomp: 0.7,
  }
  let result = update_bodies({
    newton: {
      mass: [2.0],
      com: [@geometry.vec3(1.0, 2.0, 3.0)],
      inertia: [
        {
          xx: 1.0,
          xy: 0.0,
          xz: 0.0,
          yx: 0.0,
          yy: 2.0,
          yz: 0.0,
          zx: 0.0,
          zy: 0.0,
          zz: 3.0,
        },
      ],
      gravcomp: None,
    },
    mapping: [[-1, 0]],
    existing: [[old, old]],
  })
  assert_eq(result[0][0].mass, 0.0)
  assert_eq(result[0][1].mass, 2.0)
  assert_eq(result[0][1].ipos.x, 1.0)
  assert_eq(result[0][1].gravcomp, 0.7)
  assert_eq(result[0][1].inertia.x, 3.0)
}

///|
test "subtree masses follow real parent topology and shared world broadcasting" {
  let request : SubtreeRequest = {
    parent: [0, 2, 0, 2],
    body_mass: [[0.0, 1.0, 2.0, 3.0]],
    output_worlds: 2,
  }
  let result = subtree_masses(request)
  assert_eq(result, [[6.0, 1.0, 6.0, 3.0], [6.0, 1.0, 6.0, 3.0]])
  assert_eq(request.body_mass, [[0.0, 1.0, 2.0, 3.0]])
  assert_true(
    rejected(fn() raise {
      ignore(subtree_masses({ ..request, parent: [0, 2, 1, 2], }))
    }),
  )
}

///|
test "physical mean inertia consumes CSR diagonals not flat dense diagonals" {
  let request : MeanInertiaRequest = {
    nv: 2,
    row_nnz: [1, 2],
    row_adr: [0, 1],
    matrix: [[2.0, -0.5, 6.0], [4.0, -1.0, 8.0]],
  }
  assert_eq(mean_inertia_from_mass_matrix(request), [4.0, 6.0])
  assert_eq(
    mean_inertia_from_mass_matrix({
      nv: 0,
      row_nnz: [],
      row_adr: [],
      matrix: [[]],
    }),
    [1.0],
  )
  assert_true(
    rejected(fn() raise {
      ignore(mean_inertia_from_mass_matrix({ ..request, row_adr: [0, 3], }))
    }),
  )
  assert_true(
    rejected(fn() raise {
      ignore(
        mean_inertia_from_mass_matrix({
          nv: 2,
          row_nnz: [1, 1],
          row_adr: [0, 0],
          matrix: [[2.0]],
        }),
      )
    }),
  )
  assert_true(
    rejected(fn() raise {
      ignore(
        mean_inertia_from_mass_matrix({
          ..request,
          matrix: [[2.0, -0.5, 6.0, 9.0]],
        }),
      )
    }),
  )
}

///|
test "pair margin suppression preserves compiled margin while gap still updates" {
  let old : PairConstant = {
    solref: [0.02, 1.0],
    solreffriction: [0.0, 0.0],
    solimp: [0.9, 0.95, 0.001, 0.5, 2.0],
    margin: 0.0,
    gap: 0.0,
    friction: [0.8, 0.8, 0.01, 0.001, 0.001],
  }
  let request : PairUpdate = {
    pairs_per_world: 1,
    existing: [[old], [old]],
    overrides: {
      solref: None,
      solreffriction: None,
      solimp: None,
      margin: Some([0.1, 0.2]),
      gap: Some([0.03, 0.04]),
      friction: None,
    },
    zero_native_ccd_margins: true,
  }
  let result = update_pairs(request)
  assert_eq(result[0][0].margin, 0.0)
  assert_eq(result[1][0].gap, 0.04)
  result[0][0].solref[0] = 9.0
  assert_eq(old.solref, [0.02, 1.0])
  assert_eq(
    update_pairs({ ..request, zero_native_ccd_margins: false, })[1][0].margin,
    0.2,
  )
}

///|
test "reference qpos saves and restores independent host copies only" {
  let request : ReferenceRequest = {
    qpos: [[1.0, 2.0], [3.0, 4.0]],
    qpos0: [[0.0, 0.0]],
  }
  let saved = reference_qpos(request)
  assert_eq(saved.reference(), [[0.0, 0.0], [0.0, 0.0]])
  request.qpos[0][0] = 7.0
  let restore = saved.restore()
  restore[0][0] = 8.0
  assert_eq(saved.saved(), [[1.0, 2.0], [3.0, 4.0]])
  assert_eq(saved.restore(), [[1.0, 2.0], [3.0, 4.0]])
  assert_eq(material_solref(100.0, 20.0), [0.1, 1.0])
  assert_eq(material_solref(0.0, 0.0), [0.02, 1.0])
}
