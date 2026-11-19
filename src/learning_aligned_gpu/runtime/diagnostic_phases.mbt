///|
fn diagnostic_phase_begin(
  iteration : Int32,
  phase : String,
) -> (Int64, Int64) raise {
  if @tensor.operator_diagnostic_iteration_selected(iteration, phase~) {
    println(
      "{\"format\":\"moonrobo.operator-window.v1\",\"state\":\"started\",\"iteration\":\{iteration}}",
    )
    @tensor.operator_diagnostic_flush()
  }
  let window = @tensor.operator_diagnostic_iteration_begin(iteration, phase~)
  errdefer @tensor.operator_diagnostic_iteration_cancel(window)
  let range = if window != 0L {
    @tensor.operator_range_begin("diag.iteration.\{iteration}.\{phase}")
  } else {
    0L
  }
  (window, range)
}

///|
fn diagnostic_phase_end(
  tokens : (Int64, Int64),
  iteration : Int32,
) -> Unit raise {
  let (window, range) = tokens
  @tensor.operator_range_end(range)
  @tensor.operator_diagnostic_iteration_end(window)
  if window != 0L {
    println(
      "{\"format\":\"moonrobo.operator-window.v1\",\"state\":\"completed\",\"iteration\":\{iteration}}",
    )
    @tensor.operator_diagnostic_flush()
  }
}

///|
fn diagnostic_phase_cancel(tokens : (Int64, Int64)) -> Unit {
  @tensor.operator_range_cancel(tokens.1)
  @tensor.operator_diagnostic_iteration_cancel(tokens.0)
}
