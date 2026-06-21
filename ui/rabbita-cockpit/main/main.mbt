///|
fn main {
  let app = @rabbita.static_cell(render_app(sample_snapshot()))
  @rabbita.new(app).mount("app")
}
