///|
fn[T : Show] planar_optional(value : T?) -> String {
  match value {
    Some(v) => v.to_string()
    None => ""
  }
}

///|
fn planar_csv_label(value : String) -> String {
  let out = StringBuilder()
  out.write_char('"')
  for c in value {
    if c == '"' {
      out.write_char('"')
    }
    out.write_char(c)
  }
  out.write_char('"')
  out.to_string()
}

///|
fn planar_xml_label(value : String) -> String {
  let out = StringBuilder()
  for c in value {
    match c {
      '&' => out.write_string("&amp;")
      '<' => out.write_string("&lt;")
      '>' => out.write_string("&gt;")
      '"' => out.write_string("&quot;")
      '\'' => out.write_string("&apos;")
      _ => out.write_char(c)
    }
  }
  out.to_string()
}

///|
/// One paired XY row (or explicit gap) per selected baseline observation.
/// Blank candidate/separation cells are unavailable, never zero-filled.
pub fn PlanarComparison::to_csv(self : PlanarComparison) -> String {
  let out = StringBuilder()
  out.write_string(
    "aligned_ms,baseline_timestamp_ms,candidate_left_timestamp_ms,candidate_right_timestamp_ms,baseline_sample_index,candidate_left_sample_index,candidate_right_sample_index,status,baseline_x,baseline_y,candidate_x,candidate_y,separation,connected,frame,units,alignment,baseline_x_channel,baseline_y_channel,candidate_x_channel,candidate_y_channel\n",
  )
  let recipe = self.recipe
  let labels = [
      recipe.baseline_frame,
      recipe.baseline_units,
      recipe.alignment,
      recipe.baseline_x,
      recipe.baseline_y,
      recipe.candidate_x,
      recipe.candidate_y,
    ]
    .map(planar_csv_label)
    .join(",")
  for row in self.rows {
    let left_time = planar_optional(row.candidate_left_timestamp_ms)
    let right_time = planar_optional(row.candidate_right_timestamp_ms)
    let left = planar_optional(row.candidate_left_sample_index)
    let right = planar_optional(row.candidate_right_sample_index)
    let x = planar_optional(row.candidate.map(p => p.x))
    let y = planar_optional(row.candidate.map(p => p.y))
    let distance = planar_optional(row.separation)
    out.write_string(
      "\{row.aligned_ms},\{row.baseline_timestamp_ms},\{left_time},\{right_time},\{row.baseline_sample_index},\{left},\{right},\{row.status},\{row.baseline.x},\{row.baseline.y},\{x},\{y},\{distance},\{row.connected},\{labels}\n",
    )
  }
  out.to_string()
}

///|
/// Equal-aspect XY overlay of selected baseline positions and candidate values
/// sampled at those times. Connections never cross either recording's outage.
pub fn PlanarComparison::to_svg(
  self : PlanarComparison,
) -> Result[String, String] {
  if self.rows.is_empty() {
    return Err("no positions to plot")
  }
  let mut min_x = self.rows[0].baseline.x
  let mut max_x = min_x
  let mut min_y = self.rows[0].baseline.y
  let mut max_y = min_y
  for row in self.rows {
    min_x = min_x.min(row.baseline.x)
    max_x = max_x.max(row.baseline.x)
    min_y = min_y.min(row.baseline.y)
    max_y = max_y.max(row.baseline.y)
    if row.candidate is Some(p) {
      min_x = min_x.min(p.x)
      max_x = max_x.max(p.x)
      min_y = min_y.min(p.y)
      max_y = max_y.max(p.y)
    }
  }
  let width = max_x - min_x
  let height = max_y - min_y
  if width.is_inf() || height.is_inf() {
    return Err("coordinate extent exceeds finite SVG range")
  }
  let extent = width.max(height)
  let denominator = if extent == 0.0 { 1.0 } else { extent }
  let x_pad = (1.0 - width / denominator) * 280.0
  let y_pad = (1.0 - height / denominator) * 280.0
  let px = (x : Double) => 120.0 + x_pad + (x - min_x) / denominator * 560.0
  let py = (y : Double) => 672.0 - y_pad - (y - min_y) / denominator * 560.0
  let out = StringBuilder()
  let frame = planar_xml_label(self.recipe.baseline_frame)
  let units = planar_xml_label(self.recipe.baseline_units)
  let alignment = planar_xml_label(self.recipe.alignment)
  out.write_string(
    "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 800 780\" role=\"img\" aria-labelledby=\"title desc\">\n<title id=\"title\">Paired XY route comparison</title><desc id=\"desc\">Offline declared comparable coordinates. Blue baseline, pink candidate at baseline times; orange unmatched baseline. Disconnected across gaps. No readiness or physical outcome is inferred.</desc>\n<rect width=\"800\" height=\"780\" fill=\"#0f172a\"/>\n<g fill=\"#e2e8f0\" font-family=\"sans-serif\" font-size=\"16\">\n",
  )
  out.write_string(
    "<text x=\"25\" y=\"30\">Paired XY · \{self.compared_count} paired · \{self.unmatched_count} unmatched</text>\n<text x=\"25\" y=\"58\">Declared frame: \{frame} · units: \{units}</text>\n<text x=\"25\" y=\"86\">Alignment: \{alignment} · gap cutoff: \{self.max_gap_ms} ms</text>\n<text x=\"25\" y=\"710\">Blue baseline · pink sampled candidate · orange unmatched baseline</text>\n<text x=\"25\" y=\"740\">Equal scale, Y up. Hover for exact clocks, brackets and separation.</text></g>\n<rect x=\"120\" y=\"112\" width=\"560\" height=\"560\" fill=\"none\" stroke=\"#475569\"/>\n",
  )
  for i, row in self.rows {
    let bx = px(row.baseline.x)
    let by = py(row.baseline.y)
    if row.connected && i > 0 {
      let previous = self.rows[i - 1]
      out.write_string(
        "<line data-route=\"baseline\" x1=\"\{px(previous.baseline.x)}\" y1=\"\{py(previous.baseline.y)}\" x2=\"\{bx}\" y2=\"\{by}\" stroke=\"#38bdf8\" stroke-width=\"3\"/>\n",
      )
      if previous.candidate is Some(a) && row.candidate is Some(b) {
        out.write_string(
          "<line data-route=\"candidate\" x1=\"\{px(a.x)}\" y1=\"\{py(a.y)}\" x2=\"\{px(b.x)}\" y2=\"\{py(b.y)}\" stroke=\"#f472b6\" stroke-width=\"3\"/>\n",
        )
      }
    }
    let color = if row.candidate is Some(_) { "#38bdf8" } else { "#fb923c" }
    out.write_string(
      "<circle data-route=\"baseline\" cx=\"\{bx}\" cy=\"\{by}\" r=\"4\" fill=\"\{color}\"><title>baseline sample=\{row.baseline_sample_index}; t=\{row.baseline_timestamp_ms}; aligned=\{row.aligned_ms}; x=\{row.baseline.x}; y=\{row.baseline.y}; \{row.status}</title></circle>\n",
    )
    if row.candidate is Some(p) {
      let left = planar_optional(row.candidate_left_timestamp_ms)
      let right = planar_optional(row.candidate_right_timestamp_ms)
      let separation = planar_optional(row.separation)
      out.write_string(
        "<circle data-route=\"candidate\" cx=\"\{px(p.x)}\" cy=\"\{py(p.y)}\" r=\"5\" fill=\"none\" stroke=\"#f472b6\" stroke-width=\"2\"><title>\{row.status}; source bracket=[\{left},\{right}]; aligned=\{row.aligned_ms}; x=\{p.x}; y=\{p.y}; separation=\{separation}</title></circle>\n",
      )
    }
  }
  out.write_string("</svg>\n")
  Ok(out.to_string())
}

///|
fn[T : ToJson] planar_json_optional(value : T?) -> Json {
  match value {
    Some(v) => v.to_json()
    None => Json::null()
  }
}

///|
/// Explicit nulls keep unmatched positions and missing brackets visible.
pub impl ToJson for PlanarRow with fn to_json(self) {
  {
    "aligned_ms": self.aligned_ms.to_json(),
    "baseline_timestamp_ms": self.baseline_timestamp_ms.to_json(),
    "baseline_sample_index": self.baseline_sample_index.to_json(),
    "status": self.status.to_json(),
    "baseline": self.baseline.to_json(),
    "connected": self.connected.to_json(),
    "candidate_left_timestamp_ms": planar_json_optional(
      self.candidate_left_timestamp_ms,
    ),
    "candidate_right_timestamp_ms": planar_json_optional(
      self.candidate_right_timestamp_ms,
    ),
    "candidate_left_sample_index": planar_json_optional(
      self.candidate_left_sample_index,
    ),
    "candidate_right_sample_index": planar_json_optional(
      self.candidate_right_sample_index,
    ),
    "candidate": planar_json_optional(self.candidate),
    "separation": planar_json_optional(self.separation),
  }
}

///|
/// A no-pair report has an explicit null summary, never a zero summary.
pub impl ToJson for PlanarComparison with fn to_json(self) {
  {
    "format": self.format.to_json(),
    "scope": self.scope.to_json(),
    "recipe": self.recipe.to_json(),
    "timebase": self.timebase.to_json(),
    "baseline_origin_ms": self.baseline_origin_ms.to_json(),
    "candidate_origin_ms": self.candidate_origin_ms.to_json(),
    "start_ms": self.start_ms.to_json(),
    "end_ms": self.end_ms.to_json(),
    "max_gap_ms": self.max_gap_ms.to_json(),
    "summary_weighting": self.summary_weighting.to_json(),
    "compared_count": self.compared_count.to_json(),
    "interpolated_count": self.interpolated_count.to_json(),
    "unmatched_count": self.unmatched_count.to_json(),
    "baseline_source": self.baseline_source.to_json(),
    "candidate_source": self.candidate_source.to_json(),
    "rows": self.rows.to_json(),
    "summary": planar_json_optional(self.summary),
  }
}
