///|
// This helper runs after actor backward. Cached rows cover t=1..H in the
// original time-major order; t=0 is computed separately because it is absent
// from the reward batch. No differentiable tensor escapes into critic fitting.
fn Learner::imagined_critic_features(
  self : Learner,
  states : Array[@geometry.State],
  references : Array[@geometry.State],
  xi_n : @tensor.Tensor,
  cached : @geometry.TrackingGeometry?,
  reference_fk~ : @tensor.Tensor? = None,
) -> @tensor.Tensor raise {
  let range = @tensor.operator_range_begin("diag.actor.critic_features")
  errdefer @tensor.operator_range_cancel(range)
  let output = @tensor.profile_span("actor.critic_features", () => {
    match cached {
      Some(tracking) => {
        let initial = match reference_fk {
          None =>
            self.context.critic_features(
              detach_state(states[0]),
              detach_state(references[0]),
              xi_n,
            )
          Some(table) =>
            self.context
            .tracking_geometry_cached(
              detach_state(states[0]),
              detach_state(references[0]),
              Some(
                table
                .narrow(0, 0, 1)
                .reshape([-1, self.context.reference_body_width()]),
              ),
            )
            .critic_features(xi_n)
        }
        let rest = tracking
          .detached()
          .critic_features(
            self.backend.concat(Array::make(self.config.horizon, xi_n)),
          )
        self.backend.concat([initial, rest]).stop_gradient()
      }
      None => {
        let detached = concat_states(self.backend, states.map(detach_state))
        let refs = concat_states(self.backend, references)
        let all_xi = self.backend.concat(
          Array::make(self.config.horizon + 1, xi_n),
        )
        self.context.critic_features(detached, refs, all_xi)
      }
    }
  })
  @tensor.operator_range_end(range)
  output
}
