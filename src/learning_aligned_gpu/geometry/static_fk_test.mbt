///|
test "compact rotations and static FK preserves mixed chains outputs and gradients" {
  guard @env.get_env_var("MOONROBO_TENSOR_LIBRARY") is Some(path) else {
    println("SKIP compact rotations and static FK integration")
    return
  }
  let backend = @tensor.Backend::open(path)
  let (kin, states, _) = fixtures()
  for i in 1..<kin.bodies.length() {
    let body = kin.bodies[i]
    // Includes zero and nonzero pivots, qrefs, fixed links and arbitrary axes.
    kin.bodies[i] = {
      ..body,
      pivot: if i % 2 == 0 {
        [0.0, 0.0, 0.0]
      } else {
        body.pivot
      },
      offset_rotation: if i % 3 == 0 {
        [1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0]
      } else {
        body.offset_rotation
      },
      qref: if i % 3 == 0 {
        0.0
      } else {
        body.qref
      },
      axis: if i % 4 == 0 {
        [0.6, 0.8, 0.0]
      } else {
        body.axis
      },
    }
  }
  let values = []
  for state in states {
    values.append(@aligned.flatten_state(state))
  }
  for dtype in [@tensor.Float32, @tensor.Float64] {
    let context = @geometry.Context::new(backend, kin, -1, dtype~)
    let a = backend.from_values(
      [3, 71],
      values,
      cuda_device=-1,
      requires_grad=true,
      dtype~,
    )
    let b = backend.from_values(
      [3, 71],
      values,
      cuda_device=-1,
      requires_grad=true,
      dtype~,
    )
    let left = context.forward(
      @geometry.State::from_flat71(backend, a),
      all_bodies=true,
    )
    let right = context
      .with_compact_axis_rotation(true)
      .with_static_fk_pruning(true)
      .forward(@geometry.State::from_flat71(backend, b), all_bodies=true)
    let la = []
    let lb = []
    let check = (u : Array[Double], v : Array[Double]) => {
      assert_eq(u.length(), v.length())
      for i in 0..<u.length() {
        let bound = if dtype == @tensor.Float64 {
          1.0e-10
        } else {
          2.0e-6 + 2.0e-4 * v[i].abs()
        }
        assert_true((u[i] - v[i]).abs() <= bound)
      }
    }
    for i in 0..<left.length() {
      for
        (u, v) in [
          (left[i].p, right[i].p),
          (left[i].rotation, right[i].rotation),
          (left[i].v, right[i].v),
          (left[i].w, right[i].w),
        ] {
        check(u.values(), v.values())
        la.push(u.square().sum())
        lb.push(v.square().sum())
      }
    }
    backend.stack(la).sum().backward()
    backend.stack(lb).sum().backward()
    check(a.gradient_values(), b.gradient_values())
  }
}
