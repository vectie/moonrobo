///|
fn event_compare(
  left : String,
  right : String,
  baseline_episode? : Int = 0,
  candidate_episode? : Int = 0,
  before_ms? : Int64 = 1000L,
  after_ms? : Int64 = 1000L,
  event_min_span_ms? : Int64 = 0L,
  event_max_gap_ms? : Int64 = 1000L,
  max_gap_ms? : Int64 = 0L,
  direction? : String = "above",
  threshold? : Double = 0.5,
  channels? : Array[String] = ["x"],
) -> Result[@telemetry_csv.EventComparison, String] {
  @telemetry_csv.compare_event_csv(
    left,
    right,
    "event",
    direction,
    threshold,
    baseline_episode~,
    candidate_episode~,
    before_ms~,
    after_ms~,
    event_min_span_ms~,
    event_max_gap_ms~,
    max_gap_ms~,
    channels~,
  )
}

///|
test "event registration aligns selected episodes and signed pre event observations" {
  let left = "timestamp_ms,event,x\n100,0,1\n200,1,2\n300,1,3\n400,0,4"
  let right = "timestamp_ms,x,event\n500,9,1\n600,0,0\n700,2,0\n800,3,1\n900,4,1\n1000,5,0"
  let result = event_compare(left, right, candidate_episode=1).unwrap()
  assert_eq(result.format, "moonrobo.observed-event-comparison.v1")
  assert_eq(result.baseline_anchor.episode.first_sample_position, 1)
  assert_eq(result.candidate_anchor.episode.first_sample_position, 3)
  assert_eq(result.candidate_anchor.episode_index, 1)
  assert_eq(result.candidate_anchor.qualifying_episode_count, 2)
  assert_eq(result.candidate_anchor.source_value, 1.0)
  let c = result.comparison
  assert_eq(c.baseline_origin_ms, 200L)
  assert_eq(c.candidate_origin_ms, 800L)
  assert_eq(c.samples.map(x => x.elapsed_ms), [-100L, 0L, 100L, 200L])
  assert_eq(c.samples[0].baseline_timestamp_ms, 100L)
  assert_eq(c.samples[0].candidate_left_timestamp_ms, 700L)
  assert_eq(c.summaries[0].mean_delta, 1.0)
  assert_eq(c.summaries[0].max_absolute_elapsed_ms, -100L)
  assert_true(result.to_csv().contains("-100,100,700,700,exact,\"x\",1,2,1"))
}

///|
test "event anchor selection is before window and after episode filters" {
  let input = "timestamp_ms,event,x\n0,1,9\n10,0,0\n20,1,2\n30,1,3\n40,0,4"
  let r = event_compare(
    input,
    input,
    event_min_span_ms=10L,
    event_max_gap_ms=10L,
    before_ms=0L,
    after_ms=0L,
  ).unwrap()
  assert_eq(r.baseline_anchor.qualifying_episode_count, 1)
  assert_eq(r.baseline_anchor.episode.first_timestamp_ms, 20L)
  assert_eq(r.baseline_anchor.episode.observed_span_ms, 10L)
  assert_eq(r.baseline_anchor.episode.sample_count, 2)
  assert_eq(r.comparison.samples.length(), 1)
  assert_eq(r.comparison.samples[0].elapsed_ms, 0L)
}

///|
test "event equality and observation gaps split episodes without inferred crossing" {
  let input = "timestamp_ms,event,x\n0,0,0\n10,0.5,1\n20,1,2\n30,1,3\n50,1,5\n60,0.5,6\n70,1,7"
  let r = event_compare(
    input,
    input,
    baseline_episode=1,
    candidate_episode=2,
    event_max_gap_ms=10L,
    before_ms=0L,
    after_ms=0L,
  ).unwrap()
  assert_eq(r.baseline_anchor.qualifying_episode_count, 3)
  assert_eq(r.baseline_anchor.episode.first_timestamp_ms, 50L)
  assert_eq(r.candidate_anchor.episode.first_timestamp_ms, 70L)
  assert_eq(r.comparison.samples[0].delta, [2.0])
}

///|
test "below threshold event registration preserves actual anchor value" {
  let input = "timestamp_ms,event,x\n0,1,0\n10,0.5,1\n20,-2,2\n30,-3,3"
  let r = event_compare(input, input, direction="below", event_min_span_ms=10L).unwrap()
  assert_eq(r.baseline_anchor.episode.first_timestamp_ms, 20L)
  assert_eq(r.baseline_anchor.source_value, -2.0)
  assert_eq(r.baseline_anchor.episode.minimum, -3.0)
}

///|
test "candidate absent prehistory and tail are explicit gaps never extrapolated" {
  let left = "timestamp_ms,event,x\n0,0,0\n10,0,1\n20,1,2\n30,1,3\n40,0,4"
  let right = "timestamp_ms,event,x\n100,1,2\n110,0,3"
  let r = event_compare(left, right, max_gap_ms=1000L).unwrap().comparison
  assert_eq(r.compared_count, 2)
  assert_eq(r.gaps.map(g => g.elapsed_ms), [-20L, -10L, 20L])
  assert_true(r.gaps.all(g => g.reason == "outside-candidate-range"))
}

///|
test "event comparison interpolates negative and positive elapsed only within gap limit" {
  let left = "timestamp_ms,event,x\n0,0,0\n10,0,1\n20,1,2\n30,1,3\n40,0,4"
  let right = "timestamp_ms,event,x\n100,0,1\n120,1,3\n140,0,5"
  let exact = event_compare(left, right).unwrap().comparison
  assert_eq(exact.compared_count, 3)
  assert_eq(exact.gaps.map(g => g.elapsed_ms), [-10L, 10L])
  assert_true(exact.gaps.all(g => g.reason == "candidate-gap-exceeds-limit"))
  let r = event_compare(left, right, max_gap_ms=20L).unwrap().comparison
  assert_eq(r.compared_count, 5)
  assert_eq(r.interpolated_count, 2)
  assert_eq(r.samples[1].candidate_left_timestamp_ms, 100L)
  assert_eq(r.samples[1].candidate_right_timestamp_ms, 120L)
  assert_eq(r.samples[1].candidate, [2.0])
  assert_eq(r.summaries[0].mean_delta, 1.0)
  assert_eq(
    event_compare(left, right, max_gap_ms=19L).unwrap().comparison.compared_count,
    3,
  )
}

///|
test "event channel is independent from explicitly ordered comparison channels" {
  let left = "timestamp_ms,event,x,y\n0,1,2,3"
  let right = "timestamp_ms,y,x,event\n10,5,6,2"
  let r = event_compare(left, right, channels=["y", "x"]).unwrap()
  assert_eq(r.comparison.channels, ["y", "x"])
  assert_eq(r.comparison.samples[0].delta, [2.0, 4.0])
  assert_eq(r.candidate_anchor.source_value, 2.0)
  let defaults = @telemetry_csv.compare_event_csv(
    left,
    right,
    "event",
    "above",
    0.5,
    baseline_episode=0,
    candidate_episode=0,
    before_ms=0L,
    after_ms=0L,
    event_min_span_ms=0L,
    event_max_gap_ms=0L,
    max_gap_ms=0L,
  ).unwrap()
  assert_eq(defaults.comparison.channels, ["event", "x", "y"])
}

///|
test "missing or filtered episodes are errors and never fallback to run start" {
  let yes = "timestamp_ms,event,x\n0,1,2"
  let no = "timestamp_ms,event,x\n0,0,2"
  assert_true(event_compare(no, yes) is Err(_))
  assert_true(event_compare(yes, no) is Err(_))
  assert_true(event_compare(yes, yes, baseline_episode=1) is Err(_))
  assert_true(event_compare(yes, yes, candidate_episode=1) is Err(_))
  assert_true(event_compare(yes, yes, event_min_span_ms=1L) is Err(_))
}

///|
test "event registration validates every source row including outside selected window" {
  let input = "timestamp_ms,event,x\n0,1,2"
  assert_true(
    event_compare(input + "\n1,0,bad", input, before_ms=0L, after_ms=0L)
    is Err(_),
  )
  assert_true(
    event_compare(input, input + "\n1,0,NaN", before_ms=0L, after_ms=0L)
    is Err(_),
  )
  assert_true(event_compare(input, "timestamp_ms,x\n0,2") is Err(_))
  assert_true(event_compare(input, input, channels=["missing"]) is Err(_))
  assert_true(event_compare(input, input, channels=["x", "x"]) is Err(_))
  assert_true(event_compare(input, input, channels=[]) is Err(_))
}

///|
test "event registration rejects invalid bounds selectors and finite threshold" {
  let input = "timestamp_ms,event,x\n0,1,2"
  assert_true(event_compare(input, input, baseline_episode=-1) is Err(_))
  assert_true(event_compare(input, input, candidate_episode=-1) is Err(_))
  assert_true(event_compare(input, input, before_ms=-1L) is Err(_))
  assert_true(event_compare(input, input, after_ms=-1L) is Err(_))
  assert_true(event_compare(input, input, max_gap_ms=-1L) is Err(_))
  assert_true(event_compare(input, input, event_min_span_ms=-1L) is Err(_))
  assert_true(event_compare(input, input, event_max_gap_ms=-1L) is Err(_))
  assert_true(event_compare(input, input, direction="equal") is Err(_))
  assert_true(event_compare(input, input, threshold=1.0 / 0.0) is Err(_))
}

///|
test "event registration retains signed Int64 extremes without shifted timestamp overflow" {
  let left = "timestamp_ms,event,x\n0,0,1\n9223372036854775807,1,2"
  let right = "timestamp_ms,event,x\n0,1,3\n9223372036854775807,0,4"
  let r = event_compare(
      left,
      right,
      before_ms=9223372036854775807L,
      after_ms=9223372036854775807L,
    ).unwrap().comparison
  assert_eq(r.gaps[0].elapsed_ms, -9223372036854775807L)
  assert_eq(r.samples[0].delta, [1.0])
  assert_eq(r.baseline_origin_ms, 9223372036854775807L)
  let reverse = event_compare(
      right,
      left,
      before_ms=9223372036854775807L,
      after_ms=9223372036854775807L,
    ).unwrap().comparison
  assert_eq(reverse.gaps[0].elapsed_ms, 9223372036854775807L)
  assert_eq(reverse.samples[0].delta, [-1.0])
  assert_true(r.to_json().stringify().contains("\"-9223372036854775807\""))
}

///|
test "event registration preserves large exact clocks and rejects numeric delta overflow" {
  let left = "timestamp_ms,event,x\n9007199254740993,0,1\n9007199254740994,1,2"
  let right = "timestamp_ms,event,x\n9223372036854775806,0,2\n9223372036854775807,1,3"
  let r = event_compare(left, right).unwrap().comparison
  assert_eq(r.samples[0].elapsed_ms, -1L)
  assert_eq(r.samples[0].candidate_left_timestamp_ms, 9223372036854775806L)
  assert_eq(r.samples[1].delta, [1.0])
  assert_true(
    event_compare(
      "timestamp_ms,event,x\n0,1,-1e308", "timestamp_ms,event,x\n0,1,1e308",
    )
    is Err(_),
  )
}
