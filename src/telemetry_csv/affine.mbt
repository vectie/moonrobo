///|
pub(all) struct AffineRow {
  source_sample_index : Int
  timestamp_ms : Int64
  partition : String
  predictor : Double
  observed : Double
  predicted : Double
  residual : Double
  outside_fit_predictor_range : Bool
} derive(Debug, Eq, ToJson)

///|
pub(all) struct AffineSummary {
  sample_count : Int
  bias : Double
  mean_absolute_error : Double
  root_mean_square_error : Double
  maximum_absolute_error : Double
  outside_fit_predictor_range_count : Int
} derive(Debug, Eq, ToJson)

///|
pub(all) struct AffineFit {
  format : String
  method : String
  scope : String
  residual_direction : String
  recipe : AffineRecipe
  scale : Double
  offset : Double
  fit_predictor_minimum : Double
  fit_predictor_maximum : Double
  fit_summary : AffineSummary
  holdout_summary : AffineSummary
  excluded_sample_count : Int
  source : Recording
  rows : Array[AffineRow]
} derive(Debug, Eq, ToJson)

///|
fn affine_finite(value : Double) -> Bool {
  !value.is_inf() && !value.is_nan()
}

///|
fn affine_mean(values : Array[Double]) -> Double {
  let mut sum = 0.0
  let mut correction = 0.0
  let count = values.length().to_double()
  for value in values {
    let next = value / count - correction
    let total = sum + next
    correction = total - sum - next
    sum = total
  }
  sum
}

///|
fn affine_summary(rows : Array[AffineRow]) -> AffineSummary {
  let mut maximum = 0.0
  let mut outside = 0
  for row in rows {
    maximum = maximum.max(row.residual.abs())
    if row.outside_fit_predictor_range {
      outside += 1
    }
  }
  let normalized = rows.map(r => {
    if maximum == 0.0 {
      0.0
    } else {
      r.residual / maximum
    }
  })
  {
    sample_count: rows.length(),
    bias: affine_mean(normalized).max(-1.0).min(1.0) * maximum,
    mean_absolute_error: affine_mean(normalized.map(v => v.abs())).min(1.0) *
    maximum,
    root_mean_square_error: affine_mean(normalized.map(v => v * v))
    .min(1.0)
    .sqrt() *
    maximum,
    maximum_absolute_error: maximum,
    outside_fit_predictor_range_count: outside,
  }
}

///|
/// Fit an ordinary least-squares recorded relationship using fit rows only.
/// Evaluate disjoint holdout rows with the same exported scale/offset arithmetic.
/// No interpolation, weighting by elapsed time, outlier removal or threshold verdict.
///
/// ```mbt check
/// test {
///   let recipe : @telemetry_csv.AffineRecipe = {
///     predictor: "x",
///     response: "y",
///     predictor_unit: "raw",
///     response_unit: "N",
///     output_channel: "predicted.n",
///     fit_start_ms: 0L,
///     fit_end_ms: 2L,
///     holdout_start_ms: 3L,
///     holdout_end_ms: 3L,
///   }
///   let fit = @telemetry_csv.fit_affine_csv(
///     "timestamp_ms,x,y\n0,0,1\n1,1,3\n2,2,5\n3,3,8\n", recipe,
///   ).unwrap()
///   assert_true((fit.scale - 2.0).abs() < 1.0e-12)
///   assert_true((fit.holdout_summary.mean_absolute_error - 1.0).abs() < 1.0e-12)
/// }
/// ```
pub fn fit_affine_csv(
  text : String,
  recipe : AffineRecipe,
) -> Result[AffineFit, String] {
  let source = match parse(text) {
    Ok(value) => value
    Err(message) => return Err(message)
  }
  if recipe.predictor == recipe.response {
    return Err("predictor and response must be different channels")
  }
  guard source.channels.search(recipe.predictor) is Some(x_index) else {
    return Err("unknown predictor channel: " + recipe.predictor)
  }
  guard source.channels.search(recipe.response) is Some(y_index) else {
    return Err("unknown response channel: " + recipe.response)
  }
  if recipe.predictor_unit.trim().is_empty() ||
    recipe.response_unit.trim().is_empty() {
    return Err("both unit labels must be nonblank")
  }
  if !normalization_label_valid(recipe.output_channel) ||
    source.channels.contains(recipe.output_channel) {
    return Err("output_channel must be a valid new CSV channel name")
  }
  if recipe.fit_start_ms < 0L ||
    recipe.fit_end_ms < recipe.fit_start_ms ||
    recipe.holdout_start_ms < 0L ||
    recipe.holdout_end_ms < recipe.holdout_start_ms {
    return Err("each window requires 0 <= start <= end")
  }
  if !(recipe.fit_end_ms < recipe.holdout_start_ms ||
    recipe.holdout_end_ms < recipe.fit_start_ms) {
    return Err(
      "fit and holdout windows must be disjoint, including their endpoints",
    )
  }
  let fit = source.samples.filter(s => {
    s.timestamp_ms >= recipe.fit_start_ms && s.timestamp_ms <= recipe.fit_end_ms
  })
  let holdout = source.samples.filter(s => {
    s.timestamp_ms >= recipe.holdout_start_ms &&
    s.timestamp_ms <= recipe.holdout_end_ms
  })
  if fit.length() < 3 {
    return Err("fit window requires at least three observations")
  }
  if holdout.is_empty() {
    return Err("holdout window requires at least one observation")
  }
  let mut x_scale = 0.0
  let mut y_scale = 0.0
  let mut x_min = fit[0].values[x_index]
  let mut x_max = x_min
  for sample in fit {
    let x = sample.values[x_index]
    x_scale = x_scale.max(x.abs())
    y_scale = y_scale.max(sample.values[y_index].abs())
    x_min = x_min.min(x)
    x_max = x_max.max(x)
  }
  if x_min == x_max || x_scale == 0.0 {
    return Err("fit predictor is constant; affine scale is not identifiable")
  }
  let xs = fit.map(s => s.values[x_index] / x_scale)
  let ys = fit.map(s => {
    if y_scale == 0.0 {
      0.0
    } else {
      s.values[y_index] / y_scale
    }
  })
  let xm = affine_mean(xs)
  let ym = affine_mean(ys)
  let mut dx_scale = 0.0
  for x in xs {
    dx_scale = dx_scale.max((x - xm).abs())
  }
  if dx_scale == 0.0 || !affine_finite(dx_scale) {
    return Err("fit predictor variation is unresolved at binary64 precision")
  }
  let dx = xs.map(x => (x - xm) / dx_scale)
  let numerator = affine_mean(
    Array::makei(fit.length(), i => dx[i] * (ys[i] - ym)),
  )
  let denominator = affine_mean(dx.map(x => x * x))
  let normalized_slope = numerator / denominator / dx_scale
  let scale = if normalized_slope == 0.0 {
    0.0
  } else {
    normalized_slope * (y_scale / x_scale)
  }
  let offset = (ym - normalized_slope * xm) * y_scale
  if !affine_finite(scale) || !affine_finite(offset) {
    return Err(
      "affine coefficients are not representable as finite binary64 values",
    )
  }
  // Qualify the exported recipe through the actual existing normalizer, including
  // excluded rows. This does not apply it anywhere or replace the original input.
  let mapping : ChannelMapping = {
    source: recipe.predictor,
    target: recipe.output_channel,
    scale,
    offset,
    source_unit: recipe.predictor_unit,
    target_unit: recipe.response_unit,
  }
  let normalized = match normalize_csv(text, [mapping]) {
    Ok(value) => value
    Err(message) => return Err("candidate normalization: " + message)
  }
  let rows : Array[AffineRow] = []
  for index, sample in source.samples {
    let timestamp = sample.timestamp_ms
    let partition = if timestamp >= recipe.fit_start_ms &&
      timestamp <= recipe.fit_end_ms {
      "fit"
    } else if timestamp >= recipe.holdout_start_ms &&
      timestamp <= recipe.holdout_end_ms {
      "holdout"
    } else {
      continue
    }
    let predicted = normalized.recording.samples[index].values[x_index]
    let residual = sample.values[y_index] - predicted
    if !affine_finite(residual) {
      return Err("residual arithmetic overflow at source sample \{index}")
    }
    let predictor = sample.values[x_index]
    rows.push({
      source_sample_index: index,
      timestamp_ms: timestamp,
      partition,
      predictor,
      observed: sample.values[y_index],
      predicted,
      residual,
      outside_fit_predictor_range: predictor < x_min || predictor > x_max,
    })
  }
  Ok({
    format: "moonrobo.recorded-affine-fit.v1",
    method: "ordinary-least-squares-intercept-equal-weight-per-fit-observation",
    scope: "recorded-relationship-only-no-calibration-readiness-or-control",
    residual_direction: "observed-minus-predicted",
    recipe,
    scale,
    offset,
    fit_predictor_minimum: x_min,
    fit_predictor_maximum: x_max,
    fit_summary: affine_summary(rows.filter(r => r.partition == "fit")),
    holdout_summary: affine_summary(rows.filter(r => r.partition == "holdout")),
    excluded_sample_count: source.samples.length() - rows.length(),
    source,
    rows,
  })
}
