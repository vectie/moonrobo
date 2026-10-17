///|
fn response_fixture() -> String {
  "timestamp_ms,trigger,load.n,temperature.c\n1000,0,0,20\n1100,1,2,21\n1200,1,4,22\n1300,0,2,21\n2000,0,0,20\n2100,1,4,22\n2300,0,8,24\n3000,0,0,20\n3100,1,6,23\n3400,0,0,20\n"
}

///|
fn responses(
  text? : String = response_fixture(),
  episodes? : Array[Int] = [0, 1, 2],
  channels? : Array[String] = ["load.n", "temperature.c"],
  units? : Array[String] = ["N", "C"],
  before? : Int64 = 100L,
  after? : Int64 = 200L,
  step? : Int64 = 100L,
  min_span? : Int64 = 0L,
  event_gap? : Int64 = 250L,
  gap? : Int64 = 200L,
  overlap? : String = "reject",
) -> Result[@telemetry_csv.EventResponses, String] {
  @telemetry_csv.event_responses_csv(
    text,
    "trigger",
    "above",
    0.5,
    episodes~,
    channels~,
    unit_labels=units,
    before_ms=before,
    after_ms=after,
    step_ms=step,
    event_min_span_ms=min_span,
    event_max_gap_ms=event_gap,
    max_gap_ms=gap,
    overlap_policy=overlap,
  )
}

///|
test "repeated response means use supported episodes rather than raw cadence" {
  let r = responses().unwrap()
  assert_eq(r.events.episodes.length(), 3)
  assert_eq(r.trials.map(t => t.anchor.first_timestamp_ms), [
    1100L, 2100L, 3100L,
  ])
  assert_eq(r.summaries.map(s => s.offset_ms), [-100L, 0L, 100L, 200L])
  assert_eq(r.summaries[0].mean, Some([0.0, 20.0]))
  assert_eq(r.summaries[1].mean, Some([4.0, 22.0]))
  assert_eq(r.summaries[1].minimum, Some([2.0, 21.0]))
  assert_eq(r.summaries[1].maximum, Some([6.0, 23.0]))
  assert_eq(r.summaries[2].mean, Some([5.0, 22.5]))
  assert_eq(r.summaries[2].supported_episode_indices, [0, 1])
  assert_eq(r.summaries[2].exact_count, 1)
  assert_eq(r.summaries[2].interpolated_count, 1)
  assert_eq(r.summaries[2].missing_count, 1)
  assert_eq(r.summaries[3].mean, Some([5.0, 22.5]))
}

///|
test "repeated response interpolation and exclusions retain original brackets" {
  let r = responses().unwrap()
  let p = r.trials[1].points[2]
  assert_eq(p.status, "interpolated")
  assert_eq(p.timestamp_ms, Some(2200L))
  assert_eq(p.left_sample_index, Some(5))
  assert_eq(p.right_sample_index, Some(6))
  assert_eq(p.left_timestamp_ms, Some(2100L))
  assert_eq(p.right_timestamp_ms, Some(2300L))
  assert_eq(p.right_weight, Some(0.5))
  assert_eq(p.values, Some([6.0, 23.0]))
  let missing = r.trials[2].points[2]
  assert_eq(missing.status, "source-gap-exceeds-limit")
  assert_eq(missing.left_sample_index, Some(8))
  assert_eq(missing.right_sample_index, Some(9))
  assert_eq(missing.values, None)
  assert_eq(r.source.samples[5].values, [1.0, 4.0, 22.0])
}

///|
test "exact response observations survive gaps but do not reconnect segments" {
  let r = responses(episodes=[2], after=300L).unwrap()
  assert_eq(r.trials[0].points[2].values, None)
  assert_eq(r.trials[0].points[3].values, None)
  assert_eq(r.trials[0].points[4].status, "exact")
  assert_true(
    r.trials[0].points[1].source_segment != r.trials[0].points[4].source_segment,
  )
  let exact = responses(gap=0L).unwrap()
  assert_eq(exact.trials[1].points[2].status, "source-gap-exceeds-limit")
  assert_eq(exact.summaries[1].exact_count, 3)
}

///|
test "requested response offsets remain present before and after capture" {
  let r = responses(episodes=[0], before=2000L, after=3000L).unwrap()
  assert_eq(r.trials[0].points.length(), 51)
  assert_eq(r.trials[0].points[0].status, "outside-timestamp-domain")
  assert_eq(r.trials[0].points[0].timestamp_ms, None)
  assert_eq(r.trials[0].points[11].status, "outside-source-range")
  assert_eq(r.trials[0].points[11].timestamp_ms, Some(200L))
  assert_eq(r.trials[0].points[50].status, "outside-source-range")
  assert_eq(r.summaries[0].supported_episode_indices, [])
  assert_eq(r.summaries[0].missing_count, 1)
  assert_eq(r.summaries[0].mean, None)
}

///|
test "episode selection preserves caller order and filtered episode numbering" {
  let r = responses(episodes=[2, 0]).unwrap()
  assert_eq(r.trials.map(t => t.episode_index), [2, 0])
  assert_eq(r.summaries[1].supported_episode_indices, [2, 0])
  assert_eq(r.summaries[2].supported_episode_indices, [0])
  let filtered = responses(episodes=[0], min_span=100L).unwrap()
  assert_eq(filtered.events.episodes.length(), 1)
  assert_eq(filtered.trials[0].anchor.first_timestamp_ms, 1100L)
  assert_true(responses(episodes=[1], min_span=100L) is Err(_))
}

///|
test "overlapping event windows require an explicit dependent-observation choice" {
  assert_true(responses(episodes=[0, 1], after=1000L) is Err(_))
  let r = responses(
    episodes=[0, 1],
    after=1000L,
    overlap="allow-shared-observations",
  ).unwrap()
  assert_eq(r.overlaps.length(), 1)
  assert_eq(r.overlaps[0].first_episode_index, 0)
  assert_eq(r.overlaps[0].second_episode_index, 1)
  assert_eq(r.trials.length(), 2)
  // An endpoint shared by closed windows counts as overlap too.
  assert_true(responses(episodes=[0, 1], after=900L) is Err(_))
  assert_true(responses(episodes=[0, 1], after=800L) is Ok(_))
}

///|
test "response selections and units are explicit and bounded" {
  assert_true(responses(episodes=[]) is Err(_))
  assert_true(responses(episodes=[0, 0]) is Err(_))
  assert_true(responses(episodes=[-1]) is Err(_))
  assert_true(responses(episodes=[3]) is Err(_))
  assert_true(responses(channels=["missing"], units=["N"]) is Err(_))
  assert_true(responses(channels=["load.n", "load.n"]) is Err(_))
  assert_true(responses(units=["N"]) is Err(_))
  assert_true(responses(units=["", "C"]) is Err(_))
  assert_true(responses(units=["N\n", "C"]) is Err(_))
  assert_true(responses(overlap="auto") is Err(_))
}

///|
test "response grids reject ambiguous nonzero alignment overflow and excessive work" {
  assert_true(responses(step=0L) is Err(_))
  assert_true(responses(before=-1L) is Err(_))
  assert_true(responses(before=101L) is Err(_))
  assert_true(responses(after=201L) is Err(_))
  assert_true(responses(before=9223372036854775807L, after=1L) is Err(_))
  assert_true(responses(before=1000100L) is Err(_))
  assert_true(responses(gap=-1L) is Err(_))
  assert_true(responses(event_gap=-1L) is Err(_))
  assert_true(responses(min_span=-1L) is Err(_))
}

///|
test "response processing validates all source rows and unselected channels" {
  assert_true(
    responses(text=response_fixture() + "9000,0,3,NaN\n", episodes=[0])
    is Err(_),
  )
  assert_true(
    responses(text=response_fixture() + "3400,0,3,20\n", episodes=[0]) is Err(_),
  )
  assert_true(
    responses(text="timestamp_ms,trigger,load.n,temperature.c\n1000,0,1,20\n")
    is Err(_),
  )
}

///|
test "raw response clip reopens without estimated grid values or channel loss" {
  let r = responses().unwrap()
  let clip = r.clip_csv(1).unwrap()
  let reopened = @telemetry_csv.parse(clip).unwrap()
  assert_eq(reopened.channels, r.source.channels)
  assert_eq(reopened.samples.map(s => s.timestamp_ms), [2000L, 2100L, 2300L])
  assert_eq(reopened.samples[2].values, [0.0, 8.0, 24.0])
  assert_true(!clip.contains("2200"))
  assert_true(r.clip_csv(8) is Err(_))
  let explored = @telemetry_csv.explore_csv(clip).unwrap()
  assert_eq(explored.sample_count, 3)
  assert_eq(explored.summaries[1].maximum, 8.0)
}

///|
test "response review CSV retains missing cells source anchors and support" {
  let r = responses(units=["N,\"review\"", "C"]).unwrap()
  let csv = r.to_csv()
  assert_eq(csv.split("\n").count(), 26)
  assert_true(
    csv.contains(
      "1,2100,100,2200,interpolated,\"load.n\",\"N,\"\"review\"\"\",",
    ),
  )
  assert_true(csv.contains("2,3100,100,3200,source-gap-exceeds-limit,"))
  assert_true(csv.contains(",,8,9,3100,3400,"))
  let summary = r.summary_csv()
  assert_true(summary.contains("100,\"load.n\",\"N,\"\"review\"\"\",2,1,1,1,"))
  assert_true(summary.contains(",\"0;1\""))
}

///|
test "response SVG uses escaped labels and unconnected descriptive mean dots" {
  let r = responses(units=["N<&", "C"], episodes=[2], after=300L).unwrap()
  let svg = r.to_svg().unwrap()
  assert_true(svg.contains("N&lt;&amp;"))
  assert_true(svg.contains("support 1/1"))
  // Only the exact -100 to 0 pair connects for each of the two channels.
  assert_eq(svg.split("data-episode=\"2\"").count(), 3)
  assert_true(!svg.contains("NaN"))
  assert_true(!svg.contains("Infinity"))
  let big = responses(episodes=[0], before=0L, after=20100L).unwrap()
  assert_true(big.to_svg() is Err(_))
}

///|
test "response timing stays exact above binary64 range and at Int64 boundary" {
  let text = "timestamp_ms,trigger,load.n,temperature.c\n9223372036854775607,0,0,20\n9223372036854775707,1,2,21\n9223372036854775807,0,4,22\n"
  let r = responses(text~, episodes=[0]).unwrap()
  assert_eq(r.trials[0].points[2].timestamp_ms, Some(9223372036854775807L))
  assert_eq(r.trials[0].points[3].status, "outside-timestamp-domain")
  assert_true(r.to_json().stringify().contains("\"9223372036854775707\""))
  assert_eq(r.summaries[2].mean, Some([4.0, 22.0]))
}

///|
test "response interpolation and mean avoid avoidable binary64 overflow" {
  let text = "timestamp_ms,trigger,load.n,temperature.c\n0,1,-1e308,20\n200,0,1e308,20\n1000,1,1e308,20\n1200,0,-1e308,20\n"
  let r = responses(text~, episodes=[0, 1], before=0L).unwrap()
  assert_eq(r.summaries[0].mean, Some([0.0, 20.0]))
  assert_eq(r.summaries[1].mean, Some([0.0, 20.0]))
  assert_eq(r.summaries[2].mean, Some([0.0, 20.0]))
  assert_true(!r.to_svg().unwrap().contains("NaN"))
}

///|
test "response recipe roundtrip rejects duplicate unknown and incorrectly typed fields" {
  let recipe : @telemetry_csv.EventResponseRecipe = {
    event_channel: "trigger",
    direction: "above",
    threshold: 0.5,
    episodes: [0, 1, 2],
    channels: ["load.n"],
    unit_labels: ["N"],
    before_ms: 100L,
    after_ms: 200L,
    step_ms: 100L,
    event_min_span_ms: 0L,
    event_max_gap_ms: 250L,
    max_gap_ms: 200L,
    overlap_policy: "reject",
  }
  let json = recipe.to_json().stringify()
  assert_eq(@telemetry_csv.parse_event_response_recipe(json), Ok(recipe))
  assert_true(
    @telemetry_csv.parse_event_response_recipe(
      json.replace(old="\"trigger\"", new="\"trigger\",\"event_channel\":\"x\""),
    )
    is Err(_),
  )
  assert_true(
    @telemetry_csv.parse_event_response_recipe(
      json.replace(old="event_channel", new="event_typo"),
    )
    is Err(_),
  )
  assert_true(
    @telemetry_csv.parse_event_response_recipe(
      json.replace(old="\"100\"", new="true"),
    )
    is Err(_),
  )
}

///|
test "single observed anchor supports a zero width response without claiming onset" {
  let r = responses(
    text="timestamp_ms,trigger,load.n,temperature.c\n0,1,5,20\n",
    episodes=[0],
    before=0L,
    after=0L,
  ).unwrap()
  assert_eq(r.trials[0].anchor.first_sample_position, 0)
  assert_eq(r.trials[0].anchor.observed_span_ms, 0L)
  assert_eq(r.summaries[0].mean, Some([5.0, 20.0]))
  assert_true(!r.to_svg().unwrap().contains("NaN"))
}

///|
test "coarse response SVG does not hide a source gap between exact grid points" {
  let r = responses(
    text="timestamp_ms,trigger,load.n,temperature.c\n0,1,2,20\n200,0,4,22\n",
    episodes=[0],
    before=0L,
    after=200L,
    step=200L,
    gap=100L,
  ).unwrap()
  assert_eq(r.trials[0].points.map(p => p.status), ["exact", "exact"])
  assert_true(
    r.trials[0].points[0].source_segment != r.trials[0].points[1].source_segment,
  )
  assert_true(!r.to_svg().unwrap().contains("data-episode="))
}
