///|
fn main {
  let (dispatch, app) = @rabbita.cell_with_dispatch(
    model=init_model(),
    update~,
    view=(dispatch, model) => render_app(dispatch, model),
  )
  @rabbita.new(app)
  ..with_startup(@rabbita.batch([dispatch(RefreshSnapshot), dispatch(PollRuntimeHealth)]))
  .mount("app")
}
