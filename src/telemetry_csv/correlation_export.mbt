///|
pub fn TelemetryCorrelation::to_csv(self : TelemetryCorrelation) -> String {
  let out = StringBuilder()
  out.write_string(
    "lag_samples,lag_ms,pair_count,left_start_sample,right_start_sample,coefficient,status\n",
  )
  for lag in self.lags {
    let coefficient = match lag.coefficient {
      Some(value) => value.to_string()
      None => ""
    }
    out.write_string(
      "\{lag.lag_samples},\{lag.lag_ms},\{lag.pair_count},\{lag.left_start_sample},\{lag.right_start_sample},\{coefficient},\{lag.status}\n",
    )
  }
  out.to_string()
}

///|
/// A standalone, inert plot with every discrete lag and its overlap count.
pub fn TelemetryCorrelation::to_svg(self : TelemetryCorrelation) -> String {
  let out = StringBuilder()
  let left = plot_xml_label(self.left_channel)
  let right = plot_xml_label(self.right_channel)
  let label = plot_short_label(
    self.left_channel + " versus " + self.right_channel,
  )
  out.write_string(
    "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 1100 590\" role=\"img\" aria-labelledby=\"title desc\">\n",
  )
  out.write_string(
    "<title id=\"title\">Recorded channel lag correlation</title><desc id=\"desc\">Overlap-wise Pearson correlation. Positive lag pairs earlier left with later right. Undefined variance is a gap. Descriptive similarity only, without statistical significance, delay calibration, clock correction or causality.</desc>\n",
  )
  out.write_string(
    "<rect width=\"1100\" height=\"590\" fill=\"#0f172a\"/><g fill=\"#e2e8f0\" font-family=\"sans-serif\"><text x=\"32\" y=\"38\" font-size=\"24\">Recorded channel lag correlation</text>\n",
  )
  out.write_string(
    "<text x=\"32\" y=\"70\" font-size=\"16\"><title>Left: \{left}; right: \{right}</title>\{label}</text>\n",
  )
  out.write_string(
    "<text x=\"32\" y=\"97\" font-size=\"13\">N=\{self.samples.length()} · interval=\{self.sample_interval_ms} ms · minimum overlap=3 · per-lag centering</text>\n",
  )
  out.write_string(
    "<rect x=\"100\" y=\"140\" width=\"930\" height=\"300\" fill=\"#172033\" stroke=\"#64748b\"/><path d=\"M100 290 H1030\" stroke=\"#64748b\"/><text x=\"85\" y=\"145\" text-anchor=\"end\">+1</text><text x=\"85\" y=\"295\" text-anchor=\"end\">0</text><text x=\"85\" y=\"440\" text-anchor=\"end\">−1</text>\n",
  )
  for lag in self.lags {
    let x = if self.max_lag_samples == 0 {
      565.0
    } else {
      100.0 +
      (lag.lag_samples + self.max_lag_samples).to_double() /
      (2 * self.max_lag_samples).to_double() *
      930.0
    }
    match lag.coefficient {
      Some(r) => {
        let y = 290.0 - r * 150.0
        out.write_string(
          "<g class=\"correlation-lag\"><title>lag=\{lag.lag_samples} samples, \{lag.lag_ms} ms; pairs=\{lag.pair_count}; r=\{r}</title><path d=\"M \{x} 290 V \{y}\" stroke=\"#38bdf8\"/><circle cx=\"\{x}\" cy=\"\{y}\" r=\"4\" fill=\"#7dd3fc\"/></g>\n",
        )
      }
      None =>
        out.write_string(
          "<g class=\"undefined-lag\"><title>lag=\{lag.lag_samples} samples, \{lag.lag_ms} ms; pairs=\{lag.pair_count}; undefined zero or unresolved variance</title><text x=\"\{x}\" y=\"457\" text-anchor=\"middle\" fill=\"#fbbf24\">×</text></g>\n",
        )
    }
  }
  out.write_string(
    "<text x=\"100\" y=\"480\">−\{self.max_lag_samples} samples</text><text x=\"1030\" y=\"480\" text-anchor=\"end\">+\{self.max_lag_samples} samples</text>\n",
  )
  out.write_string(
    "<text x=\"32\" y=\"519\" font-size=\"13\">Positive lag: left[i] versus later right[i+lag]. Hover each bin for milliseconds and overlap.</text><text x=\"32\" y=\"547\" font-size=\"13\">× = undefined variance. No automatic best-lag selection, clock correction, significance or causal claim.</text></g></svg>\n",
  )
  out.to_string()
}
