///|
pub(all) struct Direction {
  initial_derivative : Double
  corrected_derivative : Double
  physics_derivatives : Array[Double]
} derive(Debug, ToJson, FromJson)

///|
pub(all) struct Ascent {
  plus_return_change : Double
} derive(Debug, ToJson, FromJson)

///|
pub(all) struct Translation {
  physical_equivariance_error : Double
  normalized_model_equivariance_mse : Double
} derive(Debug, ToJson, FromJson)

///|
pub(all) struct ModelResult {
  model : String
  normalized_mse : Double
  predicted_return : Double
  ascent_physics : Array[Ascent]
  translation_checks : Array[Translation]
} derive(Debug, ToJson, FromJson)

///|
pub(all) struct Record {
  horizon : Int32
  start_time_s : Double
  physical_return : Double
  models : Array[ModelResult]
  directions : Array[Direction]
} derive(Debug, ToJson, FromJson)

///|
pub(all) struct ModelSummary {
  horizon : Int32
  model : String
  time_group : String
  snapshots : Int32
  directions : Int32
  ascent_snapshots : Int32
  translation_checks : Int32
  maximum_physical_equivariance_error : Double?
  mean_normalized_model_equivariance_mse : Double?
  mean_normalized_mse : Double?
  mean_return_absolute_error : Double?
  sign_agreement : Double?
  sign_agreement_by_epsilon : Array[Double?]
  ascent_improves_fraction_by_epsilon : Array[Double?]
  mean_ascent_return_change_by_epsilon : Array[Double?]
  fd_sign_agreement_between_scales : Double?
  physical_fd_scale_disagreement : Double?
} derive(Debug, ToJson)

///|
fn mean(values : Array[Double]) -> Double? {
  if values.is_empty() {
    None
  } else {
    let mut total = 0.0
    for x in values {
      total += x
    }
    Some(total / values.length().to_double())
  }
}

///|
fn fraction(values : Array[Bool]) -> Double? {
  mean(values.map(v => if v { 1.0 } else { 0.0 }))
}

///|
/// Empty windows remain null; zero gradients are excluded from ascent denominators.
pub fn summarize(
  records : Array[Record],
  horizon : Int32,
  time_group : String,
  epsilon_count : Int32,
) -> Array[ModelSummary] raise ProbeError {
  if epsilon_count < 2 {
    raise Invalid("summary requires at least two finite-difference scales")
  }
  let subset = records.filter(r => {
    r.horizon == horizon &&
    (
      time_group == "all" ||
      (r.start_time_s >= 2) == (time_group == "after-two-seconds")
    )
  })
  let summaries : Array[ModelSummary] = []
  for label in ["initial", "corrected"] {
    let selected : Array[ModelResult] = []
    let pairs : Array[(Double, Array[Double])] = []
    let ascents : Array[Array[Ascent]] = []
    let translations : Array[Translation] = []
    for r in subset {
      guard r.models.filter(m => m.model == label).get(0) is Some(m) else {
        raise Invalid("record missing model " + label)
      }
      selected.push(m)
      if !m.ascent_physics.is_empty() {
        if m.ascent_physics.length() != epsilon_count {
          raise Invalid("ascent epsilon width differs")
        }
        ascents.push(m.ascent_physics)
      }
      translations.append(m.translation_checks)
      for d in r.directions {
        if d.physics_derivatives.length() != epsilon_count {
          raise Invalid("direction epsilon width differs")
        }
        pairs.push(
          (
            if label == "initial" {
              d.initial_derivative
            } else {
              d.corrected_derivative
            },
            d.physics_derivatives,
          ),
        )
      }
    }
    let mut maximum : Double? = None
    for t in translations {
      maximum = Some(
        match maximum {
          None => t.physical_equivariance_error
          Some(m) =>
            if t.physical_equivariance_error > m {
              t.physical_equivariance_error
            } else {
              m
            }
        },
      )
    }
    let errors = Array::makei(selected.length(), i => {
      (selected[i].predicted_return - subset[i].physical_return).abs()
    })
    summaries.push({
      horizon,
      model: label,
      time_group,
      snapshots: subset.length(),
      directions: pairs.length(),
      ascent_snapshots: ascents.length(),
      translation_checks: translations.length(),
      maximum_physical_equivariance_error: maximum,
      mean_normalized_model_equivariance_mse: mean(
        translations.map(t => t.normalized_model_equivariance_mse),
      ),
      mean_normalized_mse: mean(selected.map(m => m.normalized_mse)),
      mean_return_absolute_error: mean(errors),
      sign_agreement: fraction(pairs.map(p => p.0 * p.1[0] > 0)),
      sign_agreement_by_epsilon: Array::makei(epsilon_count, i => {
        fraction(pairs.map(p => p.0 * p.1[i] > 0))
      }),
      ascent_improves_fraction_by_epsilon: Array::makei(epsilon_count, i => {
        fraction(ascents.map(a => a[i].plus_return_change > 0))
      }),
      mean_ascent_return_change_by_epsilon: Array::makei(epsilon_count, i => {
        mean(ascents.map(a => a[i].plus_return_change))
      }),
      fd_sign_agreement_between_scales: fraction(
        pairs.map(p => p.1[0] * p.1[1] > 0),
      ),
      physical_fd_scale_disagreement: mean(
        pairs.map(p => (p.1[0] - p.1[1]).abs()),
      ),
    })
  }
  summaries
}
