///|
fn plot_xml_label(text : String) -> String {
  let out = StringBuilder()
  for ch in text {
    match ch {
      '&' => out.write_string("&amp;")
      '<' => out.write_string("&lt;")
      '>' => out.write_string("&gt;")
      '\"' => out.write_string("&quot;")
      '\'' => out.write_string("&apos;")
      _ => out.write_char(ch)
    }
  }
  out.to_string()
}

///|
fn plot_y_fraction(
  value : Double,
  minimum : Double,
  maximum : Double,
) -> Double {
  if minimum == maximum {
    return 0.5
  }
  let extent = maximum - minimum
  if extent.is_inf() {
    // Halving before subtraction also supports finite opposite-sign extremes.
    (value / 2.0 - minimum / 2.0) / (maximum / 2.0 - minimum / 2.0)
  } else {
    (value - minimum) / extent
  }
}

///|
fn plot_short_label(text : String) -> String {
  let out = StringBuilder()
  let mut length = 0
  for ch in text {
    if length == 60 {
      out.write_string("…")
      break
    }
    out.write_char(ch)
    length += 1
  }
  plot_xml_label(out.to_string())
}

///|
/// Export a standalone SVG from an unmodified plot_csv result. Every observation
/// remains visible as a marker with exact data in its tooltip; no downsampling,
/// smoothing, inferred units, network resources or executable content is added.
pub fn TelemetryPlot::to_svg(self : TelemetryPlot) -> String {
  let out = StringBuilder()
  let height = 190 + 210 * self.channels.length()
  let first = self.samples[0].timestamp_ms
  let last = self.samples[self.samples.length() - 1].timestamp_ms
  let span = last - first
  let coordinates = self.samples.map(sample => {
    if span == 0L {
      615.0
    } else {
      // Subtract exact Int64 times before converting to floating-point pixels.
      190.0 +
      (sample.timestamp_ms - first).to_double() / span.to_double() * 850.0
    }
  })
  out.write_string(
    "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 1100 \{height}\" role=\"img\" aria-labelledby=\"title desc\">\n",
  )
  out.write_string(
    "<title id=\"title\">Recorded telemetry over time</title><desc id=\"desc\">Selected channels in separate independently scaled panels with a shared time axis. Dots are observations; lines only join observations. Amber bands mark intervals beyond the supplied gap cutoff. No values are inferred between samples.</desc>\n",
  )
  out.write_string(
    "<rect width=\"1100\" height=\"\{height}\" fill=\"#0f172a\"/>\n",
  )
  out.write_string("<g font-family=\"sans-serif\" fill=\"#e2e8f0\">\n")
  out.write_string(
    "<text x=\"32\" y=\"36\" font-size=\"23\">Recorded telemetry over time</text>\n",
  )
  out.write_string(
    "<text x=\"32\" y=\"63\" font-size=\"14\">\{self.samples.length()} observed rows · \{self.channels.length()} channels · \{self.gap_count} gaps · cutoff \{self.max_gap_ms} ms</text>\n",
  )
  out.write_string(
    "<text x=\"32\" y=\"87\" font-size=\"13\">Independent Y scales; compare timing, not panel heights. Units are supplied labels only.</text>\n",
  )
  for ci, channel in self.channels {
    let top = 140 + 210 * ci
    let bottom = top + 130
    let title_y = top - 16
    let label = channel.channel + " [" + channel.unit_label + "]"
    let full_name = plot_xml_label(label)
    let display_name = plot_short_label(label)
    out.write_string("<g data-channel-index=\"\{ci}\">\n")
    out.write_string(
      "<text x=\"32\" y=\"\{title_y}\" font-size=\"16\"><title>\{full_name}</title>\{display_name}</text>\n",
    )
    out.write_string(
      "<rect x=\"190\" y=\"\{top}\" width=\"850\" height=\"130\" fill=\"#172033\" stroke=\"#64748b\"/>\n",
    )
    for i in 1..<self.samples.length() {
      if !self.samples[i].connected {
        let x = coordinates[i - 1]
        let width = coordinates[i] - x
        let previous = self.samples[i - 1].timestamp_ms
        let current = self.samples[i].timestamp_ms
        let gap = current - previous
        out.write_string(
          "<rect class=\"gap\" x=\"\{x}\" y=\"\{top}\" width=\"\{width}\" height=\"130\" fill=\"#fbbf24\" fill-opacity=\"0.12\"><title>Gap: \{previous} to \{current} ms; \{gap} ms between observations</title></rect>\n",
        )
      }
    }
    for tick in 0..<3 {
      let elapsed = if tick == 0 {
        0L
      } else if tick == 1 {
        span / 2L
      } else {
        span
      }
      let x = if span == 0L {
        615.0
      } else {
        190.0 + elapsed.to_double() / span.to_double() * 850.0
      }
      if span == 0L && tick > 0 {
        continue
      }
      // Skip a repeated midpoint label when the entire span is one millisecond.
      if tick == 1 && elapsed == 0L {
        continue
      }
      let tick_y = bottom + 23
      // Keep long endpoint labels inside the plot instead of centering them
      // over the canvas edge. A singleton's lone tick remains centered.
      let anchor = if span == 0L || tick == 1 {
        "middle"
      } else if tick == 0 {
        "start"
      } else {
        "end"
      }
      out.write_string(
        "<path d=\"M \{x} \{top} V \{bottom}\" stroke=\"#475569\" stroke-dasharray=\"3 5\"/>\n",
      )
      out.write_string(
        "<text x=\"\{x}\" y=\"\{tick_y}\" text-anchor=\"\{anchor}\" font-size=\"12\">+\{elapsed} ms</text>\n",
      )
    }
    let max_y = top + 5
    let min_y = bottom + 5
    out.write_string(
      "<text x=\"178\" y=\"\{max_y}\" text-anchor=\"end\" font-size=\"12\">\{channel.maximum}</text>\n",
    )
    out.write_string(
      "<text x=\"178\" y=\"\{min_y}\" text-anchor=\"end\" font-size=\"12\">\{channel.minimum}</text>\n",
    )
    if channel.minimum == channel.maximum {
      let y = top + 65
      out.write_string(
        "<text x=\"178\" y=\"\{y}\" text-anchor=\"end\" font-size=\"12\">constant</text>\n",
      )
    }
    let mut path_open = false
    for i, sample in self.samples {
      let x = coordinates[i]
      let y = bottom.to_double() -
        plot_y_fraction(sample.values[ci], channel.minimum, channel.maximum) *
        130.0
      if !sample.connected {
        if path_open {
          out.write_string(
            "\" fill=\"none\" stroke=\"#38bdf8\" stroke-width=\"2\"/>\n",
          )
        }
        out.write_string("<path class=\"observations\" d=\"M \{x} \{y}")
        path_open = true
      } else {
        out.write_string(" L \{x} \{y}")
      }
    }
    if path_open {
      out.write_string(
        "\" fill=\"none\" stroke=\"#38bdf8\" stroke-width=\"2\"/>\n",
      )
    }
    for i, sample in self.samples {
      let x = coordinates[i]
      let y = bottom.to_double() -
        plot_y_fraction(sample.values[ci], channel.minimum, channel.maximum) *
        130.0
      let value = sample.values[ci]
      out.write_string(
        "<circle cx=\"\{x}\" cy=\"\{y}\" r=\"3.5\" fill=\"#e2e8f0\"><title>\{full_name}; timestamp_ms=\{sample.timestamp_ms}; value=\{value}; source_sample_index=\{sample.source_sample_index}; segment=\{sample.segment}</title></circle>\n",
      )
    }
    out.write_string("</g>\n")
  }
  let footer = height - 51
  let footer2 = height - 27
  out.write_string(
    "<text x=\"32\" y=\"\{footer}\" font-size=\"13\">Shared X: milliseconds since first selected sample \{first}; last sample \{last}.</text>\n",
  )
  out.write_string(
    "<text x=\"32\" y=\"\{footer2}\" font-size=\"13\">Hover dots for exact values. Lines only join observations; amber intervals have no connecting line.</text>\n",
  )
  out.write_string("</g></svg>\n")
  out.to_string()
}
