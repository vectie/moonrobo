///|
pub let state_dim : Int32 = 71

///|
pub let xi_dim : Int32 = 33

///|
pub let control_dt : Double = 0.02

///|
pub(all) enum ObservationMode {
  Paper
  Smc
  Observable
} derive(Debug, Eq)

///|
pub fn ObservationMode::dim(self : ObservationMode) -> Int32 {
  match self {
    Paper => 93
    Smc => 99
    Observable => 102
  }
}

///|
pub fn invariant_features(s : State) -> Array[Double] {
  let out = [s.p[2]]
  out.append(mat_to_6d(mat_mul(transpose(yaw_mat(s.rotation)), s.rotation)))
  out.append(mat_vec(transpose(s.rotation), s.v))
  out.append(mat_vec(transpose(s.rotation), s.w))
  out.append(s.q)
  out.append(s.qd)
  out
}

///|
pub fn normalize_xi(x : Array[Double]) -> Array[Double] {
  Array::makei(33, i => {
    if i == 0 {
      (x[i] - 0.75) / 0.45
    } else if i < 30 {
      x[i] / 0.01
    } else {
      x[i] / 0.05
    }
  })
}

///|
pub fn observation(
  s : State,
  previous : Array[Double],
  xi : Array[Double],
  default_q : Array[Double],
  reference : State,
  mode : ObservationMode,
) -> Array[Double] {
  let out = Array::makei(29, i => s.q[i] - default_q[i] - xi[i + 1])
  out.append(s.qd)
  let rt = transpose(s.rotation)
  out.append(mat_vec(rt, s.w))
  out.append([-s.rotation[6], -s.rotation[7], -s.rotation[8]])
  out.append(previous)
  if mode != Paper {
    out.append(mat_to_6d(mat_mul(rt, reference.rotation)))
  }
  if mode == Observable {
    out.append(mat_vec(rt, vec_sub(reference.p, s.p)))
  }
  out
}

///|
pub fn observation_noise(mode : ObservationMode) -> Array[Double] {
  Array::makei(mode.dim(), i => {
    if i < 29 {
      0.01
    } else if i < 58 {
      0.5
    } else if i < 61 {
      0.2
    } else if i < 64 {
      0.05
    } else if i < 93 {
      0.0
    } else if i < 99 {
      0.05
    } else {
      0.0
    }
  })
}

///|
pub fn observation_scale(mode : ObservationMode) -> Array[Double] {
  Array::makei(mode.dim(), i => {
    if i >= 29 && i < 58 {
      0.1
    } else if i >= 58 && i < 61 {
      0.25
    } else {
      1.0
    }
  })
}

///|
pub(all) struct RewardConfig {
  body_pos_std : Double
  body_ori_std : Double
  body_linvel_std : Double
  body_angvel_std : Double
  root_pos_std : Double
  root_ori_std : Double
  w_action_rate : Double
  w_joint_limit : Double
  soft_limit_factor : Double
  term_height : Double
  term_tilt : Double
} derive(Debug)

///|
pub fn RewardConfig::default() -> RewardConfig {
  {
    body_pos_std: 0.3,
    body_ori_std: 0.4,
    body_linvel_std: 1.0,
    body_angvel_std: 3.14,
    root_pos_std: 0.3,
    root_ori_std: 0.4,
    w_action_rate: -0.1,
    w_joint_limit: -2.0,
    soft_limit_factor: 0.9,
    term_height: 0.25,
    term_tilt: 0.8,
  }
}

///|
fn square_norm(a : Array[Double]) -> Double {
  a.fold(init=0.0, (s, x) => s + x * x)
}

///|
pub(all) struct RewardTerms {
  reward : Double
  track : Double
  body_pos : Double
  body_ori : Double
  body_linvel : Double
  body_angvel : Double
  root_pos : Double
  root_ori : Double
  action_rate : Double
  joint_limit : Double
} derive(Debug)

///|
pub fn reward(
  kin : Kinematics,
  s : State,
  reference : State,
  reference_bodies : Array[BodyState],
  action : Array[Double],
  previous : Array[Double],
  cfg~ : RewardConfig = RewardConfig::default(),
  atlas~ : Bool = false,
) -> RewardTerms {
  let bodies = kin.forward(s)
  let dr = yaw_mat(mat_mul(s.rotation, transpose(reference.rotation)), atlas~)
  let anchor = [s.p[0], s.p[1], reference.p[2]]
  let mut ep = 0.0
  let mut er = 0.0
  let mut ev = 0.0
  let mut ew = 0.0
  for i, body in bodies {
    let ref_body = reference_bodies[i]
    let target = vec_add(anchor, mat_vec(dr, vec_sub(ref_body.p, reference.p)))
    ep += square_norm(vec_sub(target, body.p))
    er += rot_angle_sq(mat_mul(dr, ref_body.rotation), body.rotation)
    ev += square_norm(vec_sub(ref_body.v, body.v))
    ew += square_norm(vec_sub(ref_body.w, body.w))
  }
  let n = bodies.length().to_double()
  ep /= n
  er /= n
  ev /= n
  ew /= n
  let root_pos = square_norm(vec_sub(reference.p, s.p))
  let root_ori = rot_angle_sq(reference.rotation, s.rotation)
  let track = (-ep / (cfg.body_pos_std * cfg.body_pos_std)).exp() +
    (-er / (cfg.body_ori_std * cfg.body_ori_std)).exp() +
    (-ev / (cfg.body_linvel_std * cfg.body_linvel_std)).exp() +
    (-ew / (cfg.body_angvel_std * cfg.body_angvel_std)).exp() +
    0.5 * (-root_pos / (cfg.root_pos_std * cfg.root_pos_std)).exp() +
    0.5 * (-root_ori / (cfg.root_ori_std * cfg.root_ori_std)).exp()
  let rate = square_norm(vec_sub(action, previous))
  let mut limit = 0.0
  for i in 0..<29 {
    let mid = (kin.q_lo[i] + kin.q_hi[i]) / 2.0
    let half = (kin.q_hi[i] - kin.q_lo[i]) * cfg.soft_limit_factor / 2.0
    limit += (s.q[i] - mid - half).max(0.0) + (mid - half - s.q[i]).max(0.0)
  }
  {
    reward: (track + cfg.w_action_rate * rate + cfg.w_joint_limit * limit) *
    control_dt,
    track: track * control_dt,
    body_pos: ep,
    body_ori: er,
    body_linvel: ev,
    body_angvel: ew,
    root_pos,
    root_ori,
    action_rate: rate,
    joint_limit: limit,
  }
}

///|
pub fn termination(
  s : State,
  reference : State,
  cfg~ : RewardConfig = RewardConfig::default(),
) -> Bool {
  (reference.p[2] - s.p[2]).abs() > cfg.term_height ||
  (reference.rotation[8] - s.rotation[8]).abs() > cfg.term_tilt
}

///|
pub fn soft_termination(
  s : State,
  reference : State,
  cfg~ : RewardConfig = RewardConfig::default(),
  tz~ : Double = 0.02,
  tt~ : Double = 0.04,
) -> Double {
  let a = ((reference.p[2] - s.p[2]).abs() - cfg.term_height) / tz
  let b = ((reference.rotation[8] - s.rotation[8]).abs() - cfg.term_tilt) / tt
  1.0 - (1.0 - 1.0 / (1.0 + (-a).exp())) * (1.0 - 1.0 / (1.0 + (-b).exp()))
}

///|
pub fn critic_features(
  kin : Kinematics,
  s : State,
  reference : State,
  reference_bodies : Array[BodyState],
  xi : Array[Double],
) -> Array[Double] {
  let out = invariant_features(s)
  out.append(vec_sub(reference.q, s.q))
  let ht = transpose(yaw_mat(s.rotation))
  let dr = yaw_mat(mat_mul(s.rotation, transpose(reference.rotation)))
  let anchor = [s.p[0], s.p[1], reference.p[2]]
  let bodies = kin.forward(s)
  for i, b in bodies {
    let target = vec_add(
      anchor,
      mat_vec(dr, vec_sub(reference_bodies[i].p, reference.p)),
    )
    out.append(mat_vec(ht, vec_sub(target, b.p)))
  }
  out.append(mat_vec(ht, vec_sub(reference.p, s.p)))
  out.append(mat_to_6d(mat_mul(transpose(s.rotation), reference.rotation)))
  out.append(xi)
  out
}
