///|
/// Training/evaluation compatibility wrapper. The task/reference runner lives
/// in e1_actor_shadow; this wrapper retains the selected actor's close lifetime.
pub async fn serve_actor_shadow(
  actor : Actor,
  input : String,
  bind : String,
) -> Unit {
  defer (actor.close() catch { _ => () })
  @shadow.serve(shadow_policy(actor), input, bind)
}
