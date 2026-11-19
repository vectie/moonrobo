///|
priv struct ADBody {
  p : Array[@numeric.Value]
  rotation : Array[@numeric.Value]
  v : Array[@numeric.Value]
  w : Array[@numeric.Value]
}

///|
fn ad_cross(
  t : @numeric.Tape,
  a : Array[@numeric.Value],
  b : Array[@numeric.Value],
) -> Array[@numeric.Value] {
  [
    t.sub(t.mul(a[1], b[2]), t.mul(a[2], b[1])),
    t.sub(t.mul(a[2], b[0]), t.mul(a[0], b[2])),
    t.sub(t.mul(a[0], b[1]), t.mul(a[1], b[0])),
  ]
}

///|
fn ad_axis(
  t : @numeric.Tape,
  axis : Array[Double],
  angle : @numeric.Value,
) -> Array[@numeric.Value] {
  let k = skew(axis)
  let c = t.cos(angle)
  let s = t.sin(angle)
  Array::makei(9, i => {
    t.add(
      t.add(
        t.scale(c, if i % 4 == 0 { 1.0 } else { 0.0 }),
        t.scale(t.sub(t.scalar(1.0), c), axis[i / 3] * axis[i % 3]),
      ),
      t.scale(s, k[i]),
    )
  })
}

///|
fn ad_forward(
  t : @numeric.Tape,
  kin : Kinematics,
  s : ADState,
) -> Array[ADBody] {
  let out : Array[ADBody] = []
  for spec in kin.bodies {
    if spec.parent < 0 {
      out.push({ p: s.p, rotation: s.rotation, v: s.v, w: s.w, })
      continue
    }
    let par = out[spec.parent]
    let mut p = ad_add(
      t,
      par.p,
      ad_vec(t, par.rotation, t.vector(spec.offset_p)),
    )
    let off = ad_mat(t, par.rotation, t.vector(spec.offset_rotation))
    let rotation = if spec.joint < 0 {
      off
    } else {
      ad_mat(
        t,
        off,
        ad_axis(t, spec.axis, t.sub(s.q[spec.joint], t.scalar(spec.qref))),
      )
    }
    let pivot = ad_add(t, p, ad_vec(t, off, t.vector(spec.pivot)))
    let jw = if spec.joint < 0 {
      t.vector([0.0, 0.0, 0.0])
    } else {
      p = ad_sub(t, pivot, ad_vec(t, rotation, t.vector(spec.pivot)))
      ad_vec(t, off, t.vector(spec.axis)).map(v => t.mul(v, s.qd[spec.joint]))
    }
    let v = ad_add(
      t,
      ad_add(t, par.v, ad_cross(t, par.w, ad_sub(t, p, par.p))),
      ad_cross(t, jw, ad_sub(t, p, pivot)),
    )
    out.push({ p, rotation, v, w: ad_add(t, par.w, jw), })
  }
  kin.tracked.map(i => out[i])
}

///|
/// Pullback of sum of tracked link-origin squared positions with respect to
/// the 29 ordered joint positions, retaining all parent-chain dependencies.
pub fn Kinematics::position_square_gradient(
  self : Kinematics,
  state : State,
) -> Array[Double] {
  let tape = @numeric.Tape::new()
  let s = lift(tape, state)
  let positions = ad_forward(tape, self, s)
  let terms = positions.map(body => ad_square(tape, body.p))
  let mut loss = tape.scalar(0.0)
  for term in terms {
    loss = tape.add(loss, term)
  }
  tape.backward(loss)
  s.q.map(v => tape.gradient(v))
}

///|
fn ad_observation(
  t : @numeric.Tape,
  s : ADState,
  previous : Array[@numeric.Value],
  xi : Array[Double],
  default_q : Array[Double],
  reference : State,
  mode : ObservationMode,
) -> Array[@numeric.Value] {
  let out = Array::makei(29, i => {
    t.sub(s.q[i], t.scalar(default_q[i] + xi[i + 1]))
  })
  out.append(s.qd)
  let rt = ad_transpose(s.rotation)
  out.append(ad_vec(t, rt, s.w))
  out.append(ad_scale(t, s.rotation[6:9].to_owned(), -1.0))
  out.append(previous)
  if mode != Paper {
    out.append(ad_six(ad_mat(t, rt, t.vector(reference.rotation))))
  }
  if mode == Observable {
    out.append(ad_vec(t, rt, ad_sub(t, t.vector(reference.p), s.p)))
  }
  out
}

///|
fn ad_reward(
  t : @numeric.Tape,
  kin : Kinematics,
  s : ADState,
  reference : State,
  ref_bodies : Array[BodyState],
  action : Array[@numeric.Value],
  previous : Array[@numeric.Value],
  cfg : RewardConfig,
) -> @numeric.Value {
  let bodies = ad_forward(t, kin, s)
  let dr = ad_yaw(
    t,
    ad_mat(t, s.rotation, t.vector(transpose(reference.rotation))),
  )
  let anchor = [s.p[0], s.p[1], t.scalar(reference.p[2])]
  let pos : Array[@numeric.Value] = []
  let ori : Array[@numeric.Value] = []
  let lv : Array[@numeric.Value] = []
  let av : Array[@numeric.Value] = []
  for i, body in bodies {
    let rb = ref_bodies[i]
    let target = ad_add(
      t,
      anchor,
      ad_vec(t, dr, t.vector(vec_sub(rb.p, reference.p))),
    )
    pos.push(ad_square(t, ad_sub(t, target, body.p)))
    ori.push(
      ad_square(
        t,
        ad_log(
          t,
          ad_mat(
            t,
            ad_mat(t, dr, t.vector(rb.rotation)),
            ad_transpose(body.rotation),
          ),
        ),
      ),
    )
    lv.push(ad_square(t, ad_sub(t, t.vector(rb.v), body.v)))
    av.push(ad_square(t, ad_sub(t, t.vector(rb.w), body.w)))
  }
  let errors = [
    t.mean(pos),
    t.mean(ori),
    t.mean(lv),
    t.mean(av),
    ad_square(t, ad_sub(t, t.vector(reference.p), s.p)),
    ad_square(
      t,
      ad_log(
        t,
        ad_mat(t, t.vector(reference.rotation), ad_transpose(s.rotation)),
      ),
    ),
  ]
  let standards = [
    cfg.body_pos_std,
    cfg.body_ori_std,
    cfg.body_linvel_std,
    cfg.body_angvel_std,
    cfg.root_pos_std,
    cfg.root_ori_std,
  ]
  let mut track = t.scalar(0.0)
  for i, e in errors {
    track = t.add(
      track,
      t.scale(
        t.exp(t.scale(e, -1.0 / (standards[i] * standards[i]))),
        if i < 4 {
          1.0
        } else {
          0.5
        },
      ),
    )
  }
  let rate = ad_square(t, ad_sub(t, action, previous))
  let mut limit = t.scalar(0.0)
  for i in 0..<29 {
    let mid = (kin.q_lo[i] + kin.q_hi[i]) / 2.0
    let half = (kin.q_hi[i] - kin.q_lo[i]) * cfg.soft_limit_factor / 2.0
    limit = t.add(
      limit,
      t.add(
        t.clamp(t.sub(s.q[i], t.scalar(mid + half)), 0.0, 1.0e300),
        t.clamp(t.sub(t.scalar(mid - half), s.q[i]), 0.0, 1.0e300),
      ),
    )
  }
  t.scale(
    t.add(
      track,
      t.add(t.scale(rate, cfg.w_action_rate), t.scale(limit, cfg.w_joint_limit)),
    ),
    control_dt,
  )
}

///|
fn ad_failure(
  t : @numeric.Tape,
  s : ADState,
  reference : State,
  cfg : RewardConfig,
) -> @numeric.Value {
  let height = t.scale(
    t.sub(
      t.abs(t.sub(t.scalar(reference.p[2]), s.p[2])),
      t.scalar(cfg.term_height),
    ),
    50.0,
  )
  let tilt = t.scale(
    t.sub(
      t.abs(t.sub(t.scalar(reference.rotation[8]), s.rotation[8])),
      t.scalar(cfg.term_tilt),
    ),
    25.0,
  )
  let one = t.scalar(1.0)
  t.sub(one, t.mul(t.sub(one, t.sigmoid(height)), t.sub(one, t.sigmoid(tilt))))
}

///|
fn ad_critic_features(
  t : @numeric.Tape,
  kin : Kinematics,
  s : ADState,
  reference : State,
  ref_bodies : Array[BodyState],
  xi_n : Array[Double],
  goal : Array[Double],
) -> Array[@numeric.Value] {
  let out = ad_invariant(t, s)
  out.append(ad_sub(t, t.vector(reference.q), s.q))
  let ht = ad_transpose(ad_yaw(t, s.rotation))
  let dr = ad_yaw(
    t,
    ad_mat(t, s.rotation, t.vector(transpose(reference.rotation))),
  )
  let anchor = [s.p[0], s.p[1], t.scalar(reference.p[2])]
  for i, b in ad_forward(t, kin, s) {
    let target = ad_add(
      t,
      anchor,
      ad_vec(t, dr, t.vector(vec_sub(ref_bodies[i].p, reference.p))),
    )
    out.append(ad_vec(t, ht, ad_sub(t, target, b.p)))
  }
  out.append(ad_vec(t, ht, ad_sub(t, t.vector(reference.p), s.p)))
  out.append(
    ad_six(ad_mat(t, ad_transpose(s.rotation), t.vector(reference.rotation))),
  )
  out.append(t.vector(xi_n))
  out.append(t.vector(goal))
  out
}
