// Reverse-mode counterparts preserve gradients through the entire imagined trajectory.

///|
pub(all) struct ADState {
  p : Array[@numeric.Value]
  rotation : Array[@numeric.Value]
  v : Array[@numeric.Value]
  w : Array[@numeric.Value]
  q : Array[@numeric.Value]
  qd : Array[@numeric.Value]
}

///|
fn lift(t : @numeric.Tape, s : State) -> ADState {
  {
    p: t.vector(s.p),
    rotation: t.vector(s.rotation),
    v: t.vector(s.v),
    w: t.vector(s.w),
    q: t.vector(s.q),
    qd: t.vector(s.qd),
  }
}

///|
fn ad_add(
  t : @numeric.Tape,
  a : Array[@numeric.Value],
  b : Array[@numeric.Value],
) -> Array[@numeric.Value] {
  Array::makei(a.length(), i => t.add(a[i], b[i]))
}

///|
fn ad_sub(
  t : @numeric.Tape,
  a : Array[@numeric.Value],
  b : Array[@numeric.Value],
) -> Array[@numeric.Value] {
  Array::makei(a.length(), i => t.sub(a[i], b[i]))
}

///|
fn ad_scale(
  t : @numeric.Tape,
  a : Array[@numeric.Value],
  s : Double,
) -> Array[@numeric.Value] {
  a.map(v => t.scale(v, s))
}

///|
fn ad_square(t : @numeric.Tape, a : Array[@numeric.Value]) -> @numeric.Value {
  let mut sum = t.scalar(0.0)
  for v in a {
    sum = t.add(sum, t.mul(v, v))
  }
  sum
}

///|
fn ad_transpose(a : Array[@numeric.Value]) -> Array[@numeric.Value] {
  Array::makei(9, i => a[i % 3 * 3 + i / 3])
}

///|
fn ad_mat(
  t : @numeric.Tape,
  a : Array[@numeric.Value],
  b : Array[@numeric.Value],
) -> Array[@numeric.Value] {
  Array::makei(9, i => {
    let r = i / 3
    let c = i % 3
    t.add(
      t.add(t.mul(a[r * 3], b[c]), t.mul(a[r * 3 + 1], b[c + 3])),
      t.mul(a[r * 3 + 2], b[c + 6]),
    )
  })
}

///|
fn ad_vec(
  t : @numeric.Tape,
  a : Array[@numeric.Value],
  b : Array[@numeric.Value],
) -> Array[@numeric.Value] {
  Array::makei(3, r => {
    t.add(
      t.add(t.mul(a[r * 3], b[0]), t.mul(a[r * 3 + 1], b[1])),
      t.mul(a[r * 3 + 2], b[2]),
    )
  })
}

///|
fn ad_six(a : Array[@numeric.Value]) -> Array[@numeric.Value] {
  [a[0], a[1], a[3], a[4], a[6], a[7]]
}

///|
fn ad_yaw(
  t : @numeric.Tape,
  r : Array[@numeric.Value],
) -> Array[@numeric.Value] {
  let vertical = r[0].value * r[0].value + r[3].value * r[3].value < 1.0e-12
  let x = if vertical { r[4] } else { r[0] }
  let y = if vertical { t.scale(r[1], -1.0) } else { r[3] }
  let n = t.clamp(t.sqrt(t.add(t.mul(x, x), t.mul(y, y))), 1.0e-12, 1.0e300)
  let c = t.div(x, n)
  let s = t.div(y, n)
  let z = t.scalar(0.0)
  [c, t.scale(s, -1.0), z, s, c, z, z, z, t.scalar(1.0)]
}

///|
fn ad_exp(
  t : @numeric.Tape,
  v : Array[@numeric.Value],
) -> Array[@numeric.Value] {
  let theta2 = ad_square(t, v)
  let theta = t.sqrt(t.add(theta2, t.scalar(1.0e-12)))
  let a = if theta2.value < 1.0e-8 {
    t.sub(t.scalar(1.0), t.scale(theta2, 1.0 / 6.0))
  } else {
    t.div(t.sin(theta), theta)
  }
  let b = if theta2.value < 1.0e-8 {
    t.sub(t.scalar(0.5), t.scale(theta2, 1.0 / 24.0))
  } else {
    t.div(t.sub(t.scalar(1.0), t.cos(theta)), t.add(theta2, t.scalar(1.0e-12)))
  }
  let z = t.scalar(0.0)
  let k = [
    z,
    t.scale(v[2], -1.0),
    v[1],
    v[2],
    z,
    t.scale(v[0], -1.0),
    t.scale(v[1], -1.0),
    v[0],
    z,
  ]
  let k2 = ad_mat(t, k, k)
  Array::makei(9, i => {
    t.add(
      t.scalar(if i % 4 == 0 { 1.0 } else { 0.0 }),
      t.add(t.mul(a, k[i]), t.mul(b, k2[i])),
    )
  })
}

///|
fn ad_quaternion(
  t : @numeric.Tape,
  m : Array[@numeric.Value],
) -> Array[@numeric.Value] {
  let one = t.scalar(1.0)
  let cands = [
    t.add(t.add(t.add(one, m[0]), m[4]), m[8]),
    t.sub(t.sub(t.add(one, m[0]), m[4]), m[8]),
    t.sub(t.add(t.sub(one, m[0]), m[4]), m[8]),
    t.add(t.sub(t.sub(one, m[0]), m[4]), m[8]),
  ].map(v => t.scale(t.sqrt(t.clamp(v, 1.0e-10, 1.0e300)), 0.5))
  let mut best = 0
  for i in 1..<4 {
    if cands[i].value > cands[best].value {
      best = i
    }
  }
  let d = t.scale(cands[best], 4.0)
  let mut q = match best {
    0 =>
      [
        cands[0],
        t.div(t.sub(m[7], m[5]), d),
        t.div(t.sub(m[2], m[6]), d),
        t.div(t.sub(m[3], m[1]), d),
      ]
    1 =>
      [
        t.div(t.sub(m[7], m[5]), d),
        cands[1],
        t.div(t.add(m[1], m[3]), d),
        t.div(t.add(m[2], m[6]), d),
      ]
    2 =>
      [
        t.div(t.sub(m[2], m[6]), d),
        t.div(t.add(m[1], m[3]), d),
        cands[2],
        t.div(t.add(m[5], m[7]), d),
      ]
    _ =>
      [
        t.div(t.sub(m[3], m[1]), d),
        t.div(t.add(m[2], m[6]), d),
        t.div(t.add(m[5], m[7]), d),
        cands[3],
      ]
  }
  let norm = t.sqrt(ad_square(t, q))
  q = q.map(v => t.div(v, norm))
  if q[0].value < 0.0 {
    q = ad_scale(t, q, -1.0)
  }
  q
}

///|
fn ad_log(
  t : @numeric.Tape,
  m : Array[@numeric.Value],
) -> Array[@numeric.Value] {
  let q = ad_quaternion(t, m)
  let v = q[1:4].to_owned()
  // At zero PyTorch's norm has derivative zero; avoid constructing sqrt'(0).
  let norm2 = ad_square(t, v)
  let scale = if norm2.value < 1.0e-12 {
    t.div(t.scalar(2.0), t.clamp(q[0], 1.0e-6, 1.0e300))
  } else {
    let n = t.sqrt(norm2)
    t.div(t.scale(t.atan2(n, q[0]), 2.0), t.add(n, t.scalar(1.0e-12)))
  }
  v.map(x => t.mul(x, scale))
}

///|
fn ad_invariant(t : @numeric.Tape, s : ADState) -> Array[@numeric.Value] {
  let out = [s.p[2]]
  out.append(ad_six(ad_mat(t, ad_transpose(ad_yaw(t, s.rotation)), s.rotation)))
  out.append(ad_vec(t, ad_transpose(s.rotation), s.v))
  out.append(ad_vec(t, ad_transpose(s.rotation), s.w))
  out.append(s.q)
  out.append(s.qd)
  out
}

///|
fn WorldModel::step_ad(
  self : WorldModel,
  t : @numeric.Tape,
  params : Array[@numeric.Value],
  s : ADState,
  action : Array[@numeric.Value],
  xi_n : Array[Double],
) -> ADState {
  let input = ad_invariant(t, s)
  input.append(action)
  input.append(t.vector(xi_n))
  let y = self.net.forward(t, params, self.input_norm.apply_ad(t, input))
  let std = self.output_norm.std()
  let d = Array::makei(70, i => {
    t.add(t.scale(y[i], std[i]), t.scalar(self.output_norm.mean[i]))
  })
  {
    p: ad_add(t, s.p, ad_vec(t, ad_yaw(t, s.rotation), d[0:3].to_owned())),
    rotation: ad_mat(t, s.rotation, ad_exp(t, d[3:6].to_owned())),
    v: ad_add(t, s.v, ad_vec(t, s.rotation, d[6:9].to_owned())),
    w: ad_add(t, s.w, ad_vec(t, s.rotation, d[9:12].to_owned())),
    q: ad_add(t, s.q, d[12:41].to_owned()),
    qd: ad_add(t, s.qd, d[41:70].to_owned()),
  }
}

///|
fn ad_state_error(
  t : @numeric.Tape,
  predicted : ADState,
  target : State,
) -> Array[@numeric.Value] {
  let rt = t.vector(transpose(target.rotation))
  let out = ad_vec(
    t,
    t.vector(transpose(yaw_mat(target.rotation))),
    ad_sub(t, predicted.p, t.vector(target.p)),
  )
  out.append(ad_log(t, ad_mat(t, rt, predicted.rotation)))
  out.append(ad_vec(t, rt, ad_sub(t, predicted.v, t.vector(target.v))))
  out.append(ad_vec(t, rt, ad_sub(t, predicted.w, t.vector(target.w))))
  out.append(ad_sub(t, predicted.q, t.vector(target.q)))
  out.append(ad_sub(t, predicted.qd, t.vector(target.qd)))
  out
}

///|
pub(all) struct WorldFitMetrics {
  loss : Double
  last_error : Double
  updates : Int32
} derive(Debug, ToJson)

///|
pub fn WorldModel::fit(
  self : WorldModel,
  replay : ReplayBuffer,
  optimizer : @numeric.Adam,
  rng : @numeric.Rng,
  batches~ : Int32 = 10,
  batch~ : Int32 = 2048,
  window~ : Int32 = 8,
  fixed_windows? : Array[ReplayWindow],
  gradient_trace? : (String, Int32, Array[Double], Array[Double], Double) -> Unit,
) -> WorldFitMetrics raise {
  guard batches > 0 else { fail("world fitting needs positive update count") }
  let std = self.output_norm.std()
  let floor = Array::makei(70, i => {
    if i < 3 {
      0.003
    } else if i < 6 {
      0.005
    } else if i < 9 {
      0.02
    } else if i < 12 {
      0.05
    } else if i < 41 {
      0.003
    } else {
      0.05
    }
  })
  let mut total_loss = 0.0
  let mut total_last = 0.0
  for update in 0..<batches {
    let windows = match fixed_windows {
      Some(windows) => windows
      None => replay.sample_windows(batch, window, n => rng.index(n))
    }
    guard windows.length() == batch &&
      windows.all(w => {
        w.transitions.length() == window && w.mask.length() == window
      }) else {
      fail("fixed world-model windows differ from configured batch/horizon")
    }
    let t = @numeric.Tape::new()
    let parameters = self.net.bind(t)
    let mut loss = t.scalar(0.0)
    let mut last_error = 0.0
    let mut last_count = 0.0
    for w in windows {
      let mut state = lift(t, unflatten_state(w.transitions[0].s))
      for j, tr in w.transitions {
        state = self.step_ad(
          t,
          parameters,
          state,
          t.vector(tr.a),
          normalize_xi(tr.xi),
        )
        let errors = ad_state_error(t, state, unflatten_state(tr.s1))
        let error = t.mean(
          Array::makei(70, i => {
            let e = t.scale(errors[i], 1.0 / std[i].max(floor[i]))
            t.mul(e, e)
          }),
        )
        loss = t.add(loss, t.scale(error, w.mask[j] / batch.to_double()))
        if j == window - 1 {
          last_error += error.value * w.mask[j]
          last_count += w.mask[j]
        }
      }
    }
    t.backward(loss)
    ignore(
      optimizer.step(self.net.parameters, t, parameters, max_norm=1.0, gradient_trace=(
        raw,
        clipped,
        norm,
      ) => {
        if gradient_trace is Some(capture) {
          capture("world", update, raw, clipped, norm)
        }
      }),
    )
    total_loss += loss.value / window.to_double()
    total_last += last_error / last_count.max(1.0)
  }
  {
    loss: total_loss / batches.to_double(),
    last_error: total_last / batches.to_double(),
    updates: batches,
  }
}
