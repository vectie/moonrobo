///|
pub(all) struct PlanarPosition {
  x : Double
  y : Double
} derive(Debug, Eq, ToJson)

///|
/// Indices are zero-based numeric sample indices in the preserved source.
/// A missing candidate is unknown, never (0,0). Brackets also identify gaps.
pub(all) struct PlanarRow {
  aligned_ms : Int64
  baseline_timestamp_ms : Int64
  baseline_sample_index : Int
  candidate_left_timestamp_ms : Int64?
  candidate_right_timestamp_ms : Int64?
  candidate_left_sample_index : Int?
  candidate_right_sample_index : Int?
  status : String
  baseline : PlanarPosition
  candidate : PlanarPosition?
  separation : Double?
  connected : Bool
} derive(Debug, Eq)

///|
pub(all) struct PlanarSummary {
  mean_separation : Double
  root_mean_square_separation : Double
  max_separation : Double
  max_separation_aligned_ms : Int64
} derive(Debug, Eq, ToJson)

///|
pub(all) struct PlanarComparison {
  format : String
  scope : String
  recipe : PlanarRecipe
  timebase : String
  baseline_origin_ms : Int64
  candidate_origin_ms : Int64
  start_ms : Int64
  end_ms : Int64
  max_gap_ms : Int64
  summary_weighting : String
  compared_count : Int
  interpolated_count : Int
  unmatched_count : Int
  summary : PlanarSummary?
  baseline_source : Recording
  candidate_source : Recording
  rows : Array[PlanarRow]
} derive(Debug, Eq)

///|
fn planar_projection(
  source : Recording,
  x : String,
  y : String,
) -> Result[Recording, String] {
  let xi = match source.channels.search(x) {
    Some(i) => i
    None => return Err("missing X channel: " + x)
  }
  let yi = match source.channels.search(y) {
    Some(i) => i
    None => return Err("missing Y channel: " + y)
  }
  Ok({
    channels: ["x", "y"],
    samples: source.samples.map(s => {
      timestamp_ms: s.timestamp_ms,
      values: [s.values[xi], s.values[yi]],
    }),
  })
}

///|
/// Coupled XY comparison at baseline times, using the existing bounded linear
/// alignment engine. Full numeric sources and Int64 clocks are preserved.
/// max_gap_ms bounds interpolation AND drawn connections; zero is points-only.
pub fn compare_planar_csv(
  baseline_text : String,
  candidate_text : String,
  recipe : PlanarRecipe,
  start_ms? : Int64 = 0L,
  end_ms? : Int64 = 9223372036854775807L,
  max_gap_ms? : Int64 = 0L,
) -> Result[PlanarComparison, String] {
  match validate_planar_recipe(recipe) {
    Err(e) => return Err(e)
    Ok(_) => ()
  }
  if start_ms < 0L || end_ms < start_ms || max_gap_ms < 0L {
    return Err("expected 0 <= start_ms <= end_ms and max_gap_ms >= 0")
  }
  let baseline_source = match parse(baseline_text) {
    Ok(v) => v
    Err(e) => return Err("baseline: " + e)
  }
  let candidate_source = match parse(candidate_text) {
    Ok(v) => v
    Err(e) => return Err("candidate: " + e)
  }
  let baseline = match
    planar_projection(baseline_source, recipe.baseline_x, recipe.baseline_y) {
    Ok(v) => v
    Err(e) => return Err("baseline: " + e)
  }
  let candidate = match
    planar_projection(candidate_source, recipe.candidate_x, recipe.candidate_y) {
    Ok(v) => v
    Err(e) => return Err("candidate: " + e)
  }
  let relative = recipe.alignment == "first-sample"
  let baseline_origin_ms = if relative {
    baseline.samples[0].timestamp_ms
  } else {
    0L
  }
  let candidate_origin_ms = if relative {
    candidate.samples[0].timestamp_ms
  } else {
    0L
  }
  let timebase = if relative {
    "milliseconds-since-each-recording-first-sample"
  } else {
    "absolute-recorded-milliseconds"
  }
  let comparison = match
    compare_recordings(
      baseline,
      candidate,
      baseline_origin_ms,
      candidate_origin_ms,
      start_ms~,
      end_ms~,
      max_gap_ms~,
      format="moonrobo.planar-comparison.v1",
      timebase~,
    ) {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  // Prefix counts prevent the overlay from bridging a candidate outage even
  // when exact observations exist on both sides and no baseline row is inside.
  let bad_prefix : Array[Int] = [0]
  for i in 1..<candidate.samples.length() {
    let outage = if candidate.samples[i].timestamp_ms -
      candidate.samples[i - 1].timestamp_ms >
      max_gap_ms {
      1
    } else {
      0
    }
    bad_prefix.push(bad_prefix[i - 1] + outage)
  }
  let rows : Array[PlanarRow] = []
  let mut match_cursor = 0
  let mut gap_cursor = 0
  let mut cursor = 0
  let mut mean = 0.0
  let mut maximum = 0.0
  let mut maximum_time = 0L
  let mut count = 0
  for i, sample in baseline.samples {
    let aligned_ms = sample.timestamp_ms - baseline_origin_ms
    if aligned_ms < start_ms || aligned_ms > end_ms {
      continue
    }
    while cursor < candidate.samples.length() &&
          candidate.samples[cursor].timestamp_ms - candidate_origin_ms <
          aligned_ms {
      cursor += 1
    }
    let right = if cursor < candidate.samples.length() {
      Some(cursor)
    } else {
      None
    }
    let exact = cursor < candidate.samples.length() &&
      candidate.samples[cursor].timestamp_ms - candidate_origin_ms == aligned_ms
    let left = if exact {
      Some(cursor)
    } else if cursor > 0 {
      Some(cursor - 1)
    } else {
      None
    }
    let mut paired : PlanarPosition? = None
    let mut separation : Double? = None
    let mut connected = false
    let status = if match_cursor < comparison.samples.length() &&
      comparison.samples[match_cursor].baseline_timestamp_ms ==
      sample.timestamp_ms {
      let s = comparison.samples[match_cursor]
      match_cursor += 1
      let dx = s.delta[0].abs()
      let dy = s.delta[1].abs()
      let scale = dx.max(dy)
      let distance = if scale == 0.0 {
        0.0
      } else {
        scale * (dx / scale * (dx / scale) + dy / scale * (dy / scale)).sqrt()
      }
      if distance.is_nan() || distance.is_inf() {
        return Err("Euclidean separation exceeds finite range")
      }
      paired = Some({ x: s.candidate[0], y: s.candidate[1], })
      separation = Some(distance)
      count += 1
      mean = mean * ((count - 1).to_double() / count.to_double()) +
        distance / count.to_double()
      if count == 1 || distance > maximum {
        maximum = distance
        maximum_time = aligned_ms
      }
      if rows.last() is Some(previous) &&
        previous.candidate is Some(_) &&
        sample.timestamp_ms - previous.baseline_timestamp_ms <= max_gap_ms {
        if previous.candidate_left_sample_index is Some(a) && right is Some(b) {
          connected = bad_prefix[a] == bad_prefix[b]
        }
      }
      if s.interpolated {
        "interpolated"
      } else {
        "exact"
      }
    } else {
      let reason = comparison.gaps[gap_cursor].reason
      gap_cursor += 1
      reason
    }
    rows.push({
      aligned_ms,
      baseline_timestamp_ms: sample.timestamp_ms,
      baseline_sample_index: i,
      candidate_left_timestamp_ms: left.map(j => {
        candidate.samples[j].timestamp_ms
      }),
      candidate_right_timestamp_ms: right.map(j => {
        candidate.samples[j].timestamp_ms
      }),
      candidate_left_sample_index: left,
      candidate_right_sample_index: right,
      status,
      baseline: { x: sample.values[0], y: sample.values[1], },
      candidate: paired,
      separation,
      connected,
    })
  }
  if rows.is_empty() {
    return Err("selected window contains no baseline positions")
  }
  let mut squares = 0.0
  if maximum > 0.0 {
    for row in rows {
      if row.separation is Some(d) {
        let scaled = d / maximum
        squares += scaled * scaled
      }
    }
  }
  let summary = if count == 0 {
    None
  } else {
    Some({
      mean_separation: mean,
      root_mean_square_separation: maximum *
      (squares / count.to_double()).sqrt(),
      max_separation: maximum,
      max_separation_aligned_ms: maximum_time,
    })
  }
  Ok({
    format: "moonrobo.planar-comparison.v1",
    scope: "offline-declared-comparable-XY-observations-only",
    recipe,
    timebase,
    baseline_origin_ms,
    candidate_origin_ms,
    start_ms,
    end_ms,
    max_gap_ms,
    summary_weighting: "equal-weight-per-paired-baseline-sample-no-time-weighting",
    compared_count: count,
    interpolated_count: comparison.interpolated_count,
    unmatched_count: comparison.unmatched_count,
    summary,
    baseline_source,
    candidate_source,
    rows,
  })
}
