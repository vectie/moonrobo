///|
/// Pending source regressions only. No algorithm, test or numerical example
/// is executed while the user's deferred-machine policy remains in force.
fn close(actual : Double, expected : Double) -> Unit raise {
  assert_true((actual - expected).abs() <= 1.0e-10)
}

///|
fn rejected(work : () -> Unit raise) -> Bool {
  try {
    work()
    false
  } catch {
    _ => true
  }
}

///|
fn world() -> Body {
  {
    parent: 0,
    pose: @geometry.transform3(@geometry.identity_basis3(), zero()),
    mass: 0.0,
    com: zero(),
    inertia: zero_basis(),
    joint: None,
  }
}

///|
fn articulated(
  kind : String,
  axis : @geometry.Vec3,
  com : @geometry.Vec3,
) -> Body {
  {
    parent: 0,
    pose: @geometry.transform3(@geometry.identity_basis3(), zero()),
    mass: 2.0,
    com,
    inertia: { ..zero_basis(), xx: 2.0, yy: 4.0, zz: 6.0, },
    joint: Some({ kind, qpos_adr: 0, dof_adr: 0, axis, anchor: zero(), }),
  }
}

///|
test "hinge mass is actual COM Jacobian inertia plus physical armature" {
  let model : RigidModel = {
    bodies: [
      world(),
      articulated(
        "hinge",
        @geometry.vec3(0.0, 0.0, 1.0),
        @geometry.vec3(1.0, 0.0, 0.0),
      ),
    ],
    armature: [0.25],
  }
  let result = rigid_reference(model, [0.0])
  close(result.mass_matrix[0][0], 8.25)
  close(result.inverse_mass_matrix[0][0], 1.0 / 8.25)
  close(result.dof_invweight0[0], 1.0 / 8.25)
  close(result.body_invweight0[1].translation, 1.0 / (3.0 * 8.25))
  close(result.body_invweight0[1].rotation, 1.0 / (3.0 * 8.25))
  close(result.mean_inertia, 8.25)
  close(result.subtree_mass[0], 2.0)
}

///|
test "slide body inverseweight uses actual MuJoCo zero-component fallback" {
  let model : RigidModel = {
    bodies: [
      world(),
      articulated("slide", @geometry.vec3(1.0, 0.0, 0.0), zero()),
    ],
    armature: [0.5],
  }
  let result = rigid_reference(model, [0.0])
  close(result.mass_matrix[0][0], 2.5)
  close(result.body_invweight0[1].translation, 1.0 / 7.5)
  close(result.body_invweight0[1].rotation, 1.0 / 7.5)
}

///|
test "free-root mass preserves COM coupling and world-linear body-angular convention" {
  let model : RigidModel = {
    bodies: [
      world(),
      articulated("free", zero(), @geometry.vec3(1.0, 0.0, 0.0)),
    ],
    armature: [0.0, 0.0, 0.0, 0.0, 0.0, 0.0],
  }
  let result = rigid_reference(model, [1.0, 2.0, 3.0, 1.0, 0.0, 0.0, 0.0])
  close(result.body_com[1].x, 2.0)
  close(result.mass_matrix[1][5], 2.0)
  close(result.mass_matrix[2][4], -2.0)
  close(result.mass_matrix[4][4], 6.0)
  close(result.mass_matrix[5][5], 8.0)
  close(result.dof_invweight0[0], result.dof_invweight0[2])
  close(result.dof_invweight0[3], result.dof_invweight0[5])
  for i in 0..<6 {
    for j in 0..<6 {
      let mut value = 0.0
      for k in 0..<6 {
        value += result.mass_matrix[i][k] * result.inverse_mass_matrix[k][j]
      }
      close(value, if i == j { 1.0 } else { 0.0 })
    }
  }
}

///|
test "nonzero joint FK delta rotates around actual anchor before COM transform" {
  let model : RigidModel = {
    bodies: [
      world(),
      articulated(
        "hinge",
        @geometry.vec3(0.0, 0.0, 1.0),
        @geometry.vec3(1.0, 0.0, 0.0),
      ),
    ],
    armature: [0.0],
  }
  let state = kinematics(model, validate_model(model), [1.5707963267948966], [
    0.0,
  ])
  close(state.com[1].x, 0.0)
  close(state.com[1].y, 1.0)
}

///|
test "composite inertia shifts both own and descendant inertia to subtree COM" {
  let left : Body = {
    parent: 0,
    pose: @geometry.transform3(
      @geometry.identity_basis3(),
      @geometry.vec3(-1.0, 0.0, 0.0),
    ),
    mass: 1.0,
    com: zero(),
    inertia: @geometry.identity_basis3(),
    joint: None,
  }
  let right = {
    ..left,
    pose: @geometry.transform3(
      @geometry.identity_basis3(),
      @geometry.vec3(1.0, 0.0, 0.0),
    ),
  }
  let result = rigid_reference(
    { bodies: [world(), left, right], armature: [], },
    [],
  )
  close(result.subtree_com[0].x, 0.0)
  close(result.subtree_inertia_about_com[0].xx, 2.0)
  close(result.subtree_inertia_about_com[0].yy, 4.0)
  close(result.subtree_inertia_about_com[0].zz, 4.0)
  assert_eq(result.mass_matrix, [])
  close(result.mean_inertia, 1.0)
}

///|
test "unsupported coordinate layouts and singular physical mass fail closed" {
  let body = articulated("hinge", @geometry.vec3(0.0, 0.0, 1.0), zero())
  assert_true(
    rejected(fn() raise {
      ignore(
        rigid_reference(
          {
            bodies: [world(), { ..body, mass: 0.0, inertia: zero_basis(), }],
            armature: [0.0],
          },
          [0.0],
        ),
      )
    }),
  )
  assert_true(
    rejected(fn() raise {
      ignore(
        rigid_reference(
          {
            bodies: [
              world(),
              {
                ..body,
                joint: Some({
                  kind: "ball",
                  qpos_adr: 0,
                  dof_adr: 0,
                  anchor: zero(),
                  axis: zero(),
                }),
              },
            ],
            armature: [0.0],
          },
          [0.0],
        ),
      )
    }),
  )
  assert_true(
    rejected(fn() raise {
      ignore(
        rigid_reference(
          { bodies: [world(), { ..body, parent: 1, }], armature: [0.0], },
          [0.0],
        ),
      )
    }),
  )
}
