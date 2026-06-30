///|
#warnings("-alert_unstable")
fn main {
  let (emit, app) = @rabbita.cell_with_emit(
    model=init_model(),
    update=(emit, msg, model) => update(msg => emit(msg), msg, model),
    view=(emit, model) => render_app(msg => emit(msg), model),
  )
  @rabbita.new(app)
  ..with_init(
    @rabbita.batch([
      emit(RefreshSnapshot),
      emit(PollRuntimeHealth),
      emit(RefreshTaskMessages),
      emit(RefreshUrdfEditorDocument),
    ]),
  )
  .mount("app")
}
