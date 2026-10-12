///|
fn laser_xml_label(value : String) -> String {
  value
  .replace_all(old="&", new="&amp;")
  .replace_all(old="<", new="&lt;")
  .replace_all(old=">", new="&gt;")
  .replace_all(old="\"", new="&quot;")
  .replace_all(old="'", new="&apos;")
}

///|
fn laser_optional(value : Double?) -> String {
  match value {
    Some(v) => v.to_string()
    None => ""
  }
}

///|
fn laser_csv_cell(value : String) -> String {
  "\"" + value.replace_all(old="\"", new="\"\"") + "\""
}

///|
/// One row per original beam, including unusable observations with blank XY.
/// This long-form point table is not scalar timestamp_ms telemetry.
pub fn LaserScan::to_csv(self : LaserScan) -> String {
  let out = StringBuilder::new()
  out.write_string(
    "source_line_number,stamp_sec,stamp_nanosec,frame_id,beam_index,angle_rad,acquisition_offset_s,raw_range,status,range_m,intensity,x_m,y_m\n",
  )
  for beam in self.beams {
    let frame = laser_csv_cell(self.frame_id)
    let raw = laser_csv_cell(beam.raw_range.stringify())
    out.write_string(
      "\{self.source_line_number},\{self.sec},\{self.nanosec},\{frame},\{beam.index},\{beam.angle_rad},\{beam.acquisition_offset_s},\{raw},\{beam.status},\{laser_optional(beam.range_m)},\{laser_optional(beam.intensity)},\{laser_optional(beam.x_m)},\{laser_optional(beam.y_m)}\n",
    )
  }
  out.to_string()
}

///|
/// Equal-aspect sensor-frame scatter plot. Returns are never connected into
/// surfaces or free-space rays. Empty usable scans remain explicitly empty.
pub fn LaserScan::to_svg(self : LaserScan) -> String {
  let out = StringBuilder::new()
  let frame = laser_xml_label(self.frame_id)
  let mut radius = 0.0
  for beam in self.beams {
    if beam.status == "usable" {
      radius = radius.max(beam.range_m.unwrap())
    }
  }
  if radius == 0.0 {
    radius = 1.0
  }
  out.write_string(
    "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 800 820\" role=\"img\" aria-labelledby=\"title desc\">\n",
  )
  out.write_string(
    "<title id=\"title\">Recorded planar laser scan</title><desc id=\"desc\">Sensor-frame return points, equal scale, X right and Y up. No world transform, motion correction, connected surfaces or free-space inference.</desc>\n",
  )
  out.write_string(
    "<rect width=\"800\" height=\"820\" fill=\"#0f172a\"/><g fill=\"#e2e8f0\" font-family=\"sans-serif\" font-size=\"16\">\n",
  )
  out.write_string(
    "<text x=\"30\" y=\"32\">Recorded laser scan: \{self.usable_count} / \{self.beams.length()} usable returns</text>\n",
  )
  out.write_string(
    "<text x=\"30\" y=\"60\">Exact first-ray stamp: sec=\{self.sec}, nanosec=\{self.nanosec}</text>\n",
  )
  out.write_string(
    "<text x=\"30\" y=\"88\">Source line \{self.source_line_number}; beam order retained; no motion correction</text>\n",
  )
  out.write_string(
    "<text x=\"30\" y=\"727\">Frame: <tspan>\{frame}</tspan></text><text x=\"30\" y=\"754\">Axes: X forward (right), Y left (up); chart half-width \{radius} m</text>\n",
  )
  out.write_string(
    "<text x=\"30\" y=\"782\">Range limits: \{self.range_min_m} to \{self.range_max_m} m; excluded \{self.beams.length() - self.usable_count}</text>\n",
  )
  if self.usable_count == 0 {
    out.write_string(
      "<text x=\"290\" y=\"170\">No usable returns in this scan</text>\n",
    )
  }
  out.write_string(
    "</g><rect x=\"120\" y=\"120\" width=\"560\" height=\"560\" fill=\"none\" stroke=\"#475569\"/>\n",
  )
  out.write_string(
    "<path d=\"M 120 400 H 680 M 400 120 V 680\" stroke=\"#475569\"/><path d=\"M 394 400 H 406 M 400 394 V 406\" stroke=\"#fb923c\" stroke-width=\"3\"><title>Sensor origin</title></path>\n",
  )
  for beam in self.beams {
    if beam.x_m is Some(x) && beam.y_m is Some(y) {
      let px = 400.0 + x / radius * 280.0
      let py = 400.0 - y / radius * 280.0
      out.write_string(
        "<circle class=\"return\" cx=\"\{px}\" cy=\"\{py}\" r=\"4\" fill=\"#38bdf8\"><title>beam=\{beam.index}; angle=\{beam.angle_rad} rad; offset=\{beam.acquisition_offset_s} s; range=\{laser_optional(beam.range_m)} m; x=\{x} m; y=\{y} m</title></circle>\n",
      )
    }
  }
  out.write_string("</svg>\n")
  out.to_string()
}
