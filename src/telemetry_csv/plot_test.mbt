///|
test "plot selection preserves order values source positions and inclusive boundaries" {
  let text = "timestamp_ms,a,b\n0,9,90\n10,1,10\n20,3,30\n31,2,20\n40,8,80\n"
  guard @telemetry_csv.plot_csv(
      text,
      ["b", "a"],
      unit_labels=["B", "A"],
      start_ms=10L,
      end_ms=31L,
      max_gap_ms=10L,
    )
    is Ok(plot) else {
    fail("plot failed")
  }
  assert_eq(plot.source_sample_count, 5)
  assert_eq(plot.samples.length(), 3)
  assert_eq(plot.channels.map(c => c.channel), ["b", "a"])
  assert_eq(plot.channels.map(c => c.unit_label), ["B", "A"])
  assert_eq(plot.samples.map(s => s.source_sample_index), [1, 2, 3])
  assert_eq(plot.samples.map(s => s.timestamp_ms), [10L, 20L, 31L])
  assert_eq(plot.samples.map(s => s.segment), [0, 0, 1])
  assert_eq(plot.samples.map(s => s.connected), [false, true, false])
  assert_eq(plot.samples[1].values, [30.0, 3.0])
  assert_eq(plot.channels[0].minimum, 10.0)
  assert_eq(plot.channels[0].maximum, 30.0)
  assert_eq(plot.segment_count, 2)
  assert_eq(plot.gap_count, 1)
  let svg = plot.to_svg()
  assert_eq(svg.split("class=\"observations\"").count(), 5)
  assert_eq(svg.split("class=\"gap\"").count(), 3)
  assert_eq(svg.split("<circle ").count(), 7)
  assert_true(svg.contains("Independent Y scales"))
  assert_true(svg.contains("b [B]"))
}

///|
test "plot exact large times and one millisecond differences survive drawing" {
  let text = "timestamp_ms,v\n9223372036854775805,0\n9223372036854775806,1\n9223372036854775807,2\n"
  guard @telemetry_csv.plot_csv(text, ["v"], max_gap_ms=1L) is Ok(plot) else {
    fail("plot failed")
  }
  assert_eq(plot.gap_count, 0)
  let svg = plot.to_svg()
  assert_true(svg.contains("cx=\"190\" cy=\"270\""))
  assert_true(svg.contains("cx=\"615\" cy=\"205\""))
  assert_true(svg.contains("cx=\"1040\" cy=\"140\""))
  assert_true(svg.contains("timestamp_ms=9223372036854775806"))
  assert_true(plot.to_json().stringify().contains("\"9223372036854775807\""))
}

///|
test "plot full Int64 span and uneven sampling use elapsed proportional X" {
  guard @telemetry_csv.plot_csv("timestamp_ms,v\n0,0\n1,1\n4,4\n", ["v"])
    is Ok(uneven) else {
    fail("plot failed")
  }
  assert_true(uneven.to_svg().contains("cx=\"402.5\""))
  guard @telemetry_csv.plot_csv(
      "timestamp_ms,v\n0,0\n9223372036854775807,1\n",
      ["v"],
      max_gap_ms=9223372036854775807L,
    )
    is Ok(wide) else {
    fail("plot failed")
  }
  assert_eq(wide.gap_count, 0)
  assert_true(wide.to_svg().contains("+4611686018427387903 ms"))
  assert_true(wide.to_svg().contains("cx=\"1040\""))
}

///|
test "plot singleton constant negative and tiny values remain visible" {
  guard @telemetry_csv.plot_csv("timestamp_ms,v\n7,-5\n", ["v"]) is Ok(single) else {
    fail("plot failed")
  }
  assert_eq(single.samples[0].connected, false)
  assert_eq(single.channels[0].unit_label, "unspecified")
  assert_true(single.to_svg().contains("cx=\"615\" cy=\"205\""))
  assert_true(single.to_svg().contains(">constant</text>"))
  guard @telemetry_csv.plot_csv("timestamp_ms,v\n0,8\n1,8\n", ["v"]) is Ok(flat) else {
    fail("plot failed")
  }
  assert_true(flat.to_svg().contains("M 190 205 L 1040 205"))
  guard @telemetry_csv.plot_csv("timestamp_ms,v\n0,0\n1,5e-324\n", ["v"])
    is Ok(tiny) else {
    fail("plot failed")
  }
  assert_true(tiny.to_svg().contains("cx=\"1040\" cy=\"140\""))
}

///|
test "plot opposite finite extremes avoid overflow in pixel geometry" {
  guard @telemetry_csv.plot_csv(
      "timestamp_ms,v\n0,-1.7976931348623157e308\n1,0\n2,1.7976931348623157e308\n",
      ["v"],
    )
    is Ok(plot) else {
    fail("plot failed")
  }
  let svg = plot.to_svg()
  assert_true(svg.contains("cx=\"190\" cy=\"270\""))
  assert_true(svg.contains("cx=\"615\" cy=\"205\""))
  assert_true(svg.contains("cx=\"1040\" cy=\"140\""))
  assert_false(svg.contains("Infinity"))
  assert_false(svg.contains("NaN"))
}

///|
test "plot rejects invalid selections windows gaps and labels" {
  let text = "timestamp_ms,v\n0,1\n2,3\n"
  assert_true(@telemetry_csv.plot_csv(text, []) is Err(_))
  assert_true(@telemetry_csv.plot_csv(text, ["missing"]) is Err(_))
  assert_true(@telemetry_csv.plot_csv(text, ["v", "v"]) is Err(_))
  assert_true(
    @telemetry_csv.plot_csv(text, ["v"], start_ms=1L, end_ms=1L) is Err(_),
  )
  assert_true(
    @telemetry_csv.plot_csv(text, ["v"], start_ms=3L, end_ms=2L) is Err(_),
  )
  assert_true(@telemetry_csv.plot_csv(text, ["v"], start_ms=-1L) is Err(_))
  assert_true(@telemetry_csv.plot_csv(text, ["v"], max_gap_ms=0L) is Err(_))
  assert_true(@telemetry_csv.plot_csv(text, ["v"], max_gap_ms=-1L) is Err(_))
  assert_true(
    @telemetry_csv.plot_csv(text, ["v"], unit_labels=["a", "b"]) is Err(_),
  )
  assert_true(@telemetry_csv.plot_csv(text, ["v"], unit_labels=[" "]) is Err(_))
  assert_true(
    @telemetry_csv.plot_csv(text, ["v"], unit_labels=["\u{0}"]) is Err(_),
  )
}

///|
test "plot validates unselected late rows and existing CSV errors" {
  for
    text in [
      "timestamp_ms,v,other\n0,1,0\n1,2,NaN\n", "timestamp_ms,v,other\n0,1,0\n1,2,Infinity\n",
      "timestamp_ms,v,other\n0,1,0\n1,2\n", "timestamp_ms,v\n0,1\n2,2\n1,3\n", "timestamp_ms,v\n0,1\n0,2\n",
      "timestamp_ms,v\n-1,1\n", "timestamp_ms,v\n9223372036854775808,1\n", "timestamp_ms,v,v\n0,1,2\n",
      "timestamp_ms,v\n0,\"1\"\n", "timestamp_ms,v\n",
    ] {
    assert_true(@telemetry_csv.plot_csv(text, ["v"], end_ms=0L) is Err(_))
  }
}

///|
test "plot escapes XML labels while preserving exact reported metadata" {
  let name = "温度<&'script>"
  let units = "<K&\"'>"
  guard @telemetry_csv.plot_csv("timestamp_ms," + name + "\n0,1\n", [name], unit_labels=[
      units,
    ])
    is Ok(plot) else {
    fail("plot failed")
  }
  assert_eq(plot.channels[0].channel, name)
  assert_eq(plot.channels[0].unit_label, units)
  let svg = plot.to_svg()
  assert_true(svg.contains("温度&lt;&amp;&apos;script&gt;"))
  assert_true(svg.contains("&lt;K&amp;&quot;&apos;&gt;"))
  assert_false(svg.contains("<K&"))
  assert_true(
    @telemetry_csv.plot_csv("timestamp_ms,a\u{0}b\n0,1\n", ["a\u{0}b"])
    is Err(_),
  )
}

///|
test "plot CRLF blank lines and long names retain original source indexing" {
  let name = "温度".repeat(45)
  guard @telemetry_csv.plot_csv(
      "\r\ntimestamp_ms," + name + "\r\n\r\n10,2\r\n20,3",
      [name],
      start_ms=20L,
    )
    is Ok(plot) else {
    fail("plot failed")
  }
  assert_eq(plot.samples[0].source_sample_index, 1)
  assert_eq(plot.source_sample_count, 2)
  let svg = plot.to_svg()
  assert_true(svg.contains("…</text>"))
  assert_true(svg.contains(name + " [unspecified]</title>"))
}

///|
test "plot full-span tick labels face inward and singleton tick stays centered" {
  guard @telemetry_csv.plot_csv(
      "timestamp_ms,voltage\n0,-1e308\n4611686018427387903,0\n9223372036854775807,1e308\n",
      ["voltage"],
      unit_labels=["V"],
      max_gap_ms=9223372036854775807L,
    )
    is Ok(wide) else {
    fail("plot failed")
  }
  let svg = wide.to_svg()
  assert_true(
    svg.contains(
      "<text x=\"190\" y=\"293\" text-anchor=\"start\" font-size=\"12\">+0 ms</text>",
    ),
  )
  assert_true(
    svg.contains(
      "<text x=\"615\" y=\"293\" text-anchor=\"middle\" font-size=\"12\">+4611686018427387903 ms</text>",
    ),
  )
  assert_true(
    svg.contains(
      "<text x=\"1040\" y=\"293\" text-anchor=\"end\" font-size=\"12\">+9223372036854775807 ms</text>",
    ),
  )
  guard @telemetry_csv.plot_csv("timestamp_ms,v\n7,1\n", ["v"]) is Ok(single) else {
    fail("plot failed")
  }
  assert_true(
    single
    .to_svg()
    .contains(
      "<text x=\"615\" y=\"293\" text-anchor=\"middle\" font-size=\"12\">+0 ms</text>",
    ),
  )
}
