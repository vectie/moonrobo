///|
fn body_orientation_device() -> Int32 raise {
  match @env.get_env_var("MOONROBO_OPTIMIZATION_TEST_DEVICE") {
    None | Some("cpu") => -1
    Some("cuda:0") => 0
    _ => fail("body orientation test device must be cpu or cuda:0")
  }
}

///|
fn body_orientation_near(
  actual : Array[Double],
  expected : Array[Double],
  dtype : @tensor.DType,
  label : String,
) -> Unit raise {
  assert_eq(actual.length(), expected.length())
  for i in 0..<actual.length() {
    // Existing Float64 geometry and Float32 execution-parity tolerances.
    let limit = if dtype == @tensor.Float64 {
      1.0e-8
    } else {
      2.0e-6 + 2.0e-4 * actual[i].abs().max(expected[i].abs())
    }
    guard !actual[i].is_nan() &&
      !actual[i].is_inf() &&
      !expected[i].is_nan() &&
      !expected[i].is_inf() &&
      (actual[i] - expected[i]).abs() <= limit else {
      fail(
        "body orientation \{label}[\{i}]: \{actual[i]} vs \{expected[i]}, tolerance \{limit}",
      )
    }
  }
}

///|
fn body_orientation_terms(
  terms : @geometry.RewardTerms,
) -> Array[@tensor.Tensor] {
  [
    terms.reward,
    terms.track,
    terms.body_pos,
    terms.body_ori,
    terms.body_linvel,
    terms.body_angvel,
    terms.root_pos,
    terms.root_ori,
    terms.action_rate,
    terms.joint_limit,
  ]
}

///|
test "batched body quaternion log preserves rewards both state gradients and four Adam updates" {
  let device = body_orientation_device()
  guard @env.get_env_var("MOONROBO_TENSOR_LIBRARY") is Some(path) else {
    guard device < 0 else {
      fail("explicit CUDA body-orientation gate needs plugin")
    }
    println("SKIP body orientation gate: set MOONROBO_TENSOR_LIBRARY")
    return
  }
  let backend = @tensor.Backend::open(path)
  if device >= 0 {
    guard backend.cuda_device_count() > 0 &&
      backend.cuda_free_bytes(device) > 17179869184L else {
      fail("body orientation gate requires 16 GiB CUDA free reserve")
    }
  }
  let (kin0, states, _) = fixtures()
  let pi = 3.141592653589793
  let rotations = [
    [0.0, 0.0, 0.0],
    [0.00000001, 0.0, 0.0],
    [0.3, -0.2, 0.1],
    [pi - 0.0001, 0.0, 0.0],
    [pi, 0.0, 0.0],
    [0.0, pi, 0.0],
    [0.0, 0.0, pi],
    [1.5707963267948966, 0.0, 0.0],
  ]
  for dtype in [@tensor.Float32, @tensor.Float64] {
    for count in [1, 14, 64] {
      let kin = {
        ..kin0,
        tracked: Array::makei(count, i => {
          kin0.tracked[i % kin0.tracked.length()]
        }),
      }
      let baseline = @geometry.Context::new(backend, kin, device, dtype~)
      let candidate = baseline.with_body_orientation_batched(true)
      let batch = if count == 14 { 8 } else { 1 }
      let state_rows = Array::makei(batch, i => {
        @aligned.flatten_state({
          ..states[0],
          rotation: @aligned.so3_exp(rotations[i]),
        })
      })
      let reference_rows = Array::makei(batch, _ => {
        @aligned.flatten_state(states[0])
      })
      let actions = Array::makei(batch, i => {
        Array::makei(29, j => (j - 14 + i).to_double() * 0.003)
      })
      let previous = Array::makei(batch, _ => Array::make(29, 0.01))
      let make = (rows : Array[Array[Double]]) => {
        let flat : Array[Double] = []
        for row in rows {
          flat.append(row)
        }
        backend.from_values(
          [batch, rows[0].length()],
          flat,
          cuda_device=device,
          requires_grad=true,
          dtype~,
        )
      }
      let inputs = [state_rows, reference_rows, actions, previous]
      let a = inputs.map(make)
      let b = inputs.map(make)
      let oa = backend.adam(a, learning_rate=0.0001)
      let ob = backend.adam(b, learning_rate=0.0001)
      let iterations = if count == 14 { 4 } else { 1 }
      for iteration in 0..<iterations {
        oa.zero_grad()
        ob.zero_grad()
        let evaluate = (
          context : @geometry.Context,
          values : Array[@tensor.Tensor],
        ) => {
          context.reward_terms(
            @geometry.State::from_flat71(backend, values[0]),
            @geometry.State::from_flat71(backend, values[1]),
            values[2],
            values[3],
          )
        }
        let ta = body_orientation_terms(evaluate(baseline, a))
        let tb = body_orientation_terms(evaluate(candidate, b))
        let label = "dtype \{Repr(dtype)} bodies \{count} update \{iteration}"
        for term in 0..<ta.length() {
          body_orientation_near(
            tb[term].values(),
            ta[term].values(),
            dtype,
            "\{label} term \{term}",
          )
        }
        // Every reward term participates so both state/reference kinematics,
        // root alignment, velocities, joint limits and both actions are checked.
        backend.stack(ta, axis=1).mean().backward()
        backend.stack(tb, axis=1).mean().backward()
        for parameter in 0..<a.length() {
          body_orientation_near(
            b[parameter].gradient_values(),
            a[parameter].gradient_values(),
            dtype,
            "\{label} gradient \{parameter}",
          )
        }
        oa.step(clip_norm=1.0, clip_value=0.5)
        ob.step(clip_norm=1.0, clip_value=0.5)
        assert_eq(oa.audit_metadata(), ob.audit_metadata())
        for parameter in 0..<a.length() {
          for kind in 0..<3 {
            body_orientation_near(
              ob.audit_tensor(parameter, kind~).values(),
              oa.audit_tensor(parameter, kind~).values(),
              dtype,
              "\{label} Adam \{parameter}/\{kind}",
            )
          }
        }
      }
      // Candidate and baseline remain selectable independently of FK reuse.
      let s = @geometry.State::from_flat71(backend, b[0])
      let r = @geometry.State::from_flat71(backend, b[1])
      body_orientation_near(
        candidate.tracking_geometry(s, r).reward(b[2], b[3]).values(),
        candidate.reward(s, r, b[2], b[3]).values(),
        dtype,
        "reuse composability",
      )
      body_orientation_near(
        candidate
        .with_body_orientation_batched(false)
        .reward(s, r, b[2], b[3])
        .values(),
        baseline.reward(s, r, b[2], b[3]).values(),
        dtype,
        "baseline remains selectable",
      )
    }
  }
  let oversize = { ..kin0, tracked: Array::make(65, kin0.tracked[0]), }
  try
    @geometry.Context::new(
      backend,
      oversize,
      device,
      body_orientation_batched=true,
    )
  catch {
    Failure(message) =>
      assert_true(message.contains("admitted 64 tracked-body bound"))
    error => raise error
  } noraise {
    _ => fail("oversized batched body constructor accepted")
  }
  let legacy = @geometry.Context::new(backend, oversize, device)
  try legacy.with_body_orientation_batched(true) catch {
    Failure(message) =>
      assert_true(message.contains("admitted 64 tracked-body bound"))
    error => raise error
  } noraise {
    _ => fail("oversized batched body option accepted")
  }
}
