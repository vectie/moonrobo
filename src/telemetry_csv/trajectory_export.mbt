///|
fn xml_label(text : String) -> String {
  text
  .replace(old="&", new="&amp;")
  .replace(old="<", new="&lt;")
  .replace(old=">", new="&gt;")
  .replace(old="\"", new="&quot;")
  .replace(old="'", new="&apos;")
}

///|
/// Long-form path export; unavailable incoming interval estimates are blank.
pub fn Trajectory::to_csv(self : Trajectory) -> String {
  let out = StringBuilder::new()
  out.write_string("timestamp_ms,x,y,segment,connected,distance,speed\n")
  for point in self.points {
    out.write_string(
      "\{point.timestamp_ms},\{point.x},\{point.y},\{point.segment},\{point.connected},",
    )
    if point.connected {
      out.write_string("\{point.distance},\{point.speed}")
    } else {
      out.write_string(",")
    }
    out.write_string("\n")
  }
  out.to_string()
}

///|
/// Standalone equal-aspect XY plot. Y increases upward; separate path elements
/// preserve gaps. Every recorded point has a timestamp/coordinate tooltip.
pub fn Trajectory::to_svg(self : Trajectory) -> String {
  let out = StringBuilder::new()
  let x_name = xml_label(self.x_channel)
  let y_name = xml_label(self.y_channel)
  let units = xml_label(self.units)
  let extent = (self.maximum_x - self.minimum_x).max(
    self.maximum_y - self.minimum_y,
  )
  // Divide offsets before multiplication to avoid overflowing large coordinates.
  let denominator = if extent == 0.0 { 1.0 } else { extent }
  let x_pad = (1.0 - (self.maximum_x - self.minimum_x) / denominator) * 280.0
  let y_pad = (1.0 - (self.maximum_y - self.minimum_y) / denominator) * 280.0
  out.write_string(
    "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 800 760\" role=\"img\" aria-labelledby=\"title desc\">\n",
  )
  out.write_string(
    "<title id=\"title\">Recorded XY trajectory</title><desc id=\"desc\">Offline positions. Gaps are disconnected. No hardware control or inferred motion.</desc>\n",
  )
  out.write_string(
    "<rect width=\"800\" height=\"760\" fill=\"#0f172a\"/><g fill=\"#e2e8f0\" font-family=\"sans-serif\" font-size=\"16\">\n",
  )
  out.write_string(
    "<text x=\"30\" y=\"32\">Recorded XY trajectory · \{self.points.length()} positions</text>\n",
  )
  out.write_string(
    "<text x=\"30\" y=\"59\">\{self.segment_count} segments · \{self.gap_count} gaps · cutoff \{self.max_gap_ms} ms</text>\n",
  )
  out.write_string(
    "<text x=\"30\" y=\"87\">Observed distance: \{self.observed_distance} \{units}</text>\n",
  )
  out.write_string(
    "<text x=\"30\" y=\"712\">X: \{x_name} · Y: \{y_name} · \{units} (equal scale, Y up)</text>\n",
  )
  out.write_string(
    "<text x=\"30\" y=\"740\">Green: first · orange: last · hover points for time and coordinates</text></g>\n",
  )
  out.write_string(
    "<rect x=\"120\" y=\"112\" width=\"560\" height=\"560\" fill=\"none\" stroke=\"#475569\"/>\n",
  )
  let mut path_open = false
  for point in self.points {
    let px = 120.0 + x_pad + (point.x - self.minimum_x) / denominator * 560.0
    let py = 672.0 - y_pad - (point.y - self.minimum_y) / denominator * 560.0
    if !point.connected {
      if path_open {
        out.write_string(
          "\" fill=\"none\" stroke=\"#38bdf8\" stroke-width=\"3\"/>\n",
        )
      }
      out.write_string("<path d=\"M \{px} \{py}")
      path_open = true
    } else {
      out.write_string(" L \{px} \{py}")
    }
  }
  if path_open {
    out.write_string(
      "\" fill=\"none\" stroke=\"#38bdf8\" stroke-width=\"3\"/>\n",
    )
  }
  for i, point in self.points {
    let px = 120.0 + x_pad + (point.x - self.minimum_x) / denominator * 560.0
    let py = 672.0 - y_pad - (point.y - self.minimum_y) / denominator * 560.0
    let color = if i == self.points.length() - 1 {
      "#fb923c"
    } else if i == 0 {
      "#4ade80"
    } else {
      "#e2e8f0"
    }
    out.write_string(
      "<circle cx=\"\{px}\" cy=\"\{py}\" r=\"5\" fill=\"\{color}\"><title>t=\{point.timestamp_ms} ms; x=\{point.x}; y=\{point.y}; segment=\{point.segment}</title></circle>\n",
    )
  }
  out.write_string("</svg>\n")
  out.to_string()
}
