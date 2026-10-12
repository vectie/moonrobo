///|
test "XY path distance speed and gaps" {
  let text = "timestamp_ms,y,x,temperature\n100,0,0,20\n600,4,3,21\n1100,4,6,22\n3100,10,100,23\n3600,10,103,24"
  let path = @telemetry_csv.trajectory_csv(text, "x", "y", units="m").unwrap()
  assert_eq(path.observed_distance, 11.0)
  assert_eq(path.observed_duration_ms, 1500L)
  assert_eq(path.peak_interval_speed, 10.0)
  assert_eq(path.segment_count, 2)
  assert_eq(path.gap_count, 1)
  assert_eq(path.points[3].connected, false)
  assert_eq(path.points[3].segment, 1)
  assert_eq(path.minimum_x, 0.0)
  assert_eq(path.maximum_y, 10.0)
  assert_true(path.to_csv().contains("3100,100,10,1,false,,"))
  assert_eq(path.to_svg().split("<path ").count(), 3)
  assert_eq(path.to_svg().split("<circle ").count(), 6)
}

///|
test "absolute inclusive window and no boundary interpolation" {
  let text = "timestamp_ms,x,y\n100,0,0\n600,3,4\n1100,6,4"
  let path = @telemetry_csv.trajectory_csv(
    text,
    "x",
    "y",
    start_ms=600L,
    end_ms=1100L,
    max_gap_ms=500L,
  ).unwrap()
  assert_eq(path.points.length(), 2)
  assert_eq(path.observed_distance, 3.0)
  assert_eq(path.points[0].connected, false)
  assert_eq(path.gap_count, 0)
  assert_true(
    @telemetry_csv.trajectory_csv(text, "x", "y", start_ms=601L, end_ms=1099L)
    is Err(_),
  )
}

///|
test "stationary and singleton paths remain visible" {
  let path = @telemetry_csv.trajectory_csv(
    "timestamp_ms,x,y\n0,5,-8\n10,5,-8", "x", "y",
  ).unwrap()
  assert_eq(path.observed_distance, 0.0)
  assert_eq(path.peak_interval_speed, 0.0)
  assert_true(path.to_svg().contains("cx=\"400\" cy=\"392\""))
  let single = @telemetry_csv.trajectory_csv(
    "timestamp_ms,x,y\n0,5,-8", "x", "y",
  ).unwrap()
  assert_eq(single.segment_count, 1)
  assert_eq(single.observed_duration_ms, 0L)
  assert_true(single.to_csv().contains("0,5,-8,0,false,,"))
}

///|
test "SVG preserves equal aspect and escapes labels" {
  let path = @telemetry_csv.trajectory_csv(
    "timestamp_ms,<x>,y&\n0,0,0\n1000,2,1",
    "<x>",
    "y&",
    units="m<script>",
  ).unwrap()
  assert_true(path.to_svg().contains("M 120 532 L 680 252"))
  assert_true(path.to_svg().contains("&lt;x&gt;"))
  assert_true(path.to_svg().contains("y&amp;"))
  assert_true(!path.to_svg().contains("<script>"))
}

///|
test "invalid mappings options and all rows validated" {
  let text = "timestamp_ms,x,y\n0,1,2"
  assert_true(@telemetry_csv.trajectory_csv(text, "x", "x") is Err(_))
  assert_true(@telemetry_csv.trajectory_csv(text, "z", "y") is Err(_))
  assert_true(@telemetry_csv.trajectory_csv(text, "x", "z") is Err(_))
  assert_true(
    @telemetry_csv.trajectory_csv(text, "x", "y", units="  ") is Err(_),
  )
  assert_true(
    @telemetry_csv.trajectory_csv(text, "x", "y", max_gap_ms=0L) is Err(_),
  )
  assert_true(
    @telemetry_csv.trajectory_csv(text, "x", "y", start_ms=2L, end_ms=1L)
    is Err(_),
  )
  assert_true(
    @telemetry_csv.trajectory_csv(text + "\n1,bad,3", "x", "y", end_ms=0L)
    is Err(_),
  )
}

///|
test "large finite geometry and precise Int64 intervals" {
  let path = @telemetry_csv.trajectory_csv(
    "timestamp_ms,x,y\n9007199254740993,0,0\n9007199254740994,3,4", "x", "y",
  ).unwrap()
  assert_eq(path.observed_duration_ms, 1L)
  assert_eq(path.peak_interval_speed, 5000.0)
  assert_eq(path.points[0].timestamp_ms, 9007199254740993L)
  let large = @telemetry_csv.trajectory_csv(
    "timestamp_ms,x,y\n0,0,0\n1000,1e200,1e200", "x", "y",
  ).unwrap()
  assert_true(!large.observed_distance.is_inf())
  assert_true(!large.to_svg().contains("NaN"))
  assert_true(
    @telemetry_csv.trajectory_csv(
      "timestamp_ms,x,y\n0,-1e308,0\n1000,1e308,0", "x", "y",
    )
    is Err(_),
  )
}
