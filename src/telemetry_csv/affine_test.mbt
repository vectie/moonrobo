///|
fn affine_recipe(
  fit_start? : Int64 = 1000L,
  fit_end? : Int64 = 1300L,
  holdout_start? : Int64 = 2000L,
  holdout_end? : Int64 = 2200L,
  predictor? : String = "sensor.raw",
  response? : String = "reference.n",
  output? : String = "predicted.n",
  x_unit? : String = "raw",
  y_unit? : String = "N",
) -> @telemetry_csv.AffineRecipe {
  {
    predictor,
    response,
    output_channel: output,
    predictor_unit: x_unit,
    response_unit: y_unit,
    fit_start_ms: fit_start,
    fit_end_ms: fit_end,
    holdout_start_ms: holdout_start,
    holdout_end_ms: holdout_end,
  }
}

///|
fn affine_fixture() -> String {
  "timestamp_ms,sensor.raw,reference.n,temperature.c\n1000,0,1,20\n1100,1,3,20\n1200,2,5,21\n1300,3,7,21\n2000,1,4,22\n2100,2,4,22\n2200,4,11,23\n3000,99,0,24\n"
}

///|
fn affine_near(
  actual : Double,
  expected : Double,
  tolerance? : Double = 1.0e-12,
) -> Unit raise {
  assert_true(
    (actual - expected).abs() <= tolerance,
    msg="expected \{expected}, got \{actual}",
  )
}

///|
test "affine fit hand calculation and held-out residuals" {
  let fit = @telemetry_csv.fit_affine_csv(affine_fixture(), affine_recipe()).unwrap()
  affine_near(fit.scale, 2.0)
  affine_near(fit.offset, 1.0)
  affine_near(fit.fit_summary.root_mean_square_error, 0.0)
  affine_near(fit.holdout_summary.bias, 2.0 / 3.0)
  affine_near(fit.holdout_summary.mean_absolute_error, 4.0 / 3.0)
  affine_near(fit.holdout_summary.root_mean_square_error, 2.0.sqrt())
  affine_near(fit.holdout_summary.maximum_absolute_error, 2.0)
  assert_eq(fit.fit_summary.sample_count, 4)
  assert_eq(fit.holdout_summary.sample_count, 3)
  assert_eq(fit.excluded_sample_count, 1)
}

///|
test "affine holdout change cannot leak into coefficients" {
  let first = @telemetry_csv.fit_affine_csv(affine_fixture(), affine_recipe()).unwrap()
  let changed = affine_fixture().replace(
    old="2000,1,4,22",
    new="2000,1,1000,22",
  )
  let second = @telemetry_csv.fit_affine_csv(changed, affine_recipe()).unwrap()
  assert_eq(first.scale, second.scale)
  assert_eq(first.offset, second.offset)
  assert_true(second.holdout_summary.root_mean_square_error > 500.0)
}

///|
test "affine range flags describe extrapolation only" {
  let fit = @telemetry_csv.fit_affine_csv(affine_fixture(), affine_recipe()).unwrap()
  assert_eq(fit.fit_predictor_minimum, 0.0)
  assert_eq(fit.fit_predictor_maximum, 3.0)
  assert_eq(fit.fit_summary.outside_fit_predictor_range_count, 0)
  assert_eq(fit.holdout_summary.outside_fit_predictor_range_count, 1)
  assert_eq(fit.rows[6].outside_fit_predictor_range, true)
  affine_near(fit.rows[6].predicted, 9.0)
  assert_eq(fit.rows[6].source_sample_index, 6)
  assert_eq(fit.source.samples[7].values, [99.0, 0.0, 24.0])
}

///|
test "affine reusable normalization recipe agrees with every selected prediction" {
  let fit = @telemetry_csv.fit_affine_csv(affine_fixture(), affine_recipe()).unwrap()
  let text = fit.normalization_recipe().to_json().stringify()
  let parsed = @telemetry_csv.parse_normalization_recipe(text).unwrap()
  let normalized = @telemetry_csv.normalize_csv(affine_fixture(), parsed).unwrap()
  assert_eq(normalized.recording.channels, [
    "predicted.n", "reference.n", "temperature.c",
  ])
  assert_eq(normalized.recording.samples.length(), 8)
  for row in fit.rows {
    assert_eq(
      normalized.recording.samples[row.source_sample_index].values[0],
      row.predicted,
    )
  }
  let reopened = @telemetry_csv.parse(normalized.to_csv().unwrap()).unwrap()
  assert_eq(reopened, normalized.recording)
}

///|
test "affine residual exports isolate the requested partition and reopen" {
  let fit = @telemetry_csv.fit_affine_csv(affine_fixture(), affine_recipe()).unwrap()
  let holdout = @telemetry_csv.parse(fit.residual_csv("holdout").unwrap()).unwrap()
  assert_eq(holdout.samples.map(s => s.timestamp_ms), [2000L, 2100L, 2200L])
  assert_eq(holdout.channels, ["predictor", "observed", "predicted", "residual"])
  let train = @telemetry_csv.parse(fit.residual_csv("fit").unwrap()).unwrap()
  assert_eq(train.samples.length(), 4)
  assert_true(fit.residual_csv("both") is Err(_))
  let plot = @telemetry_csv.plot_csv(
    fit.residual_csv("holdout").unwrap(),
    ["residual"],
    unit_labels=["N"],
    max_gap_ms=100L,
  ).unwrap()
  assert_eq(plot.segment_count, 1)
  assert_true(plot.to_svg().contains("<svg"))
}

///|
test "affine changing fit window changes candidate while preserving original" {
  let original = affine_fixture()
  let fit = @telemetry_csv.fit_affine_csv(
    original,
    affine_recipe(
      fit_start=2000L,
      fit_end=2200L,
      holdout_start=1000L,
      holdout_end=1300L,
    ),
  ).unwrap()
  affine_near(fit.scale, 2.5)
  affine_near(fit.offset, 0.5)
  assert_eq(fit.source, @telemetry_csv.parse(original).unwrap())
}

///|
test "affine rejects overlapping endpoints reversed windows and negative time" {
  for
    recipe in [
      affine_recipe(holdout_start=1300L),
      affine_recipe(fit_start=1300L, fit_end=1000L),
      affine_recipe(fit_start=-1L),
      affine_recipe(holdout_end=1000L),
    ] {
    assert_true(
      @telemetry_csv.fit_affine_csv(affine_fixture(), recipe) is Err(_),
    )
  }
}

///|
test "affine requires three fit observations and nonempty holdout" {
  assert_true(
    @telemetry_csv.fit_affine_csv(
      affine_fixture(),
      affine_recipe(fit_end=1100L),
    )
    is Err(_),
  )
  assert_true(
    @telemetry_csv.fit_affine_csv(
      affine_fixture(),
      affine_recipe(holdout_start=4000L, holdout_end=5000L),
    )
    is Err(_),
  )
  let fit = @telemetry_csv.fit_affine_csv(
    affine_fixture(),
    affine_recipe(holdout_end=2000L),
  ).unwrap()
  assert_eq(fit.holdout_summary.sample_count, 1)
  affine_near(fit.holdout_summary.root_mean_square_error, 1.0)
}

///|
test "affine constant predictor is unidentified including all zero" {
  for x in ["0", "5", "1e300"] {
    let text = "timestamp_ms,sensor.raw,reference.n\n1000,\{x},1\n1100,\{x},2\n1200,\{x},3\n2000,0,4\n"
    assert_true(@telemetry_csv.fit_affine_csv(text, affine_recipe()) is Err(_))
  }
}

///|
test "affine constant response has zero slope including extreme scale ratio" {
  for y in ["0", "7", "1e300"] {
    let text = "timestamp_ms,sensor.raw,reference.n\n1000,1e-100,\{y}\n1100,2e-100,\{y}\n1200,3e-100,\{y}\n2000,4e-100,\{y}\n"
    let fit = @telemetry_csv.fit_affine_csv(text, affine_recipe()).unwrap()
    assert_eq(fit.scale, 0.0)
    assert_eq(fit.fit_summary.root_mean_square_error, 0.0)
    assert_eq(fit.holdout_summary.root_mean_square_error, 0.0)
  }
}

///|
test "affine negative slope and irregular cadence are sample weighted" {
  let text = "timestamp_ms,sensor.raw,reference.n\n1000,-2,10\n1001,0,4\n1300,2,-2\n2000,1,1\n"
  let fit = @telemetry_csv.fit_affine_csv(text, affine_recipe()).unwrap()
  affine_near(fit.scale, -3.0)
  affine_near(fit.offset, 4.0)
  affine_near(fit.holdout_summary.root_mean_square_error, 0.0)
}

///|
test "affine validates unused rows and unrelated columns" {
  for
    bad in [
      affine_fixture().replace(old="3000,99,0,24", new="3000,99,0,NaN"),
      affine_fixture().replace(old="3000,99,0,24", new="3000,99,0"),
      affine_fixture() + "3000,1,1,1\n",
    ] {
    assert_true(@telemetry_csv.fit_affine_csv(bad, affine_recipe()) is Err(_))
  }
}

///|
test "affine rejects unknown roles output collisions and blank units" {
  for
    recipe in [
      affine_recipe(predictor="missing"),
      affine_recipe(response="missing"),
      affine_recipe(response="sensor.raw"),
      affine_recipe(output="reference.n"),
      affine_recipe(output="timestamp_ms"),
      affine_recipe(output="bad,name"),
      affine_recipe(x_unit=" "),
      affine_recipe(y_unit=""),
    ] {
    assert_true(
      @telemetry_csv.fit_affine_csv(affine_fixture(), recipe) is Err(_),
    )
  }
}

///|
test "affine exact Int64 time survives JSON and residual export" {
  let text = "timestamp_ms,sensor.raw,reference.n\n9223372036854775800,0,1\n9223372036854775801,1,3\n9223372036854775802,2,5\n9223372036854775807,3,7\n"
  let recipe = affine_recipe(
    fit_start=9223372036854775800L,
    fit_end=9223372036854775802L,
    holdout_start=9223372036854775807L,
    holdout_end=9223372036854775807L,
  )
  let fit = @telemetry_csv.fit_affine_csv(text, recipe).unwrap()
  assert_true(fit.to_json().stringify().contains("\"9223372036854775807\""))
  assert_eq(
    @telemetry_csv.parse(fit.residual_csv("holdout").unwrap()).unwrap().samples[0].timestamp_ms,
    9223372036854775807L,
  )
}

///|
test "affine recipe rejects duplicate unknown missing and numeric timestamp fields" {
  let text = affine_recipe().to_json().stringify()
  assert_eq(@telemetry_csv.parse_affine_recipe(text).unwrap(), affine_recipe())
  assert_true(
    @telemetry_csv.parse_affine_recipe(
      text.replace(old="\"fit_start_ms\":\"1000\"", new="\"fit_start_ms\":1000"),
    )
    is Err(_),
  )
  assert_true(
    @telemetry_csv.parse_affine_recipe(
      text.replace(old="\"predictor\":", new="\"unknown\":"),
    )
    is Err(_),
  )
  assert_true(
    @telemetry_csv.parse_affine_recipe(
      "{\"predictor\":\"x\",\"predictor\":\"y\"}",
    )
    is Err(_),
  )
  assert_true(@telemetry_csv.parse_affine_recipe("{}") is Err(_))
  assert_true(@telemetry_csv.parse_affine_recipe("[") is Err(_))
}

///|
test "affine large finite values avoid square and sum overflow" {
  let text = "timestamp_ms,sensor.raw,reference.n\n1000,-1e300,-1e300\n1100,0,0\n1200,1e300,1e300\n2000,5e299,4e299\n"
  let fit = @telemetry_csv.fit_affine_csv(text, affine_recipe()).unwrap()
  affine_near(fit.scale, 1.0)
  affine_near(fit.holdout_summary.root_mean_square_error / 1.0e299, 1.0)
}

///|
test "affine nonfinite candidate or residual fails before export" {
  let huge = "timestamp_ms,sensor.raw,reference.n\n1000,0,0\n1100,1,1e308\n1200,-1,-1e308\n2000,2,1\n"
  assert_true(@telemetry_csv.fit_affine_csv(huge, affine_recipe()) is Err(_))
  let residual = "timestamp_ms,sensor.raw,reference.n\n1000,-1,-1e308\n1100,0,0\n1200,1,1e308\n2000,1,-1e308\n"
  assert_true(
    @telemetry_csv.fit_affine_csv(residual, affine_recipe()) is Err(_),
  )
}

///|
test "affine JSON keeps hostile labels as inert data" {
  let recipe = affine_recipe(x_unit="<script>&\"", y_unit="N</text>")
  let fit = @telemetry_csv.fit_affine_csv(affine_fixture(), recipe).unwrap()
  assert_eq(fit.recipe.predictor_unit, "<script>&\"")
  assert_true(
    fit
    .residual_csv("fit")
    .unwrap()
    .has_prefix("timestamp_ms,predictor,observed,predicted,residual"),
  )
}
