///|
/// One disposition for every original sample; segment is absent on excluded rows.
pub(all) struct ExclusionRow {
  source_sample_index : Int
  disposition : String
  interval_ids : Array[String]
  segment : Int?
} derive(Debug, Eq, ToJson)

///|
pub(all) struct ExclusionCoverage {
  interval_id : String
  matched_sample_count : Int
  crossed_boundary_count : Int
} derive(Debug, Eq, ToJson)

///|
/// A new retained segment can follow excluded observations, an annotated
/// interval with no observation, a large source gap, or both interval and gap.
pub(all) struct ExclusionBoundary {
  previous_retained_source_index : Int
  next_retained_source_index : Int
  interval_ids : Array[String]
  exceeds_max_gap : Bool
} derive(Debug, Eq, ToJson)

///|
pub(all) struct ExclusionSegment {
  index : Int
  first_source_sample_index : Int
  last_source_sample_index : Int
  start_ms : Int64
  end_ms : Int64
  sample_count : Int
} derive(Debug, Eq, ToJson)

///|
pub(all) struct TelemetryExclusion {
  format : String
  timebase : String
  interval_semantics : String
  annotation_scope : String
  recipe : ExclusionRecipe
  source : Recording
  retained_sample_count : Int
  excluded_sample_count : Int
  rows : Array[ExclusionRow]
  coverage : Array[ExclusionCoverage]
  segments : Array[ExclusionSegment]
  boundaries : Array[ExclusionBoundary]
} derive(Debug, Eq, ToJson)

///|
/// Preview a non-destructive edit of numeric telemetry by closed time intervals.
/// Every original row is preserved. Every retained segment is split at excluded
/// intervals, even when an interval falls strictly between observed samples,
/// and at adjacent retained timestamps farther apart than max_gap_ms.
/// Empty interval lists are allowed; all-excluded input remains reviewable.
/// This is an annotation-based selection, not automated corruption detection.
///
/// ```mbt check
/// test {
///   let recipe : @telemetry_csv.ExclusionRecipe = {
///     editor_label: "review draft",
///     max_gap_ms: 100L,
///     intervals: [{ id: "spike", start_ms: 10L, end_ms: 10L, reason: "fixture", }],
///   }
///   let edited = @telemetry_csv.exclude_csv(
///     "timestamp_ms,x\n0,1\n10,99\n20,2\n", recipe,
///   ).unwrap()
///   assert_eq(edited.retained_sample_count, 2)
///   assert_eq(edited.segments.length(), 2)
///   assert_true(edited.to_csv() is Err(_))
///   assert_eq(edited.to_csv(segment=1).unwrap(), "timestamp_ms,x\n20,2\n")
/// }
/// ```
pub fn exclude_csv(
  text : String,
  recipe : ExclusionRecipe,
) -> Result[TelemetryExclusion, String] {
  match validate_exclusion_recipe(recipe) {
    Err(message) => return Err(message)
    Ok(_) => ()
  }
  if text.length() > 4194304 {
    return Err("exclusion input exceeds 4 Mi UTF-16 units")
  }
  let source = match parse(text) {
    Ok(value) => value
    Err(message) => return Err(message)
  }
  if source.samples.length() > 100000 {
    return Err("source exceeds 100000 samples")
  }
  let matched = Array::make(recipe.intervals.length(), 0)
  let crossed = Array::make(recipe.intervals.length(), 0)
  let rows : Array[ExclusionRow] = []
  let segments : Array[ExclusionSegment] = []
  let boundaries : Array[ExclusionBoundary] = []
  let mut previous : Int? = None
  let mut retained = 0
  for source_sample_index, sample in source.samples {
    let interval_ids : Array[String] = []
    for i, interval in recipe.intervals {
      if sample.timestamp_ms >= interval.start_ms &&
        sample.timestamp_ms <= interval.end_ms {
        interval_ids.push(interval.id)
        matched[i] += 1
      }
    }
    if !interval_ids.is_empty() {
      rows.push({
        source_sample_index,
        disposition: "excluded",
        interval_ids,
        segment: None,
      })
      continue
    }
    let mut starts_segment = previous is None
    if previous is Some(left_index) {
      let left = source.samples[left_index].timestamp_ms
      let ids : Array[String] = []
      for i, interval in recipe.intervals {
        if interval.start_ms < sample.timestamp_ms && interval.end_ms > left {
          ids.push(interval.id)
          crossed[i] += 1
        }
      }
      let exceeds_max_gap = sample.timestamp_ms - left > recipe.max_gap_ms
      if !ids.is_empty() || exceeds_max_gap {
        starts_segment = true
        boundaries.push({
          previous_retained_source_index: left_index,
          next_retained_source_index: source_sample_index,
          interval_ids: ids,
          exceeds_max_gap,
        })
      }
    }
    if starts_segment {
      segments.push({
        index: segments.length(),
        first_source_sample_index: source_sample_index,
        last_source_sample_index: source_sample_index,
        start_ms: sample.timestamp_ms,
        end_ms: sample.timestamp_ms,
        sample_count: 1,
      })
    } else {
      let last = segments[segments.length() - 1]
      segments[segments.length() - 1] = {
        ..last,
        last_source_sample_index: source_sample_index,
        end_ms: sample.timestamp_ms,
        sample_count: last.sample_count + 1,
      }
    }
    rows.push({
      source_sample_index,
      disposition: "retained",
      interval_ids: [],
      segment: Some(segments.length() - 1),
    })
    previous = Some(source_sample_index)
    retained += 1
  }
  let coverage : Array[ExclusionCoverage] = []
  for i, interval in recipe.intervals {
    coverage.push({
      interval_id: interval.id,
      matched_sample_count: matched[i],
      crossed_boundary_count: crossed[i],
    })
  }
  Ok({
    format: "moonrobo.telemetry-exclusion.v1",
    timebase: "milliseconds-as-recorded",
    interval_semantics: "closed intervals; union for row exclusion; all matching IDs retained",
    annotation_scope: "user-supplied labels and reasons; no authenticated review or physical safety decision",
    recipe,
    source,
    retained_sample_count: retained,
    excluded_sample_count: source.samples.length() - retained,
    rows,
    coverage,
    segments,
    boundaries,
  })
}
