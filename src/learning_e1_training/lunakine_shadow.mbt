///|
pub using @shadow {type ActorReplayFrame, type ActorReplay}

///|
fn shadow_policy(actor : Actor) -> @shadow.Policy raise {
  guard actor.spec.mode() is Smc else {
    fail("shadow execution requires the99-feature SMC actor")
  }
  @shadow.Policy::new(
    history_frames=actor.spec.hist,
    goal_width=actor.spec.goal_frames * 73,
    physical_actions=actor.robot.joints.length(),
    predict=(history, goals) => actor.forward_embedded(history, goals),
    nominal_setpoints=actions => {
      Array::makei(actor.robot.joints.length(), i => {
        actor.robot.default_q[i] + actor.robot.scales[i] * actions[i]
      })
    },
  )
}

///|
/// Compatibility entrypoint; recorded execution is owned by the deployment-only
/// shadow package. Both LibTorch comparison and LunaKine use the same runner.
pub fn replay_actor(actor : Actor, tape : ActorReplay) -> Json raise {
  @shadow.replay(shadow_policy(actor), tape)
}

///|
pub async fn replay_deployed_actor(
  actor : Actor,
  input : String,
  output : String,
) -> Json {
  defer (actor.close() catch { _ => () })
  let report = @shadow.replay_file(shadow_policy(actor), input, output)
  actor.close()
  report
}
