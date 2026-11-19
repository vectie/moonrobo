///|
/// Batch-local kinematics for exactly the stored state/reference pair. The
/// object has no mutable cache and cannot be rebound to a later actor update.
/// Reward and tail features preserve gradients; detached() explicitly cuts the
/// actor graph before producing critic training inputs.
pub struct TrackingGeometry {
  context : Context
  state : State
  reference : State
  bodies : Array[BodyState]
  refs : Array[BodyState]
}

///|
pub fn Context::tracking_geometry(
  self : Context,
  state : State,
  reference : State,
) -> TrackingGeometry raise {
  self.tracking_geometry_cached(state, reference, None)
}

///|
/// Optional immutable reference FK rows, packed by this same Context. Robot
/// FK always stays connected to autograd; cached reference rows are detached.
pub fn Context::tracking_geometry_cached(
  self : Context,
  state : State,
  reference : State,
  packed_reference : @tensor.Tensor?,
) -> TrackingGeometry raise {
  // The execution-only admission supplement reserves at most 64 tracked
  // bodies. Reject a larger contract before allocating the optional cache.
  guard self.kin.tracked.length() <= 64 else {
    fail("tracking reuse exceeds the admitted 64 tracked-body bound")
  }
  {
    context: self,
    state,
    reference,
    bodies: @tensor.profile_span("geometry.robot_fk", () => {
      @tensor.operator_span("diag.geometry.robot_fk", () => self.forward(state))
    }),
    refs: @tensor.profile_span("geometry.reference_fk", () => {
      @tensor.operator_span("diag.geometry.reference_fk", () => {
        match packed_reference {
          None => self.forward(reference)
          Some(packed) => {
            guard packed.shape().length() == 2 &&
              packed.shape()[0] == reference.p.shape()[0] else {
              fail("cached reference FK row count differs")
            }
            self.unpack_reference_bodies(packed)
          }
        }
      })
    }),
  }
}

///|
pub fn Context::pack_reference_bodies(
  self : Context,
  state : State,
) -> @tensor.Tensor raise {
  let bodies = self.forward(state)
  let columns : Array[@tensor.Tensor] = []
  for body in bodies {
    columns.append([body.p, body.rotation.reshape([-1, 9]), body.v, body.w])
  }
  self.backend.concat(columns, axis=1).stop_gradient()
}

///|
pub fn Context::reference_body_width(self : Context) -> Int32 {
  self.kin.tracked.length() * 18
}

///|
fn Context::unpack_reference_bodies(
  self : Context,
  packed : @tensor.Tensor,
) -> Array[BodyState] raise {
  guard packed.shape().length() == 2 &&
    packed.shape()[1] == self.reference_body_width() else {
    fail("cached reference FK shape/context mismatch")
  }
  let packed = packed.stop_gradient()
  Array::makei(self.kin.tracked.length(), i => {
    p: packed.narrow(1, i * 18, 3),
    rotation: packed.narrow(1, i * 18 + 3, 9).reshape([-1, 3, 3]),
    v: packed.narrow(1, i * 18 + 12, 3),
    w: packed.narrow(1, i * 18 + 15, 3),
  })
}

///|
pub fn TrackingGeometry::reward(
  self : TrackingGeometry,
  actions : @tensor.Tensor,
  previous : @tensor.Tensor,
) -> @tensor.Tensor raise {
  self.reward_terms(actions, previous).reward
}

///|
/// Expose the same component errors without repeating robot/reference FK.
/// This preserves the reward graph and supports same-input numerical audits.
pub fn TrackingGeometry::reward_terms(
  self : TrackingGeometry,
  actions : @tensor.Tensor,
  previous : @tensor.Tensor,
) -> RewardTerms raise {
  self.context.reward_terms_from_bodies(
    self.state,
    self.reference,
    actions,
    previous,
    self.bodies,
    self.refs,
  )
}

///|
pub fn TrackingGeometry::critic_features(
  self : TrackingGeometry,
  xi_n : @tensor.Tensor,
) -> @tensor.Tensor raise {
  self.context.critic_features_from_bodies(
    self.state,
    self.reference,
    xi_n,
    self.bodies,
    self.refs,
  )
}

///|
fn reuse_state_map(
  state : State,
  f : (@tensor.Tensor) -> @tensor.Tensor raise,
) -> State raise {
  {
    p: f(state.p),
    rotation: f(state.rotation),
    v: f(state.v),
    w: f(state.w),
    q: f(state.q),
    qd: f(state.qd),
  }
}

///|
fn reuse_bodies_map(
  bodies : Array[BodyState],
  f : (@tensor.Tensor) -> @tensor.Tensor raise,
) -> Array[BodyState] raise {
  bodies.map(body => {
    p: f(body.p),
    rotation: f(body.rotation),
    v: f(body.v),
    w: f(body.w),
  })
}

///|
/// Views only: the tail remains connected to the same predicted-state graph.
pub fn TrackingGeometry::narrow(
  self : TrackingGeometry,
  start : Int32,
  count : Int32,
) -> TrackingGeometry raise {
  let f : (@tensor.Tensor) -> @tensor.Tensor raise = value => {
    value.narrow(0, start, count)
  }
  {
    context: self.context,
    state: reuse_state_map(self.state, f),
    reference: reuse_state_map(self.reference, f),
    bodies: reuse_bodies_map(self.bodies, f),
    refs: reuse_bodies_map(self.refs, f),
  }
}

///|
/// Shares storage while cutting every predicted/reference FK gradient edge.
pub fn TrackingGeometry::detached(
  self : TrackingGeometry,
) -> TrackingGeometry raise {
  let f : (@tensor.Tensor) -> @tensor.Tensor raise = value => {
    value.stop_gradient()
  }
  {
    context: self.context,
    state: reuse_state_map(self.state, f),
    reference: reuse_state_map(self.reference, f),
    bodies: reuse_bodies_map(self.bodies, f),
    refs: reuse_bodies_map(self.refs, f),
  }
}
