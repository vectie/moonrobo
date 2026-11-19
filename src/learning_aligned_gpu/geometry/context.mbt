///|
pub(all) struct BodyState {
  p : @tensor.Tensor
  rotation : @tensor.Tensor
  v : @tensor.Tensor
  w : @tensor.Tensor
}

///|
struct BodyConstants {
  offset_p : @tensor.Tensor
  offset_rotation : @tensor.Tensor
  pivot : @tensor.Tensor
  axis_column : @tensor.Tensor
}

///|
pub struct Context {
  backend : @tensor.Backend
  kin : @aligned.Kinematics
  cfg : @aligned.RewardConfig
  constants : Array[BodyConstants]
  default_q : @tensor.Tensor
  default_q_values : Array[Double]
  active_joints : Int32
  joint_mask : @tensor.Tensor?
  soft_lo : @tensor.Tensor
  soft_hi : @tensor.Tensor
  body_orientation_batched : Bool
  submitted_cross : Bool
  submitted_axis : Bool
  sparse_joint_axis : Bool
  rotation_error_mode : RotationErrorMode
  heading_mode : HeadingMode
  zero_joint_pivot : Bool
  native_cross : Bool
  cross_preserve_forward : Bool
  compact_axis_rotation : Bool
  fused_axis_rotation : Bool
  fused_cross_forward : Bool
  fused_cross_vjp : Bool
  static_fk_pruning : Bool
  compact_heading : Bool
  smc_fk_layout : Bool
  smc_critic_layout : Bool
}

///|
fn constant(
  backend : @tensor.Backend,
  device : Int32,
  shape : Array[Int32],
  values : Array[Double],
  dtype : @tensor.DType,
) -> @tensor.Tensor raise {
  backend.from_values(
    shape,
    values,
    cuda_device=device,
    requires_grad=false,
    dtype~,
  )
}

///|
/// Upload immutable kinematics once. Float32 matches the learner's physical state;
/// Float64 can be requested for CPU numerical parity checks.
pub fn Context::new(
  backend : @tensor.Backend,
  kin : @aligned.Kinematics,
  cuda_device : Int32,
  reward_cfg~ : @aligned.RewardConfig = @aligned.RewardConfig::default(),
  dtype~ : @tensor.DType = Float32,
  body_orientation_batched~ : Bool = false,
  submitted_cross~ : Bool = false,
  submitted_axis~ : Bool = false,
  default_q~ : Array[Double] = @aligned.default_joint_positions(),
  active_joints~ : Int32 = 29,
) -> Context raise {
  guard active_joints > 0 &&
    active_joints <= 29 &&
    default_q.length() == 29 &&
    default_q.all(x => !x.is_nan() && !x.is_inf()) &&
    default_q[active_joints:].all(x => x == 0.0) else {
    fail("invalid embedded embodiment or default posture")
  }
  guard !kin.bodies.is_empty() &&
    !kin.tracked.is_empty() &&
    kin.q_lo.length() == 29 &&
    kin.q_hi.length() == 29 else {
    fail("invalid G1 kinematics")
  }
  guard !body_orientation_batched || kin.tracked.length() <= 64 else {
    fail("batched body orientation exceeds the admitted 64 tracked-body bound")
  }
  let constants = []
  for i, spec in kin.bodies {
    guard (i == 0 && spec.parent < 0) || (spec.parent >= 0 && spec.parent < i) else {
      fail("kinematics must be in parent-first order with one root")
    }
    guard spec.joint >= -1 &&
      spec.joint < active_joints &&
      spec.axis.length() == 3 &&
      spec.offset_p.length() == 3 &&
      spec.offset_rotation.length() == 9 &&
      spec.pivot.length() == 3 else {
      fail("invalid body kinematics dimensions")
    }
    constants.push({
      offset_p: constant(backend, cuda_device, [1, 3], spec.offset_p, dtype),
      offset_rotation: constant(
        backend,
        cuda_device,
        [1, 3, 3],
        spec.offset_rotation,
        dtype,
      ),
      pivot: constant(backend, cuda_device, [1, 3], spec.pivot, dtype),
      axis_column: constant(backend, cuda_device, [3, 1], spec.axis, dtype),
    })
  }
  for i in kin.tracked {
    guard i >= 0 && i < kin.bodies.length() else {
      fail("tracked body index out of range")
    }
  }
  let lo = Array::makei(29, i => {
    (kin.q_lo[i] + kin.q_hi[i]) / 2.0 -
    (kin.q_hi[i] - kin.q_lo[i]) * reward_cfg.soft_limit_factor / 2.0
  })
  let hi = Array::makei(29, i => {
    (kin.q_lo[i] + kin.q_hi[i]) / 2.0 +
    (kin.q_hi[i] - kin.q_lo[i]) * reward_cfg.soft_limit_factor / 2.0
  })
  {
    backend,
    kin,
    cfg: reward_cfg,
    constants,
    active_joints,
    default_q_values: default_q.copy(),
    joint_mask: if active_joints == 29 {
      None
    } else {
      Some(
        constant(
          backend,
          cuda_device,
          [1, 29],
          Array::makei(29, i => if i < active_joints { 1.0 } else { 0.0 }),
          dtype,
        ),
      )
    },
    default_q: constant(backend, cuda_device, [1, 29], default_q, dtype),
    soft_lo: constant(backend, cuda_device, [1, 29], lo, dtype),
    soft_hi: constant(backend, cuda_device, [1, 29], hi, dtype),
    body_orientation_batched,
    submitted_cross,
    submitted_axis,
    sparse_joint_axis: false,
    rotation_error_mode: QuaternionLog,
    heading_mode: StableFallback,
    zero_joint_pivot: false,
    native_cross: false,
    cross_preserve_forward: false,
    compact_axis_rotation: false,
    fused_axis_rotation: false,
    fused_cross_forward: false,
    fused_cross_vjp: false,
    static_fk_pruning: false,
    compact_heading: false,
    smc_fk_layout: false,
    smc_critic_layout: false,
  }
}

///|
pub fn Context::forward(
  self : Context,
  state : State,
  all_bodies~ : Bool = false,
) -> Array[BodyState] raise {
  guard !(self.native_cross ||
    self.cross_preserve_forward ||
    self.fused_cross_forward ||
    self.compact_axis_rotation ||
    self.fused_axis_rotation) ||
    (state.p.shape()[0] >= 1 && state.p.shape()[0] <= 262144) else {
    fail("native FK cross exceeds admitted batch rows")
  }
  let out : Array[BodyState] = []
  for i, spec in self.kin.bodies {
    if spec.parent < 0 {
      out.push({ p: state.p, rotation: state.rotation, v: state.v, w: state.w, })
      continue
    }
    let par = out[spec.parent]
    let c = self.constants[i]
    let mut p = par.p.add(
      if self.smc_fk_layout {
        par.rotation.matmul(c.offset_p.reshape([3, 1])).reshape([-1, 3])
      } else {
        mv(par.rotation, c.offset_p)
      },
    )
    // Strict identity, never an approximate matrix test or G1-only assumption.
    let off = if self.static_fk_pruning &&
      !self.smc_fk_layout &&
      spec.offset_rotation == [1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0] {
      par.rotation
    } else {
      par.rotation.matmul(
        if self.smc_fk_layout {
          c.offset_rotation.reshape([3, 3])
        } else {
          c.offset_rotation
        },
      )
    }
    if self.static_fk_pruning && spec.joint < 0 {
      // Fixed links have no joint-induced velocity or pivot correction.
      out.push({
        p,
        rotation: off,
        v: par.v.add(self.cross(par.w, p.sub(par.p))),
        w: par.w,
      })
      continue
    }
    let rotation = if spec.joint < 0 {
      off
    } else {
      let angle = if self.zero_joint_pivot && spec.qref == 0.0 {
        col(state.q, spec.joint)
      } else {
        col(state.q, spec.joint).affine(1.0, bias=-spec.qref)
      }
      off.matmul(
        if self.fused_axis_rotation &&
          coordinate_axis(spec.axis) is Some((axis, sign)) {
          angle.fused_axis_rotation(axis, sign)
        } else if self.compact_axis_rotation &&
          coordinate_axis(spec.axis) is Some((axis, sign)) {
          angle.compact_axis_rotation(axis, sign)
        } else if self.submitted_axis {
          angle.axis_angle_submitted(spec.axis[0], spec.axis[1], spec.axis[2])
        } else {
          axis_angle(self.backend, spec.axis, angle)
        },
      )
    }
    if self.zero_joint_pivot && spec.joint >= 0 && spec.pivot.all(x => x == 0.0) {
      // SMC G1 path: no link-origin correction and no joint-induced linear
      // velocity at a zero pivot. General/nonzero pivots keep the path below.
      let jw = (if self.smc_fk_layout {
        off.matmul(c.axis_column).reshape([-1, 3])
      } else {
        self.joint_axis(off, spec.axis)
      }).mul(col(state.qd, spec.joint))
      let v = par.v.add(self.cross(par.w, p.sub(par.p)))
      out.push({ p, rotation, v, w: par.w.add(jw), })
      continue
    }
    let pivot = p.add(mv(off, c.pivot))
    let jw = if spec.joint < 0 {
      state.w.affine(0.0)
    } else {
      p = pivot.sub(mv(rotation, c.pivot))
      (if self.smc_fk_layout {
        off.matmul(c.axis_column).reshape([-1, 3])
      } else {
        self.joint_axis(off, spec.axis)
      }).mul(col(state.qd, spec.joint))
    }
    let v = par.v
      .add(self.cross(par.w, p.sub(par.p)))
      .add(self.cross(jw, p.sub(pivot)))
    out.push({ p, rotation, v, w: par.w.add(jw), })
  }
  if all_bodies {
    out
  } else {
    self.kin.tracked.map(i => out[i])
  }
}

///|
/// Match SMC's rank-two constant matmuls. Under TF32 these differ numerically
/// from broadcast bmm, identity pruning, and coordinate-column selection.
/// Keep disabled until the enclosing original-SMC training gate passes.
pub fn Context::with_smc_fk_layout(self : Context, enabled : Bool) -> Context {
  { ..self, smc_fk_layout: enabled, }
}

///|
/// Opt-in original SMC critic dataflow, including the shared batched body-error
/// matmuls. The former per-body implementation remains the default control.
pub fn Context::with_smc_critic_layout(
  self : Context,
  enabled : Bool,
) -> Context {
  { ..self, smc_critic_layout: enabled, }
}

///|
/// Reproduce SMC's soft-limit construction in the physical state's dtype.
/// Rounding the limits in Double before upload can move a ReLU boundary and
/// change its derivative even when the reward value agrees to many digits.
/// The original Context and its host-computed constants remain unchanged.
pub fn Context::with_smc_soft_limits(self : Context) -> Context raise {
  let device = self.soft_lo.cuda_device()
  let dtype = self.soft_lo.dtype()
  let lo = constant(self.backend, device, [1, 29], self.kin.q_lo, dtype)
  let hi = constant(self.backend, device, [1, 29], self.kin.q_hi, dtype)
  let mid = lo.add(hi).affine(0.5)
  let half = hi.sub(lo).affine(0.5)
  let span = half.affine(self.cfg.soft_limit_factor)
  { ..self, soft_lo: mid.sub(span), soft_hi: mid.add(span), }
}

///|
/// Validate the specialized reward graph's topology/configuration, then return
/// live FP32 robot constants. A different robot or reward must be re-exported.
/// This does not enable the compiled graph or replace the preserved eager path.
pub fn Context::compiled_reward_constants(
  self : Context,
  names : Array[String],
  parents : Array[Int32],
  joints : Array[Int32],
  tracked : Array[Int32],
  reward : Array[Double],
) -> Array[@tensor.Tensor] raise {
  let selected : Array[Int32] = []
  for i, body in self.kin.bodies {
    if body.parent < 0 || body.joint >= 0 {
      selected.push(i)
    }
  }
  guard selected.length() == 30 &&
    names.length() == 30 &&
    parents.length() == 30 &&
    joints.length() == 30 &&
    tracked.length() == 14 &&
    self.kin.tracked.length() == 14 &&
    self.soft_lo.dtype() == Float32 else {
    fail("compiled reward model dimensions")
  }
  for i, source in selected {
    let b = self.kin.bodies[source]
    guard b.name == names[i] &&
      b.joint == joints[i] &&
      b.qref == 0.0 &&
      b.pivot.all(x => x == 0.0) &&
      (
        (parents[i] == -1 && b.parent < 0) ||
        (parents[i] >= 0 && parents[i] < i && selected[parents[i]] == b.parent)
      ) else {
      fail("compiled reward topology differs at body \{i}")
    }
  }
  for i, source in self.kin.tracked {
    guard tracked[i] >= 0 && tracked[i] < 30 && selected[tracked[i]] == source else {
      fail("compiled reward tracked-body order differs")
    }
  }
  let c = self.cfg
  guard reward ==
    [
      c.body_pos_std,
      c.body_ori_std,
      c.body_linvel_std,
      c.body_angvel_std,
      c.root_pos_std,
      c.root_ori_std,
      c.w_action_rate,
      c.w_joint_limit,
      c.soft_limit_factor,
      c.term_height,
      c.term_tilt,
    ] else {
    fail("compiled reward coefficients differ")
  }
  let aligned = self.with_smc_soft_limits()
  [
    self.backend.concat(selected.map(i => self.constants[i].offset_p)),
    self.backend.concat(selected.map(i => self.constants[i].offset_rotation)),
    self.backend.concat(
      selected.map(i => self.constants[i].axis_column.reshape([1, 3])),
    ),
    aligned.soft_hi.reshape([29]),
    aligned.soft_lo.reshape([29]),
  ]
}

///|
fn coordinate_axis(axis : Array[Double]) -> (Int32, Double)? {
  for i in 0..<3 {
    if (axis[i] == 1.0 || axis[i] == -1.0) &&
      axis[(i + 1) % 3] == 0.0 &&
      axis[(i + 2) % 3] == 0.0 {
      return Some((i, axis[i]))
    }
  }
  None
}

///|
pub fn Context::with_compact_axis_rotation(
  self : Context,
  enabled : Bool,
) -> Context raise {
  guard !enabled || self.backend.has_compact_rotation() else {
    fail("compact rotation plugin required")
  }
  { ..self, compact_axis_rotation: enabled, }
}

///|
pub fn Context::with_static_fk_pruning(
  self : Context,
  enabled : Bool,
) -> Context {
  { ..self, static_fk_pruning: enabled, }
}

///|
pub fn Context::with_sparse_joint_axis(
  self : Context,
  enabled : Bool,
) -> Context {
  { ..self, sparse_joint_axis: enabled, }
}

///|
fn Context::joint_axis(
  self : Context,
  off : @tensor.Tensor,
  axis : Array[Double],
) -> @tensor.Tensor raise {
  // Exact signed coordinate axes only. General robot axes retain the original
  // operation order. Column selection uses a view and adds no memory reserve;
  // the full original FK/autograd allocation envelope is retained.
  if self.sparse_joint_axis {
    for k in 0..<3 {
      if (axis[k] == 1.0 || axis[k] == -1.0) &&
        axis[(k + 1) % 3] == 0.0 &&
        axis[(k + 2) % 3] == 0.0 {
        let column = off.narrow(2, k, 1).reshape([-1, 3])
        return if axis[k] == 1.0 { column } else { column.affine(-1.0) }
      }
    }
  }
  // Preserved generic reference implementation.
  columns(self.backend, [
    entry(off, 0)
    .affine(axis[0])
    .add(entry(off, 1).affine(axis[1]))
    .add(entry(off, 2).affine(axis[2])),
    entry(off, 3)
    .affine(axis[0])
    .add(entry(off, 4).affine(axis[1]))
    .add(entry(off, 5).affine(axis[2])),
    entry(off, 6)
    .affine(axis[0])
    .add(entry(off, 7).affine(axis[1]))
    .add(entry(off, 8).affine(axis[2])),
  ])
}

///|
fn Context::cross(
  self : Context,
  a : @tensor.Tensor,
  b : @tensor.Tensor,
) -> @tensor.Tensor raise {
  if self.fused_cross_vjp {
    a.fused_cross_vjp(b)
  } else if self.fused_cross_forward {
    a.fused_cross_forward(b)
  } else if self.cross_preserve_forward {
    a.cross_preserve_forward(b)
  } else if self.native_cross {
    a.native_cross(b)
  } else if self.submitted_cross {
    a.cross_submitted(b)
  } else {
    cross(self.backend, a, b)
  }
}

///|
/// Keep expanded/submitted cross as the default reference path.
pub fn Context::with_native_cross(
  self : Context,
  enabled : Bool,
) -> Context raise {
  guard !enabled ||
    (self.backend.has_native_cross() && !self.cross_preserve_forward) else {
    fail("native cross extension unavailable")
  }
  { ..self, native_cross: enabled, }
}

///|
pub fn Context::with_cross_preserve_forward(
  self : Context,
  enabled : Bool,
) -> Context raise {
  guard !enabled ||
    (self.backend.has_cross_preserve_forward() && !self.native_cross) else {
    fail("cross VJP extension unavailable or conflicting cross modes")
  }
  { ..self, cross_preserve_forward: enabled, }
}

///|
pub fn Context::observation(
  self : Context,
  state : State,
  previous : @tensor.Tensor,
  xi : @tensor.Tensor,
  reference : State,
  mode : @aligned.ObservationMode,
) -> @tensor.Tensor raise {
  let rt = tr(state.rotation)
  let parts = [
    state.q.sub(self.default_q).sub(xi.narrow(1, 1, 29)),
    state.qd,
    mv(rt, state.w),
    state.rotation.narrow(1, 2, 1).reshape([-1, 3]).affine(-1.0),
    previous,
  ]
  if mode != Paper {
    parts.push(mat_to_6d(rt.matmul(reference.rotation)))
  }
  if mode == Observable {
    parts.push(mv(rt, reference.p.sub(state.p)))
  }
  columns(self.backend, parts)
}

///|
/// Detached default posture for explicit-input compiled observation packages.
/// Callers must treat this shared immutable model constant as read-only.
pub fn Context::default_joint_positions(self : Context) -> @tensor.Tensor raise {
  self.default_q.stop_gradient()
}

///|
/// Original Double constants for host collection; a Float32 device readback
/// changes subtraction rounding and must not redefine the legacy G1 inputs.
pub fn Context::default_joint_values(self : Context) -> Array[Double] {
  self.default_q_values.copy()
}

///|
/// Physical axes occupy a prefix; unused embedding channels are exactly zero.
pub fn Context::active_joint_count(self : Context) -> Int32 {
  self.active_joints
}

///|
pub fn Context::project_state(self : Context, state : State) -> State raise {
  if self.active_joints == 29 {
    return state
  }
  guard self.joint_mask is Some(mask) else { fail("missing embodiment mask") }
  { ..state, q: state.q.mul(mask), qd: state.qd.mul(mask), }
}

///|
/// Mask dummy joint position, velocity and previous-action sensor channels,
/// including any additive observation noise supplied by a batch builder.
pub fn Context::project_observation(
  self : Context,
  obs : @tensor.Tensor,
) -> @tensor.Tensor raise {
  if self.active_joints == 29 {
    return obs
  }
  let width = obs.shape().last().unwrap()
  let mask = constant(
    self.backend,
    obs.cuda_device(),
    [width],
    Array::makei(width, i => {
      if (i >= self.active_joints && i < 29) ||
        (i >= 29 + self.active_joints && i < 58) ||
        (i >= 64 + self.active_joints && i < 93) {
        0.0
      } else {
        1.0
      }
    }),
    obs.dtype(),
  )
  obs.mul(mask)
}

///|
pub(all) struct RewardTerms {
  reward : @tensor.Tensor
  track : @tensor.Tensor
  body_pos : @tensor.Tensor
  body_ori : @tensor.Tensor
  body_linvel : @tensor.Tensor
  body_angvel : @tensor.Tensor
  root_pos : @tensor.Tensor
  root_ori : @tensor.Tensor
  action_rate : @tensor.Tensor
  joint_limit : @tensor.Tensor
}

///|
fn squared(x : @tensor.Tensor) -> @tensor.Tensor raise {
  x.square().sum_dim(1, keepdim=true)
}

///|
fn score(error : @tensor.Tensor, std : Double) -> @tensor.Tensor raise {
  error.affine(-1.0 / (std * std)).exp()
}

///|
pub fn Context::reward_terms(
  self : Context,
  state : State,
  reference : State,
  actions : @tensor.Tensor,
  previous : @tensor.Tensor,
) -> RewardTerms raise {
  let bodies = @tensor.profile_span("geometry.robot_fk", () => {
    @tensor.operator_span("diag.geometry.robot_fk", () => self.forward(state))
  })
  let refs = @tensor.profile_span("geometry.reference_fk", () => {
    @tensor.operator_span("diag.geometry.reference_fk", () => {
      self.forward(reference)
    })
  })
  self.reward_terms_from_bodies(
    state, reference, actions, previous, bodies, refs,
  )
}

///|
fn Context::reward_terms_from_bodies(
  self : Context,
  state : State,
  reference : State,
  actions : @tensor.Tensor,
  previous : @tensor.Tensor,
  bodies : Array[BodyState],
  refs : Array[BodyState],
) -> RewardTerms raise {
  let dr = yaw_mat(
    self.backend,
    state.rotation.matmul(tr(reference.rotation)),
    mode=self.heading_mode,
    compact=self.compact_heading,
  )
  let anchor = columns(self.backend, [
    state.p.narrow(1, 0, 2),
    col(reference.p, 2),
  ])
  let ps = []
  let rs = []
  let vs = []
  let ws = []
  for i, body in bodies {
    let ref_body = refs[i]
    {
      let pos_range = @tensor.operator_range_begin(
        "diag.reward.body_position.error",
      )
      errdefer @tensor.operator_range_cancel(pos_range)
      let target = anchor.add(mv(dr, ref_body.p.sub(reference.p)))
      ps.push(squared(target.sub(body.p)))
      @tensor.operator_range_end(pos_range)
    }
    if !self.body_orientation_batched {
      let ori_range = @tensor.operator_range_begin(
        "diag.reward.body_orientation.error",
      )
      errdefer @tensor.operator_range_cancel(ori_range)
      rs.push(
        angle_square(
          self.backend,
          dr.matmul(ref_body.rotation),
          body.rotation,
          mode=self.rotation_error_mode,
        ),
      )
      @tensor.operator_range_end(ori_range)
    }
    vs.push(
      @tensor.operator_span("diag.reward.body_linvel.error", () => {
        squared(ref_body.v.sub(body.v))
      }),
    )
    ws.push(
      @tensor.operator_span("diag.reward.body_angvel.error", () => {
        squared(ref_body.w.sub(body.w))
      }),
    )
  }
  let ep = columns(self.backend, ps).mean_dim(1, keepdim=true)
  let ev = columns(self.backend, vs).mean_dim(1, keepdim=true)
  let ew = columns(self.backend, ws).mean_dim(1, keepdim=true)
  let er = if self.body_orientation_batched {
    @tensor.operator_span("diag.reward.body_orientation.batched_error", () => {
      self.batched_body_orientation(dr, bodies, refs)
    })
  } else {
    columns(self.backend, rs).mean_dim(1, keepdim=true)
  }
  let root_pos = @tensor.operator_span("diag.reward.root_position.error", () => {
    squared(reference.p.sub(state.p))
  })
  let root_ori = @tensor.operator_span("diag.reward.root_orientation.error", () => {
    angle_square(
      self.backend,
      reference.rotation,
      state.rotation,
      mode=self.rotation_error_mode,
    )
  })
  let c = self.cfg
  let tracking_range = @tensor.operator_range_begin(
    "diag.reward.tracking_scores",
  )
  errdefer @tensor.operator_range_cancel(tracking_range)
  let track = score(ep, c.body_pos_std)
    .add(score(er, c.body_ori_std))
    .add(score(ev, c.body_linvel_std))
    .add(score(ew, c.body_angvel_std))
    .add(score(root_pos, c.root_pos_std).affine(0.5))
    .add(score(root_ori, c.root_ori_std).affine(0.5))
  @tensor.operator_range_end(tracking_range)
  let rate = @tensor.operator_span("diag.reward.action_rate", () => {
    squared(actions.sub(previous))
  })
  let limit_range = @tensor.operator_range_begin("diag.reward.joint_limit")
  errdefer @tensor.operator_range_cancel(limit_range)
  let limit = state.q
    .sub(self.soft_hi)
    .relu()
    .add(self.soft_lo.sub(state.q).relu())
    .sum_dim(1, keepdim=true)
  @tensor.operator_range_end(limit_range)
  {
    reward: track
    .add(rate.affine(c.w_action_rate))
    .add(limit.affine(c.w_joint_limit))
    .affine(@aligned.control_dt)
    .reshape([-1]),
    track: track.affine(@aligned.control_dt).reshape([-1]),
    body_pos: ep.reshape([-1]),
    body_ori: er.reshape([-1]),
    body_linvel: ev.reshape([-1]),
    body_angvel: ew.reshape([-1]),
    root_pos: root_pos.reshape([-1]),
    root_ori: root_ori.reshape([-1]),
    action_rate: rate.reshape([-1]),
    joint_limit: limit.reshape([-1]),
  }
}

///|
pub fn Context::reward(
  self : Context,
  state : State,
  reference : State,
  actions : @tensor.Tensor,
  previous : @tensor.Tensor,
) -> @tensor.Tensor raise {
  self.reward_terms(state, reference, actions, previous).reward
}

///|
pub fn Context::soft_failure(
  self : Context,
  state : State,
  reference : State,
  height_temperature~ : Double = 0.02,
  tilt_temperature~ : Double = 0.04,
) -> @tensor.Tensor raise {
  guard height_temperature > 0.0 && tilt_temperature > 0.0 else {
    fail("soft termination temperatures must be positive")
  }
  let a = col(reference.p, 2)
    .sub(col(state.p, 2))
    .abs()
    .affine(
      1.0 / height_temperature,
      bias=-self.cfg.term_height / height_temperature,
    )
    .sigmoid()
  let b = entry(reference.rotation, 8)
    .sub(entry(state.rotation, 8))
    .abs()
    .affine(1.0 / tilt_temperature, bias=-self.cfg.term_tilt / tilt_temperature)
    .sigmoid()
  a
  .affine(-1.0, bias=1.0)
  .mul(b.affine(-1.0, bias=1.0))
  .affine(-1.0, bias=1.0)
  .reshape([-1])
}

///|
/// Output width is 142 + 3 * tracked body count (184 for the G1 14-body contract).
/// xi_n is normalized, matching the learner's critic input contract.
pub fn Context::critic_features(
  self : Context,
  state : State,
  reference : State,
  xi_n : @tensor.Tensor,
) -> @tensor.Tensor raise {
  if self.smc_critic_layout {
    return self.critic_features_smc(state, reference, xi_n)
  }
  // Keep the baseline submission order for paired measurements.
  let parts = [
    invariant_features(
      self.backend,
      state,
      heading_mode=self.heading_mode,
      compact_heading=self.compact_heading,
    ),
    reference.q.sub(state.q),
  ]
  let ht = tr(
    yaw_mat(
      self.backend,
      state.rotation,
      mode=self.heading_mode,
      compact=self.compact_heading,
    ),
  )
  let dr = yaw_mat(
    self.backend,
    state.rotation.matmul(tr(reference.rotation)),
    mode=self.heading_mode,
    compact=self.compact_heading,
  )
  let anchor = columns(self.backend, [
    state.p.narrow(1, 0, 2),
    col(reference.p, 2),
  ])
  let bodies = @tensor.profile_span("geometry.robot_fk", () => {
    @tensor.operator_span("diag.geometry.robot_fk", () => self.forward(state))
  })
  let refs = @tensor.profile_span("geometry.reference_fk", () => {
    @tensor.operator_span("diag.geometry.reference_fk", () => {
      self.forward(reference)
    })
  })
  for i, body in bodies {
    let target = anchor.add(mv(dr, refs[i].p.sub(reference.p)))
    parts.push(mv(ht, target.sub(body.p)))
  }
  parts.push(mv(ht, reference.p.sub(state.p)))
  parts.push(mat_to_6d(tr(state.rotation).matmul(reference.rotation)))
  parts.push(xi_n)
  columns(self.backend, parts)
}

///|
fn Context::critic_features_smc(
  self : Context,
  state : State,
  reference : State,
  xi_n : @tensor.Tensor,
  reference_fk~ : @tensor.Tensor? = None,
) -> @tensor.Tensor raise {
  // The actor tail in SMC is eager. Keep its graph boundaries and accumulation
  // points, rather than substituting the fused FK/heading derivative here.
  let eager = {
    ..self,
    smc_fk_layout: true,
    native_cross: true,
    cross_preserve_forward: false,
    fused_cross_forward: false,
    fused_cross_vjp: false,
    compact_axis_rotation: false,
    fused_axis_rotation: false,
    submitted_axis: false,
    zero_joint_pivot: true,
    static_fk_pruning: false,
    compact_heading: false,
    heading_mode: self.heading_mode,
  }
  let n = state.p.shape()[0]
  let count = self.kin.tracked.length()
  let ht = tr(self.critic_heading(state.rotation))
  let bp = self.backend.stack(eager.forward(state).map(b => b.p), axis=1)
  let ref_bp = match reference_fk {
    Some(packed) => {
      guard packed.shape() == [n, self.reference_body_width()] else {
        fail("critic tail reference FK shape/context mismatch")
      }
      // Cache contains [body position, orientation, linear/angular velocity].
      // Only the immutable reference positions are reused. Materialize their
      // original dense layout; do not fuse or detach any robot-state path.
      self.backend.concat([
        packed.stop_gradient().reshape([n, count, 18]).narrow(2, 0, 3),
      ])
    }
    None => self.backend.stack(eager.forward(reference).map(b => b.p), axis=1)
  }
  let dr = self.critic_heading(state.rotation.matmul(tr(reference.rotation)))
  let anchor = columns(self.backend, [
    state.p.narrow(1, 0, 2),
    col(reference.p, 2),
  ])
  let target = anchor
    .reshape([n, 1, 3])
    .add(
      dr
      .reshape([n, 1, 3, 3])
      .matmul(
        ref_bp.sub(reference.p.reshape([n, 1, 3])).reshape([n, count, 3, 1]),
      )
      .reshape([n, count, 3]),
    )
  let body_error = ht
    .reshape([n, 1, 3, 3])
    .matmul(target.sub(bp).reshape([n, count, 3, 1]))
    .reshape([n, count * 3])
  let root_error = mv(ht, reference.p.sub(state.p))
  let relative = mat_to_6d(tr(state.rotation).matmul(reference.rotation))
  // Match SMC's shared Rt boundary. Its isolated control did not change the
  // measured residual; the duplicate heading products below did.
  let ih = self.critic_heading(state.rotation)
  let rt = tr(state.rotation)
  let invariant = columns(self.backend, [
    col(state.p, 2),
    mat_to_6d(tr(ih).matmul(state.rotation)),
    mv(rt, state.v),
    mv(rt, state.w),
    state.q,
    state.qd,
  ])
  columns(self.backend, [
    invariant,
    reference.q.sub(state.q),
    body_error,
    root_error,
    relative,
    xi_n,
  ])
}

///|
/// Opt-in SMC-layout tail features using the caller's reference FK cache.
/// The cache must belong to this context and the exact supplied reference.
/// Reference data is detached by contract; robot-state derivatives stay live.
pub fn Context::critic_features_cached_reference(
  self : Context,
  state : State,
  reference : State,
  xi_n : @tensor.Tensor,
  reference_fk : @tensor.Tensor,
) -> @tensor.Tensor raise {
  guard self.smc_critic_layout else {
    fail("cached critic tail requires SMC feature layout")
  }
  self.critic_features_smc(
    state,
    reference,
    xi_n,
    reference_fk=Some(reference_fk),
  )
}

///|
/// SMC writes x*x and y*y. Preserve both MulBackward edges: square() has
/// the same forward values but a different gradient join with x/n and y/n.
/// This helper is confined to the opt-in original critic graph.
fn smc_critic_heading(
  backend : @tensor.Backend,
  r : @tensor.Tensor,
) -> @tensor.Tensor raise {
  let x = entry(r, 0)
  let y = entry(r, 3)
  let n = x.mul(x).add(y.mul(y)).affine(1.0, bias=1.0e-9).sqrt()
  let c = x.div(n)
  let s = y.div(n)
  let zero = c.stop_gradient().affine(0.0)
  mat(backend, [
    c,
    s.affine(-1.0),
    zero,
    s,
    c,
    zero,
    zero,
    zero,
    zero.affine(0.0, bias=1.0),
  ])
}

///|
// Preserve critic batching and gradient joins independently of geometry mode.
// A corrected heading must also reach the actor's differentiable tail value.
fn Context::critic_heading(
  self : Context,
  r : @tensor.Tensor,
) -> @tensor.Tensor raise {
  if self.heading_mode == SmcProjected {
    smc_critic_heading(self.backend, r)
  } else {
    yaw_mat(self.backend, r, mode=self.heading_mode)
  }
}

///|
fn Context::critic_features_from_bodies(
  self : Context,
  state : State,
  reference : State,
  xi_n : @tensor.Tensor,
  bodies : Array[BodyState],
  refs : Array[BodyState],
) -> @tensor.Tensor raise {
  if self.smc_critic_layout {
    // A cached eager graph may have a different FK/heading derivative. The
    // strict comparison route deliberately reconstructs the original graph.
    return self.critic_features_smc(state, reference, xi_n)
  }
  let parts = [
    invariant_features(
      self.backend,
      state,
      heading_mode=self.heading_mode,
      compact_heading=self.compact_heading,
    ),
    reference.q.sub(state.q),
  ]
  let ht = tr(
    yaw_mat(
      self.backend,
      state.rotation,
      mode=self.heading_mode,
      compact=self.compact_heading,
    ),
  )
  let dr = yaw_mat(
    self.backend,
    state.rotation.matmul(tr(reference.rotation)),
    mode=self.heading_mode,
    compact=self.compact_heading,
  )
  let anchor = columns(self.backend, [
    state.p.narrow(1, 0, 2),
    col(reference.p, 2),
  ])
  for i, body in bodies {
    let target = anchor.add(mv(dr, refs[i].p.sub(reference.p)))
    parts.push(mv(ht, target.sub(body.p)))
  }
  parts.push(mv(ht, reference.p.sub(state.p)))
  parts.push(mat_to_6d(tr(state.rotation).matmul(reference.rotation)))
  parts.push(xi_n)
  columns(self.backend, parts)
}

///|
pub fn Context::with_heading_mode(
  self : Context,
  mode : HeadingMode,
) -> Context {
  { ..self, heading_mode: mode, }
}

///|
/// Specialize exactly zero pivots; retain general axes, fixed bodies and offsets.
pub fn Context::with_zero_joint_pivot(
  self : Context,
  enabled : Bool,
) -> Context {
  { ..self, zero_joint_pivot: enabled, }
}
